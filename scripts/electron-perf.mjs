#!/usr/bin/env node
/**
 * Issue #279：packaged Electron Release 性能基线 runner。
 *
 * 这个 runner 只测量，不改变产品架构：
 * - 只启动 apps/desktop/out 下的 packaged binary；
 * - workload 使用仓库内匿名 fixture，数据根和 Chromium profile 均隔离；
 * - CPU/RSS/footprint、导航、scroll frame、IPC DTO 字节数分别记录；
 * - 不把缺失的 footprint 或 hitch 数据记为 0/通过。
 */
import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';

import { chromium } from 'playwright-core';

import { resolvePackagedBinary } from './electron-package.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = path.join(root, 'e2e/fixtures/perf-manifest.json');
const manifest = readJson(manifestPath);
const binary = resolvePackagedBinary(root);
const runId = `${new Date().toISOString().replaceAll(':', '-')}-${process.pid}`;
const defaultOutput = path.join(root, 'e2e-artifacts', 'perf', runId);

const scenarioArg = optionValue('--scenario') ?? process.env.COCHELPER_PERF_SCENARIO ?? 'all';
const repetitions = positiveInt(
  optionValue('--repetitions') ?? process.env.COCHELPER_PERF_REPETITIONS,
  3,
);
const warmupCount = nonNegativeInt(
  optionValue('--warmup') ?? process.env.COCHELPER_PERF_WARMUP,
  1,
);
const scrollMs = positiveInt(optionValue('--scroll-ms') ?? process.env.COCHELPER_PERF_SCROLL_MS, 10_000);
const outputDir = path.resolve(optionValue('--output') ?? process.env.COCHELPER_PERF_OUTPUT ?? defaultOutput);
const importTimeoutMs = 120_000;

const SCENARIOS = ['overview', 'village-detail', 'history-24', 'official-lists'];
const selectedScenarios = scenarioArg === 'all' ? SCENARIOS : scenarioArg.split(',').filter(Boolean);
for (const scenario of selectedScenarios) {
  if (!SCENARIOS.includes(scenario)) {
    throw new Error(`未知性能场景：${scenario}；可选值：${SCENARIOS.join(', ')}`);
  }
}

const sessions = new Set();

function optionValue(name) {
  const prefix = `${name}=`;
  const arg = process.argv.find((value) => value.startsWith(prefix));
  return arg === undefined ? undefined : arg.slice(prefix.length);
}

function positiveInt(value, fallback) {
  const parsed = Number(value ?? fallback);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`必须是正整数：${String(value)}`);
  }
  return parsed;
}

function nonNegativeInt(value, fallback) {
  const parsed = Number(value ?? fallback);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`必须是非负整数：${String(value)}`);
  }
  return parsed;
}

function readJson(file) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

function fixturePath(file) {
  const fixtureRoot = path.resolve(root, manifest.fixtureRoot);
  const resolved = path.resolve(fixtureRoot, file);
  if (resolved !== fixtureRoot && !resolved.startsWith(`${fixtureRoot}${path.sep}`)) {
    throw new Error(`fixture 路径越界：${file}`);
  }
  return resolved;
}

function fixtureText(file) {
  return readFileSync(fixturePath(file), 'utf8');
}

function validatePerfFixtures() {
  for (const spec of Object.values(manifest.accountSnapshots)) {
    const snapshot = readJson(fixturePath(spec.file));
    assert.equal(snapshot.tag, spec.tag, `fixture tag 不匹配：${spec.file}`);
    if (spec.minimumBuildingRecords !== undefined) {
      assert(
        snapshot.buildings.length >= spec.minimumBuildingRecords,
        `fixture building 数量不足：${spec.file}`,
      );
    }
    if (spec.minimumBuilderRecords !== undefined) {
      assert(
        snapshot.buildings.length >= spec.minimumBuilderRecords,
        `fixture builder building 数量不足：${spec.file}`,
      );
    }
  }

  const before = readJson(fixturePath(manifest.largeWalls.before));
  const after = readJson(fixturePath(manifest.largeWalls.after));
  const beforeWalls = before.buildings.filter((item) => item.data === 1_000_008);
  const afterWalls = after.buildings.filter((item) => item.data === 1_000_008);
  assert.equal(before.tag, manifest.largeWalls.tag, 'large wall before tag 不匹配');
  assert.equal(after.tag, manifest.largeWalls.tag, 'large wall after tag 不匹配');
  assert.equal(beforeWalls.length, manifest.largeWalls.segmentCount, 'large wall before 数量不匹配');
  assert.equal(afterWalls.length, manifest.largeWalls.segmentCount, 'large wall after 数量不匹配');
  assert(beforeWalls.every((item) => item.lvl === 1), 'large wall before level 不匹配');
  assert(afterWalls.every((item) => item.lvl === 12), 'large wall after level 不匹配');

  for (const file of [...manifest.warLogPages, ...manifest.capitalRaidPages]) {
    const page = readJson(fixturePath(file));
    assert(Array.isArray(page.items) && page.items.length > 0, `分页 fixture 为空：${file}`);
  }
}

validatePerfFixtures();

function getCommitSha() {
  try {
    return execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
  } catch {
    return 'unknown';
  }
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function withTimeout(task, timeoutMs, fallback) {
  let timer;
  try {
    return await Promise.race([
      task,
      new Promise((resolve) => {
        timer = setTimeout(() => resolve(fallback), timeoutMs);
      }),
    ]);
  } finally {
    if (timer !== undefined) {
      clearTimeout(timer);
    }
  }
}

async function findFreePort() {
  const server = createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert(address !== null && typeof address !== 'string');
  const port = address.port;
  await new Promise((resolve, reject) => {
    server.close((error) => (error === undefined ? resolve() : reject(error)));
  });
  return port;
}

async function waitForDevTools(child, port) {
  const endpoint = `http://127.0.0.1:${port}/json/version`;
  const deadline = Date.now() + 30_000;
  let lastError = null;
  while (Date.now() < deadline) {
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(
        `packaged app 在 CDP 可用前退出，exit=${String(child.exitCode)} signal=${String(child.signalCode)}`,
      );
    }
    try {
      const response = await fetch(endpoint, { signal: AbortSignal.timeout(1_000) });
      if (response.ok) {
        return `http://127.0.0.1:${port}`;
      }
      lastError = new Error(`HTTP ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await sleep(100);
  }
  throw new Error(
    `等待 packaged app CDP 超时：${lastError instanceof Error ? lastError.message : String(lastError)}`,
  );
}

async function waitForRendererReady(browser, onPage) {
  const context = browser.contexts()[0];
  assert(context !== undefined, 'CDP 未提供 browser context');
  const deadline = Date.now() + 45_000;
  let page = null;
  while (page === null && Date.now() < deadline) {
    page = context.pages().find((candidate) => !candidate.isClosed()) ?? null;
    if (page === null) {
      await sleep(100);
    }
  }
  if (page === null) {
    throw new Error('等待 packaged app renderer page 超时');
  }
  onPage?.(page);
  while (Date.now() < deadline) {
    const state = await withTimeout(
      page.evaluate(() => ({
        smoke: globalThis.document.querySelector('[data-smoke]')?.getAttribute('data-smoke') ?? '',
        status: globalThis.document.getElementById('status')?.textContent ?? '',
      })),
      1_000,
      null,
    );
    if (state?.smoke === 'ready' || state?.status.includes('Electron 宿主已就绪')) {
      page.setDefaultTimeout(30_000);
      return page;
    }
    if (state?.smoke === 'fatal' || state?.status.includes('宿主健康检查失败')) {
      throw new Error(`Renderer 未就绪：${state.status || state.smoke}`);
    }
    await sleep(100);
  }
  throw new Error('等待 packaged app renderer ready 超时');
}

function collectOutput(child) {
  const output = { stdout: '', stderr: '' };
  child.stdout.on('data', (chunk) => {
    const text = chunk.toString();
    output.stdout += text;
    process.stdout.write(text);
  });
  child.stderr.on('data', (chunk) => {
    const text = chunk.toString();
    output.stderr += text;
    process.stderr.write(text);
  });
  return output;
}

function attachCatalogRequestProbe(page) {
  const events = [];
  const pending = new Map();
  const isCatalogRequest = (request) => request.url().startsWith('cochelper://catalog/');
  page.on('request', (request) => {
    if (!isCatalogRequest(request)) {
      return;
    }
    const startedAt = performance.now();
    pending.set(request, { url: request.url(), startedAt });
    events.push({ kind: 'request', url: request.url(), atMs: startedAt });
  });
  page.on('requestfinished', (request) => {
    const started = pending.get(request);
    if (started === undefined) {
      return;
    }
    pending.delete(request);
    events.push({
      kind: 'finished',
      url: started.url,
      durationMs: performance.now() - started.startedAt,
    });
  });
  page.on('requestfailed', (request) => {
    const started = pending.get(request);
    if (started === undefined) {
      return;
    }
    pending.delete(request);
    events.push({
      kind: 'failed',
      url: started.url,
      durationMs: performance.now() - started.startedAt,
    });
  });
  return {
    mark() {
      return events.length;
    },
    pendingCount() {
      return pending.size;
    },
    summary(mark = 0) {
      const segment = events.slice(mark);
      const requests = segment.filter((event) => event.kind === 'request');
      const finished = segment.filter((event) => event.kind === 'finished');
      const failed = segment.filter((event) => event.kind === 'failed');
      return {
        requestCount: requests.length,
        completedCount: finished.length,
        failedCount: failed.length,
        uniqueUrlCount: new Set(requests.map((event) => event.url)).size,
        durationMs: summarizeNumbers(finished.map((event) => event.durationMs)),
      };
    },
  };
}

async function settleCatalogRequests(page, probe) {
  assert(probe !== null, 'catalog request probe 尚未安装');
  await page.waitForFunction(
    () =>
      [...globalThis.document.images]
        .filter((image) => image.currentSrc.startsWith('cochelper://catalog/'))
        .every((image) => image.complete),
    undefined,
    { timeout: 30_000 },
  );
  const deadline = Date.now() + 5_000;
  while (probe.pendingCount() > 0 && Date.now() < deadline) {
    await sleep(10);
  }
}

function createContext(scenario, repetition) {
  const tempRoot = mkdtempSync(path.join(os.tmpdir(), `coc-helper-perf-${scenario}-${repetition}-`));
  const context = {
    scenario,
    repetition,
    tempRoot,
    homeDirectory: path.join(tempRoot, 'home'),
    dataRoot: path.join(tempRoot, 'electron-data'),
    userDataDirectory: path.join(tempRoot, 'electron-user-data'),
  };
  mkdirSync(context.homeDirectory, { recursive: true });
  mkdirSync(context.dataRoot, { recursive: true });
  mkdirSync(context.userDataDirectory, { recursive: true });
  return context;
}

function createEnvironment(context) {
  return {
    ...process.env,
    COCHELPER_E2E_DATA_ROOT: context.dataRoot,
    ELECTRON_ENABLE_LOGGING: '1',
    ...(process.platform !== 'darwin'
      ? {
          HOME: context.homeDirectory,
          XDG_CONFIG_HOME: path.join(context.homeDirectory, 'config'),
        }
      : {}),
    ...(process.platform === 'win32'
      ? { APPDATA: path.join(context.homeDirectory, 'AppData', 'Roaming') }
      : {}),
  };
}

async function launchApp(context) {
  const port = await findFreePort();
  const spawnAt = performance.now();
  const child = spawn(
    binary,
    [
      `--user-data-dir=${context.userDataDirectory}`,
      '--remote-debugging-address=127.0.0.1',
      `--remote-debugging-port=${port}`,
      ...(process.platform === 'linux' ? ['--no-sandbox'] : []),
    ],
    {
      cwd: root,
      env: {
        ...createEnvironment(context),
        ...(process.platform === 'linux' ? { ELECTRON_DISABLE_SANDBOX: '1' } : {}),
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  const output = collectOutput(child);
  const session = {
    child,
    output,
    browser: null,
    page: null,
    catalogProbe: null,
    port,
    spawnAt,
    startup: null,
  };
  sessions.add(session);
  const startupSampler = startProcessSampler(session, context.tempRoot);
  try {
    const endpoint = await waitForDevTools(child, port);
    const devToolsReadyAt = performance.now();
    session.browser = await withTimeout(chromium.connectOverCDP(endpoint), 20_000, null);
    if (session.browser === null) {
      throw new Error('连接 packaged app CDP 超时');
    }
    session.page = await waitForRendererReady(session.browser, (page) => {
      session.catalogProbe = attachCatalogRequestProbe(page);
    });
    const rendererReadyAt = performance.now();
    await settleCatalogRequests(session.page, session.catalogProbe);
    session.startup = {
      // startupMs 是进程启动到 CDP 可用；ttiMs 是到 renderer app-shell ready。
      startupMs: devToolsReadyAt - spawnAt,
      ttiMs: rendererReadyAt - spawnAt,
      process: await startupSampler.stop(),
    };
    return session;
  } catch (error) {
    await startupSampler.stop();
    await closeSession(session);
    throw error;
  }
}

async function waitForExit(child, timeoutMs) {
  return new Promise((resolve) => {
    let timer;
    const onClose = () => {
      clearTimeout(timer);
      resolve(true);
    };
    timer = setTimeout(() => {
      child.removeListener('close', onClose);
      resolve(false);
    }, timeoutMs);
    child.once('close', onClose);
    if (child.exitCode !== null || child.signalCode !== null) {
      onClose();
    }
  });
}

async function closeSession(session) {
  if (session === null || session === undefined) {
    return;
  }
  if (session.browser !== null) {
    await withTimeout(session.browser.close().catch(() => undefined), 5_000, undefined);
    session.browser = null;
  }
  if (session.child.exitCode === null && session.child.signalCode === null) {
    session.child.kill('SIGTERM');
    await waitForExit(session.child, 10_000);
  }
  if (session.child.exitCode === null && session.child.signalCode === null) {
    session.child.kill('SIGKILL');
    await waitForExit(session.child, 5_000);
  }
  sessions.delete(session);
}

function psRows() {
  try {
    const raw = execFileSync('ps', ['-axo', 'pid=,ppid=,rss=,%cpu=,command='], {
      encoding: 'utf8',
    });
    return raw
      .split('\n')
      .map((line) => line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s+(.*)$/))
      .filter((match) => match !== null)
      .map((match) => ({
        pid: Number(match[1]),
        ppid: Number(match[2]),
        rssBytes: Number(match[3]) * 1024,
        cpuPercent: Number(match[4]),
        command: match[5],
      }));
  } catch {
    return [];
  }
}

function processTree(rootPid) {
  const rows = psRows();
  const children = new Map();
  for (const row of rows) {
    const list = children.get(row.ppid) ?? [];
    list.push(row);
    children.set(row.ppid, list);
  }
  const selected = [];
  const pending = [rootPid];
  const seen = new Set();
  while (pending.length > 0) {
    const pid = pending.pop();
    if (pid === undefined || seen.has(pid)) {
      continue;
    }
    seen.add(pid);
    const row = rows.find((candidate) => candidate.pid === pid);
    if (row !== undefined) {
      selected.push(row);
    }
    for (const child of children.get(pid) ?? []) {
      pending.push(child.pid);
    }
  }
  return selected;
}

function footprintForPid(pid, tempRoot) {
  if (process.platform !== 'darwin' || !existsSync('/usr/bin/footprint')) {
    return null;
  }
  const jsonPath = path.join(tempRoot, `footprint-${pid}.json`);
  try {
    spawnSync('/usr/bin/footprint', ['-j', jsonPath, String(pid)], {
      encoding: 'utf8',
      stdio: 'ignore',
    });
    if (!existsSync(jsonPath)) {
      return null;
    }
    const parsed = readJson(jsonPath);
    const values = {
      physFootprintPeak: null,
      physFootprint: null,
      physfootprint: null,
      footprint: null,
    };
    const visit = (value) => {
      if (value === null || typeof value !== 'object') {
        return;
      }
      if (Array.isArray(value)) {
        for (const item of value) visit(item);
        return;
      }
      for (const [key, item] of Object.entries(value)) {
        const normalized = key.toLowerCase().replaceAll('-', '_');
        if (typeof item === 'number') {
          if (normalized === 'phys_footprint_peak' && values.physFootprintPeak === null) {
            values.physFootprintPeak = item;
          }
          if (normalized === 'phys_footprint' && values.physFootprint === null) {
            values.physFootprint = item;
          }
          if (normalized === 'physfootprint' && values.physfootprint === null) {
            values.physfootprint = item;
          }
          if (normalized === 'footprint' && values.footprint === null) {
            values.footprint = item;
          }
        }
        visit(item);
      }
    };
    visit(parsed);
    return (
      values.physFootprintPeak ??
      values.physFootprint ??
      values.physfootprint ??
      values.footprint
    );
  } catch {
    return null;
  } finally {
    rmSync(jsonPath, { force: true });
  }
}

function sampleProcess(session, tempRoot, index) {
  const rows = processTree(session.child.pid);
  return {
    atMs: performance.now(),
    pids: rows.map((row) => row.pid),
    rssBytes: rows.reduce((total, row) => total + row.rssBytes, 0),
    cpuPercent: rows.reduce((total, row) => total + row.cpuPercent, 0),
    rootFootprintBytes: index % 2 === 0 ? footprintForPid(session.child.pid, tempRoot) : null,
  };
}

function startProcessSampler(session, tempRoot) {
  const samples = [];
  let index = 0;
  const collect = () => {
    samples.push(sampleProcess(session, tempRoot, index));
    index += 1;
  };
  collect();
  const timer = setInterval(collect, 1_000);
  return {
    async stop() {
      clearInterval(timer);
      collect();
      return summarizeProcessSamples(samples);
    },
  };
}

function sortedNumbers(values) {
  return values.filter((value) => Number.isFinite(value)).sort((left, right) => left - right);
}

function percentile(values, ratio) {
  const sorted = sortedNumbers(values);
  if (sorted.length === 0) {
    return null;
  }
  const index = Math.min(sorted.length - 1, Math.ceil(sorted.length * ratio) - 1);
  return sorted[index];
}

function summarizeNumbers(values) {
  const sorted = sortedNumbers(values);
  if (sorted.length === 0) {
    return { count: 0, min: null, p50: null, p95: null, max: null, mean: null };
  }
  return {
    count: sorted.length,
    min: sorted[0],
    p50: percentile(sorted, 0.5),
    p95: percentile(sorted, 0.95),
    max: sorted[sorted.length - 1],
    mean: sorted.reduce((total, value) => total + value, 0) / sorted.length,
  };
}

function summarizeProcessSamples(samples) {
  return {
    sampleCount: samples.length,
    rssBytes: summarizeNumbers(samples.map((sample) => sample.rssBytes)),
    cpuPercent: summarizeNumbers(samples.map((sample) => sample.cpuPercent)),
    rootFootprintBytes: summarizeNumbers(
      samples
        .map((sample) => sample.rootFootprintBytes)
        .filter((value) => value !== null),
    ),
    footprintAvailable: samples.some((sample) => sample.rootFootprintBytes !== null),
    processCount: Math.max(0, ...samples.map((sample) => sample.pids.length)),
  };
}

function waitForPanel(page, ariaLabel) {
  const selector = `section[aria-label="${ariaLabel}"]`;
  return (async () => {
    await page.locator(selector).waitFor({ state: 'visible' });
    await page.waitForFunction(
      (query) => !globalThis.document.querySelector(query)?.textContent?.includes('正在加载'),
      selector,
    );
  })();
}

async function goToTab(page, name, ariaLabel) {
  const start = performance.now();
  await page.getByRole('button', { name, exact: true }).click();
  await waitForPanel(page, ariaLabel);
  return performance.now() - start;
}

async function getSnapshot(page) {
  const result = await page.evaluate(() => globalThis.window.cocHelper.snapshot({}));
  if (!result.ok) {
    throw new Error(`app.snapshot 失败：${result.error.message}`);
  }
  return result.value;
}

async function importFixture(page, text, expectedTag) {
  await page.getByRole('button', { name: '导入', exact: true }).click();
  const input = page.locator('#account-json');
  await input.evaluate((element, value) => {
    const setter = Object.getOwnPropertyDescriptor(globalThis.HTMLTextAreaElement.prototype, 'value')?.set;
    if (setter === undefined) {
      throw new Error('无法设置账号 JSON textarea value');
    }
    setter.call(element, value);
    element.dispatchEvent(new globalThis.Event('input', { bubbles: true }));
    element.dispatchEvent(new globalThis.Event('change', { bubbles: true }));
  }, text);
  await page.waitForFunction(
    ({ selector, length }) =>
      (globalThis.document.querySelector(selector)?.value?.length ?? 0) === length,
    { selector: '#account-json', length: text.length },
  );
  await page.getByRole('button', { name: '解析预览', exact: true }).click();
  const preview = page.getByRole('region', { name: '导入预览' });
  await preview.waitFor({ state: 'visible' });
  const previewText = await preview.innerText();
  assert.match(previewText, new RegExp(expectedTag.replace('#', '\\#')));
  const preparedSnapshot = await getSnapshot(page);
  await preview.getByRole('button', { name: '确认导入', exact: true }).click();
  await page.waitForFunction(
    async (previousGeneration) => {
      const result = await globalThis.window.cocHelper.snapshot({});
      return result.ok && result.value.generation > previousGeneration;
    },
    preparedSnapshot.generation,
    { timeout: importTimeoutMs },
  );
  await page
    .getByRole('complementary', { name: '村庄列表' })
    .getByText(expectedTag, { exact: true })
    .waitFor({ state: 'visible', timeout: importTimeoutMs });
  await preview.waitFor({ state: 'detached' }).catch(() => undefined);
}

function markedFixture(text, markerField, marker) {
  const value = JSON.parse(text);
  value[markerField] = marker;
  return `${JSON.stringify(value)}\n`;
}

function villageRecord(id, name, accountOriginalText, importedAtMs) {
  return { id, name, accountOriginalText, accountImportedAtMs: importedAtMs };
}

function writeJson(file, value) {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function writeVillages(context, records, selectedVillageId = records[0]?.id ?? null) {
  writeJson(path.join(context.dataRoot, 'villages-v1.json'), records);
  writeJson(path.join(context.dataRoot, 'selection-v1.json'), { selectedVillageId });
}

function officialState(clanTag, parserVersion, lastGood) {
  const now = Date.now();
  return {
    status: 'success',
    ...(clanTag === undefined ? {} : { clanTag }),
    fetchedAt: now,
    lastAttemptAt: now,
    parserVersion,
    lastGood,
    unrecognizedKeys: [],
  };
}

function seedOfficialStates(context) {
  const clanTag = manifest.official.clanTag;
  const warLogItems = manifest.warLogPages.flatMap((file) => readJson(fixturePath(file)).items);
  const capitalItems = manifest.capitalRaidPages.flatMap((file) => readJson(fixturePath(file)).items);
  writeJson(path.join(context.dataRoot, 'player-states-v1.json'), [
    {
      [manifest.official.villageId]: officialState(undefined, 'player-snapshot-0.2', {
        tag: '#ANONYMIZED',
        name: 'perf-player',
        clan: { tag: clanTag, name: 'perf-clan' },
      }),
    },
  ]);
  writeJson(path.join(context.dataRoot, 'clans-v1.json'), [
    {
      [clanTag]: officialState(clanTag, 'clan-snapshot-0.4', {
        tag: clanTag,
        name: 'perf-clan',
        clanLevel: 12,
        members: 30,
        isWarLogPublic: manifest.official.warLogPublic,
      }),
    },
  ]);
  writeJson(path.join(context.dataRoot, 'clan-war-logs-v1.json'), [
    {
      [clanTag]: officialState(clanTag, 'clan-war-log-0.4', {
        page: { items: warLogItems },
        unrecognizedKeys: [],
      }),
    },
  ]);
  writeJson(path.join(context.dataRoot, 'clan-capitals-v1.json'), [
    {
      [clanTag]: officialState(clanTag, 'clan-capital-0.3', {
        page: { items: capitalItems },
        unrecognizedKeys: [],
      }),
    },
  ]);
}

async function prepareScenario(scenario, repetition) {
  const context = createContext(scenario, repetition);
  const importedAtMs = 1_785_736_933_000;
  const home = fixtureText(manifest.accountSnapshots.home.file);
  const builder = fixtureText(manifest.accountSnapshots.builder.file);
  const mixed = fixtureText(manifest.accountSnapshots.mixed.file);
  let session = null;
  let restartStartup = null;

  if (scenario === 'overview') {
    const ids = [
      '00000000-0000-4000-8000-000000000001',
      '00000000-0000-4000-8000-000000000002',
      '00000000-0000-4000-8000-000000000003',
    ];
    writeVillages(context, [
      villageRecord(ids[0], 'perf-home', home, importedAtMs),
      villageRecord(ids[1], 'perf-builder', builder, importedAtMs),
      villageRecord(ids[2], 'perf-mixed', mixed, importedAtMs),
    ]);
  } else if (scenario === 'official-lists') {
    const id = '00000000-0000-4000-8000-000000000011';
    writeVillages(context, [villageRecord(id, 'perf-official', home, importedAtMs)], id);
    manifest.official.villageId = id;
    seedOfficialStates(context);
  }

  try {
    session = await launchApp(context);

    if (scenario === 'village-detail') {
      const before = fixtureText(manifest.largeWalls.before);
      const after = fixtureText(manifest.largeWalls.after);
      await importFixture(pageOf(session), before, manifest.largeWalls.tag);
      await importFixture(pageOf(session), after, manifest.largeWalls.tag);
      await closeSession(session);
      session = await launchApp(context);
      restartStartup = session.startup;
    } else if (scenario === 'history-24') {
      const source = fixtureText(manifest.accountSnapshots[manifest.history24.source].file);
      for (let index = 0; index < manifest.history24.entries; index += 1) {
        await importFixture(
          pageOf(session),
          markedFixture(
            source,
            manifest.history24.markerField,
            `history-${String(index + 1).padStart(2, '0')}`,
          ),
          manifest.accountSnapshots[manifest.history24.source].tag,
        );
      }
      await closeSession(session);
      session = await launchApp(context);
      restartStartup = session.startup;
    }
  } catch (error) {
    await closeSession(session);
    rmSync(context.tempRoot, { recursive: true, force: true });
    throw error;
  }

  return { context, session, restartStartup };
}

function pageOf(session) {
  assert(session.page !== null, 'session page 尚未就绪');
  return session.page;
}

async function measureIpc(page, kind, villageId, clanTag) {
  return page.evaluate(
    async ({ requestKind, requestVillageId, requestClanTag }) => {
      const started = performance.now();
      let result;
      if (requestKind === 'snapshot') {
        result = await globalThis.window.cocHelper.snapshot({});
      } else if (requestKind === 'overview') {
        result = await globalThis.window.cocHelper.upgradeOverview({});
      } else if (requestKind === 'detail') {
        result = await globalThis.window.cocHelper.villageDetail({
          villageId: requestVillageId,
          base: 'home',
        });
      } else if (requestKind === 'warLog') {
        result = await globalThis.window.cocHelper.warLogState({ clanTag: requestClanTag });
      } else if (requestKind === 'capitalRaid') {
        result = await globalThis.window.cocHelper.capitalRaidState({ clanTag: requestClanTag });
      } else {
        throw new Error(`未知 IPC 性能样本：${requestKind}`);
      }
      const encoded = JSON.stringify(result);
      return {
        durationMs: performance.now() - started,
        payloadBytes: new TextEncoder().encode(encoded).byteLength,
        ok: result.ok,
      };
    },
    { requestKind: kind, requestVillageId: villageId, requestClanTag: clanTag },
  );
}

async function resourceSummary(page, probe, mark) {
  assert(probe !== null, 'catalog request probe 尚未安装');
  const requests = probe.summary(mark);
  const images = await page.evaluate(() => {
    const catalogImages = [...globalThis.document.images].filter((image) =>
      image.currentSrc.startsWith('cochelper://catalog/'),
    );
    return {
      imageCount: catalogImages.length,
      loadedImageCount: catalogImages.filter((image) => image.naturalWidth > 0).length,
      failedImageCount: catalogImages.filter((image) => image.complete && image.naturalWidth === 0)
        .length,
    };
  });
  return {
    ...requests,
    ...images,
    cacheObservation:
      requests.requestCount === 0 ? 'no-new-catalog-requests' : 'catalog-requests-observed',
  };
}

async function measureScroll(page, durationMs) {
  return page.evaluate(
    ({ duration }) =>
      new Promise((resolve) => {
        const target = globalThis.document.scrollingElement;
        if (target === null) {
          resolve({ durationMs: 0, frameCount: 0, longFrameCount: 0, hitchCount: 0, frameMs: summarize([]) });
          return;
        }
        const frameDurations = [];
        const started = performance.now();
        let previous = started;
        let direction = 1;
        const step = (now) => {
          frameDurations.push(now - previous);
          previous = now;
          const max = Math.max(0, target.scrollHeight - target.clientHeight);
          if (max > 0) {
            target.scrollTop += direction * Math.max(12, Math.round(target.clientHeight / 12));
            if (target.scrollTop >= max) direction = -1;
            if (target.scrollTop <= 0) direction = 1;
          }
          if (now - started >= duration) {
            target.scrollTop = 0;
            resolve({
              durationMs: now - started,
              frameCount: frameDurations.length,
              longFrameCount: frameDurations.filter((value) => value > 16.7).length,
              hitchCount: frameDurations.filter((value) => value > 50).length,
              frameMs: summarize(frameDurations),
            });
            return;
          }
          globalThis.requestAnimationFrame(step);
        };
        globalThis.requestAnimationFrame(step);

        function summarize(values) {
          const sorted = values.slice().sort((left, right) => left - right);
          if (sorted.length === 0) {
            return { count: 0, p50: null, p95: null, max: null };
          }
          return {
            count: sorted.length,
            p50: sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.5) - 1)],
            p95: sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * 0.95) - 1)],
            max: sorted[sorted.length - 1],
          };
        }
      }),
    { duration: durationMs },
  );
}

async function measureViews(session, includeOfficial) {
  const page = pageOf(session);
  const probe = session.catalogProbe;
  assert(probe !== null, 'catalog request probe 尚未安装');
  const snapshot = await getSnapshot(page);
  assert(snapshot.selectedVillageId !== null, '性能场景需要 selectedVillageId');

  // probe 在 renderer ready 前已安装；当前 session 的全部 catalog 请求属于 cold 视图。
  const overviewColdMark = 0;
  const overviewColdMs = await goToTab(page, '升级总览', '升级总览');
  await settleCatalogRequests(page, probe);
  const overviewColdResources = await resourceSummary(page, probe, overviewColdMark);
  const overviewIpc = await measureIpc(page, 'overview', snapshot.selectedVillageId, null);

  const detailColdMark = probe.mark();
  const detailColdMs = await goToTab(page, '村庄详情', '村庄详情');
  await settleCatalogRequests(page, probe);
  const detailColdResources = await resourceSummary(page, probe, detailColdMark);
  const detailIpc = await measureIpc(page, 'detail', snapshot.selectedVillageId, null);
  const detailScroll = await measureScroll(page, scrollMs);

  for (let index = 0; index < warmupCount; index += 1) {
    await goToTab(page, '升级总览', '升级总览');
    await settleCatalogRequests(page, probe);
    await goToTab(page, '村庄详情', '村庄详情');
    await settleCatalogRequests(page, probe);
  }

  const overviewHotMark = probe.mark();
  const overviewHotMs = await goToTab(page, '升级总览', '升级总览');
  await settleCatalogRequests(page, probe);
  const overviewHotResources = await resourceSummary(page, probe, overviewHotMark);

  const result = {
    navigationMs: {
      overviewCold: overviewColdMs,
      detailCold: detailColdMs,
      overviewHot: overviewHotMs,
    },
    resources: {
      overviewCold: overviewColdResources,
      detailCold: detailColdResources,
      overviewHot: overviewHotResources,
    },
    ipc: { overview: overviewIpc, detail: detailIpc },
    scroll: { detail: detailScroll },
  };

  if (includeOfficial) {
    const clanTag = manifest.official.clanTag;
    await goToTab(page, '村庄详情', '村庄详情');
    await settleCatalogRequests(page, probe);
    await page.locator('section[aria-label="部落对战日志"]').waitFor({ state: 'visible' });
    await page.locator('section[aria-label="突袭周末"]').waitFor({ state: 'visible' });
    const warLog = await measureIpc(page, 'warLog', snapshot.selectedVillageId, clanTag);
    const capitalRaid = await measureIpc(page, 'capitalRaid', snapshot.selectedVillageId, clanTag);
    const officialScroll = await measureScroll(page, scrollMs);
    result.ipc.warLog = warLog;
    result.ipc.capitalRaid = capitalRaid;
    result.scroll.official = officialScroll;
  }
  return result;
}

async function readRuntimeDiagnostics(page) {
  try {
    const result = await page.evaluate(() => globalThis.window.cocHelper.diagnosticsSnapshot({}));
    return result.ok ? result.value.runtime : null;
  } catch {
    return null;
  }
}

async function runScenario(scenario, repetition) {
  const prepared = await prepareScenario(scenario, repetition);
  const session = prepared.session;
  session.context = prepared.context;
  const page = pageOf(session);
  try {
    const snapshot = await getSnapshot(page);
    const views = await measureViews(session, scenario === 'official-lists');
    const runtime = await readRuntimeDiagnostics(page);
    return {
      scenario,
      repetition,
      startup: session.startup,
      restartStartup: prepared.restartStartup,
      selectedVillageId: snapshot.selectedVillageId,
      views,
      runtime,
    };
  } finally {
    await closeSession(session);
    rmSync(prepared.context.tempRoot, { recursive: true, force: true });
  }
}

function collectPath(runs, pathParts) {
  const values = [];
  for (const run of runs) {
    let value = run;
    for (const part of pathParts) value = value?.[part];
    if (typeof value === 'number') values.push(value);
  }
  return summarizeNumbers(values);
}

function formatNumber(value) {
  if (value === null || value === undefined) return 'unknown';
  if (!Number.isFinite(value)) return 'unknown';
  return Math.round(value).toLocaleString('en-US');
}

function formatBytes(value) {
  if (value === null || value === undefined) return 'unknown';
  return `${(value / (1024 * 1024)).toFixed(1)} MB`;
}

function buildSummary(runs) {
  return Object.fromEntries(
    SCENARIOS.map((scenario) => {
      const selected = runs.filter((run) => run.scenario === scenario);
      return [
        scenario,
        {
          runCount: selected.length,
          startupMs: collectPath(selected, ['startup', 'startupMs']),
          ttiMs: collectPath(selected, ['startup', 'ttiMs']),
          restartStartupMs: collectPath(selected, ['restartStartup', 'startupMs']),
          restartTtiMs: collectPath(selected, ['restartStartup', 'ttiMs']),
          overviewColdMs: collectPath(selected, ['views', 'navigationMs', 'overviewCold']),
          detailColdMs: collectPath(selected, ['views', 'navigationMs', 'detailCold']),
          overviewHotMs: collectPath(selected, ['views', 'navigationMs', 'overviewHot']),
          detailPayloadBytes: collectPath(selected, ['views', 'ipc', 'detail', 'payloadBytes']),
          overviewPayloadBytes: collectPath(selected, ['views', 'ipc', 'overview', 'payloadBytes']),
          warLogPayloadBytes: collectPath(selected, ['views', 'ipc', 'warLog', 'payloadBytes']),
          capitalRaidPayloadBytes: collectPath(selected, [
            'views',
            'ipc',
            'capitalRaid',
            'payloadBytes',
          ]),
          detailScrollFrameP95: collectPath(selected, [
            'views',
            'scroll',
            'detail',
            'frameMs',
            'p95',
          ]),
          detailScrollFrameMax: collectPath(selected, [
            'views',
            'scroll',
            'detail',
            'frameMs',
            'max',
          ]),
          detailScrollLongFrames: collectPath(selected, [
            'views',
            'scroll',
            'detail',
            'longFrameCount',
          ]),
          detailScrollHitches: collectPath(selected, [
            'views',
            'scroll',
            'detail',
            'hitchCount',
          ]),
          overviewColdIconRequests: collectPath(selected, [
            'views',
            'resources',
            'overviewCold',
            'requestCount',
          ]),
          detailColdIconRequests: collectPath(selected, [
            'views',
            'resources',
            'detailCold',
            'requestCount',
          ]),
          overviewHotIconRequests: collectPath(selected, [
            'views',
            'resources',
            'overviewHot',
            'requestCount',
          ]),
          peakRssBytes: collectPath(selected, ['startup', 'process', 'rssBytes', 'max']),
          startupCpuPercent: collectPath(selected, [
            'startup',
            'process',
            'cpuPercent',
            'p95',
          ]),
          peakFootprintBytes: collectPath(selected, [
            'startup',
            'process',
            'rootFootprintBytes',
            'max',
          ]),
        },
      ];
    }),
  );
}

function markdownReport(report) {
  const lines = [
    '# Electron Release 性能基线',
    '',
    `- protocol: ${report.protocol}`,
    `- generatedAt: ${report.generatedAt}`,
    `- commit: ${report.commitSha}`,
    `- platform: ${report.environment.platform}/${report.environment.arch}`,
    `- repetitions: ${report.options.repetitions}`,
    `- warmup: ${report.options.warmup}`,
    `- scrollMs: ${report.options.scrollMs}`,
    '',
    '> 本报告只记录 observed baseline；unknown 不等于 0，也不等于通过。',
    '',
    '| 场景 | 启动/CDP p50 | TTI p50 | Overview cold p50 | Detail cold p50 | Detail IPC p95 | 启动 CPU p95 | 启动峰值 RSS | 启动峰值 footprint |',
    '|---|---:|---:|---:|---:|---:|---:|---:|---:|',
  ];
  for (const scenario of SCENARIOS) {
    const summary = report.summary[scenario];
    lines.push(
      `| ${scenario} | ${formatNumber(summary.startupMs.p50)} ms | ${formatNumber(summary.ttiMs.p50)} ms | ${formatNumber(summary.overviewColdMs.p50)} ms | ${formatNumber(summary.detailColdMs.p50)} ms | ${formatNumber(summary.detailPayloadBytes.p95)} B | ${formatNumber(summary.startupCpuPercent.p95)}% | ${formatBytes(summary.peakRssBytes.max)} | ${formatBytes(summary.peakFootprintBytes.max)} |`,
    );
  }
  lines.push('', '## 图标冷/热缓存', '');
  lines.push(
    '| 场景 | Overview cold 新请求 p50 | Detail cold 新请求 p50 | Overview hot 新请求 p50 |',
    '|---|---:|---:|---:|',
  );
  for (const scenario of SCENARIOS) {
    const summary = report.summary[scenario];
    lines.push(
      `| ${scenario} | ${formatNumber(summary.overviewColdIconRequests.p50)} | ${formatNumber(summary.detailColdIconRequests.p50)} | ${formatNumber(summary.overviewHotIconRequests.p50)} |`,
    );
  }
  lines.push('', '## IPC payload', '');
  lines.push(
    '| 场景 | Overview p95 | Detail p95 | WarLog p95 | Capital Raid p95 |',
    '|---|---:|---:|---:|---:|',
  );
  for (const scenario of SCENARIOS) {
    const summary = report.summary[scenario];
    lines.push(
      `| ${scenario} | ${formatNumber(summary.overviewPayloadBytes.p95)} B | ${formatNumber(summary.detailPayloadBytes.p95)} B | ${formatNumber(summary.warLogPayloadBytes.p95)} B | ${formatNumber(summary.capitalRaidPayloadBytes.p95)} B |`,
    );
  }
  lines.push('', '## 滚动', '');
  lines.push(
    '| 场景 | Detail frame p95 | Detail frame max | >16.7ms 帧 | >50ms hitch |',
    '|---|---:|---:|---:|---:|',
  );
  for (const scenario of SCENARIOS) {
    const summary = report.summary[scenario];
    lines.push(
      `| ${scenario} | ${formatNumber(summary.detailScrollFrameP95.p50)} ms | ${formatNumber(summary.detailScrollFrameMax.p50)} ms | ${formatNumber(summary.detailScrollLongFrames.p50)} | ${formatNumber(summary.detailScrollHitches.p50)} |`,
    );
  }
  lines.push('', '## 采样边界', '');
  lines.push(
    '- 启动/CDP 是从 spawn 到 remote debugging endpoint 可用；TTI 是从 spawn 到 renderer app-shell `data-smoke=ready`。',
    '- RSS 统计 packaged app 进程树；footprint 当前仅统计主进程，平台不支持时为 unknown。',
    '- IPC payload 是 bridge 返回 Result 的 JSON UTF-8 字节数，不声称等于 Chromium 内部 structured-clone 字节数。',
    '- 图标冷/热请求来自 Playwright catalog protocol request 事件；hot=0 表示该视图未观察到新的 catalog 请求，不等于证明所有缓存层命中。',
    '- 滚动指标来自 renderer requestAnimationFrame 间隔；未把空 hitch 表解释为无卡顿。',
    '- 原始进程日志和临时数据不进入报告。',
  );
  return `${lines.join('\n')}\n`;
}

async function main() {
  mkdirSync(outputDir, { recursive: true });
  const runs = [];
  const failures = [];
  for (const scenario of selectedScenarios) {
    for (let repetition = 1; repetition <= repetitions; repetition += 1) {
      process.stdout.write(`\n[perf] ${scenario} repetition=${repetition}/${repetitions}\n`);
      try {
        runs.push(await runScenario(scenario, repetition));
      } catch (error) {
        const failure = {
          scenario,
          repetition,
          message: error instanceof Error ? error.message : String(error),
        };
        failures.push(failure);
        console.error(`[perf] 失败：${failure.message}`);
      }
    }
  }

  const report = {
    protocol: manifest.protocol,
    generatedAt: new Date().toISOString(),
    commitSha: getCommitSha(),
    binary,
    environment: {
      platform: process.platform,
      arch: process.arch,
      node: process.version,
    },
    options: { scenario: scenarioArg, repetitions, warmup: warmupCount, scrollMs },
    manifest,
    summary: buildSummary(runs),
    runs,
    failures,
    status: failures.length === 0 && runs.length > 0 ? 'observed' : 'partial',
  };
  writeFileSync(path.join(outputDir, 'report.json'), `${JSON.stringify(report, null, 2)}\n`);
  writeFileSync(path.join(outputDir, 'report.md'), markdownReport(report));
  console.log(`\n[perf] report: ${path.join(outputDir, 'report.md')}`);
  if (failures.length > 0 || runs.length === 0) {
    process.exitCode = 1;
  }
}

try {
  await main();
} finally {
  for (const session of [...sessions]) {
    await closeSession(session);
  }
}
