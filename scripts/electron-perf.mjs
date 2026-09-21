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
import { execFile, spawn } from 'node:child_process';
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
import { promisify } from 'node:util';

import { chromium } from 'playwright-core';

import { readPackagedBuildProvenance, resolvePackagedBinary } from './electron-package.mjs';
import { FROZEN_RELEASE_BASELINE, validatePerfProfile } from './perf-config.mjs';
import { startPerfFixtureApiServer } from './perf-fixture-server.mjs';
import {
  collectProcessMetric,
  collectTracePhase,
  summarizeNumbers,
  summarizeProcessSamples,
} from './perf-metrics.mjs';
import { readGitProvenance } from './perf-provenance.mjs';
import {
  evaluateWithTimeout,
  PerfTimeoutError,
  remainingTimeoutMs,
} from './perf-timeouts.mjs';

const execFileAsync = promisify(execFile);

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = path.join(root, 'e2e/fixtures/perf-manifest.json');
const manifest = readJson(manifestPath);
const sourceProvenance = readGitProvenance(root);
if (sourceProvenance.commitSha === 'unknown') {
  throw new Error('无法读取当前源码 commit，不能绑定 packaged binary provenance');
}
if (sourceProvenance.dirty) {
  throw new Error('当前 worktree 有未提交源码变更，请先提交后再运行 perf:release');
}
const binary = resolvePackagedBinary(root, sourceProvenance.commitSha);
const binaryProvenance = readPackagedBuildProvenance(binary);
if (binaryProvenance === null) {
  throw new Error('packaged binary 缺少有效的 perf-build-provenance.json');
}
const runId = `${new Date().toISOString().replaceAll(':', '-')}-${process.pid}`;
const defaultOutput = path.join(root, 'e2e-artifacts', 'perf', runId);

const scenarioArg = optionValue('--scenario') ?? process.env.COCHELPER_PERF_SCENARIO ?? 'all';
const profile = optionValue('--profile') ?? process.env.COCHELPER_PERF_PROFILE ?? 'diagnostic';
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
const bridgeCallTimeoutMs = 10_000;
const diagnosticsTimeoutMs = 5_000;
const scrollGraceTimeoutMs = 5_000;
const processSampleIntervalMs = FROZEN_RELEASE_BASELINE.processSampleIntervalMs;
const footprintSampleEvery = FROZEN_RELEASE_BASELINE.footprintSampleEvery;
const failureOutputMaxChars = 20_000;

const SCENARIOS = ['overview', 'village-detail', 'history-24', 'official-lists'];
const PERFORMANCE_TRACE_PREFIX = 'COCHELPER_PERF_PHASE ';
const PERFORMANCE_TRACE_PHASES = [
  { key: 'importParse', scope: 'import', phase: 'parse' },
  { key: 'historyLoad', scope: 'history', phase: 'load' },
  { key: 'historyCanonicalization', scope: 'history', phase: 'canonicalization' },
  { key: 'reconciliationBuild', scope: 'reconciliation', phase: 'build' },
  { key: 'reconciliationDiff', scope: 'reconciliation', phase: 'diff' },
  { key: 'historyValidateInput', scope: 'history', phase: 'validate-input' },
  { key: 'historyValidatePrevious', scope: 'history', phase: 'validate-previous-history' },
  { key: 'historyValidateWire', scope: 'history', phase: 'validate-wire-history' },
  { key: 'storageCommit', scope: 'storage', phase: 'commit' },
  { key: 'storageWrite', scope: 'storage', phase: 'write' },
  { key: 'projectionCatalog', scope: 'projection', phase: 'catalog' },
  { key: 'projectionDetailRows', scope: 'projection', phase: 'detail-rows' },
  { key: 'projectionDetailDto', scope: 'projection', phase: 'detail-dto' },
];
const selectedScenarios = scenarioArg === 'all' ? SCENARIOS : scenarioArg.split(',').filter(Boolean);
for (const scenario of selectedScenarios) {
  if (!SCENARIOS.includes(scenario)) {
    throw new Error(`未知性能场景：${scenario}；可选值：${SCENARIOS.join(', ')}`);
  }
}
const profileContract = validatePerfProfile({
  profile,
  scenario: scenarioArg,
  repetitions,
  warmup: warmupCount,
  scrollMs,
});

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

async function connectOverCDPWithTimeout(endpoint, timeoutMs) {
  let timedOut = false;
  let timer;
  const connection = chromium.connectOverCDP(endpoint);
  const observedConnection = connection.then(
    async (browser) => {
      if (timedOut) {
        await withTimeout(browser.close().catch(() => undefined), 5_000, undefined);
        return null;
      }
      return browser;
    },
    (error) => {
      if (timedOut) {
        return null;
      }
      throw error;
    },
  );
  try {
    return await Promise.race([
      observedConnection,
      new Promise((resolve) => {
        timer = setTimeout(() => {
          timedOut = true;
          resolve(null);
        }, timeoutMs);
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

function fixturePage(file) {
  const value = readJson(fixturePath(file));
  assert(Array.isArray(value.items), `分页 fixture items 无效：${file}`);
  const cursors = value.paging?.cursors;
  return {
    items: value.items,
    before: cursors?.before,
    after: cursors?.after,
  };
}

async function startFixtureApiServer() {
  return startPerfFixtureApiServer({
    warLogPages: manifest.warLogPages,
    capitalRaidPages: manifest.capitalRaidPages,
    readPage: fixturePage,
    readText: fixtureText,
  });
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
  const output = { stdout: '', stderr: '', phaseEvents: [], partialLine: '' };
  child.stdout.on('data', (chunk) => {
    const text = chunk.toString();
    collectPerformanceTraceEvents(output, text);
    output.stdout = appendTail(output.stdout, text, failureOutputMaxChars);
    process.stdout.write(text);
  });
  child.stderr.on('data', (chunk) => {
    const text = chunk.toString();
    output.stderr = appendTail(output.stderr, text, failureOutputMaxChars);
    process.stderr.write(text);
  });
  return output;
}

function collectPerformanceTraceEvents(output, text) {
  const lines = `${output.partialLine}${text}`.split('\n');
  output.partialLine = lines.pop() ?? '';
  for (const line of lines) {
    if (!line.startsWith(PERFORMANCE_TRACE_PREFIX)) {
      continue;
    }
    try {
      const event = JSON.parse(line.slice(PERFORMANCE_TRACE_PREFIX.length));
      if (
        typeof event?.scope === 'string' &&
        typeof event?.phase === 'string' &&
        typeof event?.durationMs === 'number'
      ) {
        output.phaseEvents.push(event);
      }
    } catch {
      // Keep raw child output for failure diagnostics; malformed trace lines are ignored.
    }
  }
}

function appendTail(previous, next, maxChars) {
  const combined = `${previous}${next}`;
  return combined.length <= maxChars ? combined : combined.slice(-maxChars);
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
  if (probe.pendingCount() > 0) {
    throw new Error(`catalog 请求在 ${5_000}ms 后仍未完成：${probe.pendingCount()}`);
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
    apiServer: null,
    phase: 'setup',
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
    ...(context.apiServer === null
      ? {}
      : {
          COCHELPER_PERF_API_HOST: `127.0.0.1:${context.apiServer.port}`,
          COCHELPER_PERF_API_SCHEME: 'http',
          COCHELPER_PERF_API_TOKEN: 'perf-fixture-token',
        }),
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
  context.phase = 'launch:spawn';
  const port = await findFreePort();
  const spawnAt = performance.now();
  const child = spawn(
    binary,
    [
      `--user-data-dir=${context.userDataDirectory}`,
      '--remote-debugging-address=127.0.0.1',
      `--remote-debugging-port=${port}`,
      ...(context.apiServer === null ? [] : ['--perf-fixture']),
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
    processSampler: null,
    knownPids: new Set([child.pid]),
    port,
    spawnAt,
    startup: null,
  };
  sessions.add(session);
  let startupSampler = null;
  try {
    startupSampler = await startProcessSampler(session, context.tempRoot);
    session.processSampler = startupSampler;
    const endpoint = await waitForDevTools(child, port);
    const devToolsReadyAt = performance.now();
    session.browser = await connectOverCDPWithTimeout(endpoint, 20_000);
    if (session.browser === null) {
      throw new Error('连接 packaged app CDP 超时');
    }
    session.page = await waitForRendererReady(session.browser, (page) => {
      session.catalogProbe = attachCatalogRequestProbe(page);
    });
    const rendererReadyAt = performance.now();
    const startupProcess = await startupSampler.snapshot();
    await settleCatalogRequests(session.page, session.catalogProbe);
    session.startup = {
      // startupMs 是进程启动到 CDP 可用；ttiMs 是到 renderer app-shell ready。
      startupMs: devToolsReadyAt - spawnAt,
      ttiMs: rendererReadyAt - spawnAt,
      process: startupProcess,
    };
    return session;
  } catch (error) {
    const diagnostics = await captureFailureDiagnostics(context, session, error);
    try {
      await startupSampler?.stop();
    } catch {
      // closeSession records sampler failures together with process cleanup failures.
    }
    const cleanupError = await closeSession(session);
    if (cleanupError !== null) {
      throw attachFailureDiagnostics(
        new AggregateError([error, cleanupError], 'packaged app launch cleanup failed'),
        diagnostics,
      );
    }
    throw attachFailureDiagnostics(error, diagnostics);
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
    return null;
  }
  const failures = [];
  if (session.processSampler !== null) {
    try {
      session.processFinal = await session.processSampler.stop();
    } catch (error) {
      failures.push(`process sampler: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  if (session.browser !== null) {
    const browserClosed = await withTimeout(
      session.browser
        .close()
        .then(() => true)
        .catch(() => false),
      5_000,
      false,
    );
    if (browserClosed) {
      session.browser = null;
    } else {
      failures.push('browser close 超时或失败');
    }
  }
  session.knownPids.add(session.child.pid);
  const childAlive = () => session.child.exitCode === null && session.child.signalCode === null;
  if (childAlive()) {
    try {
      session.child.kill('SIGTERM');
    } catch (error) {
      failures.push(`SIGTERM 失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }
  signalKnownProcesses(session, 'SIGTERM', failures);
  await waitForExit(session.child, 10_000);
  if (childAlive()) {
    try {
      session.child.kill('SIGKILL');
    } catch (error) {
      failures.push(`SIGKILL 失败：${error instanceof Error ? error.message : String(error)}`);
    }
  }
  signalKnownProcesses(session, 'SIGKILL', failures);
  await waitForExit(session.child, 5_000);
  const processTreeStatus = await waitForKnownProcessesExit(session, 5_000);
  if (processTreeStatus.kind === 'unknown') {
    failures.push(processTreeStatus.message);
  } else if (processTreeStatus.kind === 'timeout') {
    failures.push(
      `packaged app process tree 在 cleanup 超时后仍存活：${processTreeStatus.pids.join(',')}`,
    );
  }
  if (childAlive()) {
    failures.push('packaged app 在 SIGKILL 后仍未退出');
  }
  sessions.delete(session);
  if (failures.length > 0) {
    session.cleanupError = failures.join('; ');
    return new Error(`session cleanup failed: ${session.cleanupError}`);
  }
  return null;
}

function signalKnownProcesses(session, signal, failures) {
  for (const pid of session.knownPids) {
    if (pid === process.pid || pid === session.child.pid) {
      continue;
    }
    try {
      process.kill(pid, signal);
    } catch (error) {
      if (error?.code !== 'ESRCH') {
        failures.push(`${signal} PID ${pid} 失败：${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }
}

async function closeSessionOrThrow(session) {
  const cleanupError = await closeSession(session);
  if (cleanupError !== null) {
    throw cleanupError;
  }
}

async function closeContextServer(context) {
  if (context.apiServer === null) {
    return null;
  }
  try {
    await context.apiServer.close();
    return null;
  } catch (error) {
    return error instanceof Error ? error : new Error(String(error));
  }
}

async function waitForKnownProcessesExit(session, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastPids = [...session.knownPids];
  while (Date.now() < deadline) {
    const rows = await psRows();
    if (rows === null) {
      return { kind: 'unknown', message: '无法用 ps 验证 packaged app process tree 是否退出' };
    }
    lastPids = rows
      .filter((row) => session.knownPids.has(row.pid))
      .map((row) => row.pid);
    if (lastPids.length === 0) {
      return { kind: 'gone' };
    }
    await sleep(100);
  }
  return { kind: 'timeout', pids: lastPids };
}

async function psRows() {
  try {
    const { stdout } = await execFileAsync('ps', ['-axo', 'pid=,ppid=,rss=,%cpu=,command='], {
      encoding: 'utf8',
      timeout: 5_000,
      killSignal: 'SIGTERM',
      maxBuffer: 1_048_576,
    });
    const rows = stdout
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
    return rows.length === 0 ? null : rows;
  } catch {
    return null;
  }
}

async function processTree(rootPid) {
  const rows = await psRows();
  if (rows === null) {
    return null;
  }
  if (!rows.some((row) => row.pid === rootPid)) {
    return null;
  }
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

async function footprintForPid(pid, tempRoot) {
  if (process.platform !== 'darwin' || !existsSync('/usr/bin/footprint')) {
    return null;
  }
  const jsonPath = path.join(tempRoot, `footprint-${pid}.json`);
  try {
    await execFileAsync('/usr/bin/footprint', ['-j', jsonPath, String(pid)], {
      encoding: 'utf8',
      timeout: 5_000,
      killSignal: 'SIGTERM',
      maxBuffer: 1_048_576,
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

async function sampleProcess(session, tempRoot, index, forceFootprint = false) {
  const startedAt = performance.now();
  const rows = await processTree(session.child.pid);
  if (rows === null) {
    const atMs = performance.now();
    return {
      atMs,
      pids: null,
      rssBytes: null,
      cpuPercent: null,
      rootFootprintBytes: null,
      samplingDurationMs: atMs - startedAt,
    };
  }
  for (const row of rows) {
    session.knownPids.add(row.pid);
  }
  const rootFootprintBytes =
    forceFootprint || index % footprintSampleEvery === 0
      ? await footprintForPid(session.child.pid, tempRoot)
      : null;
  const atMs = performance.now();
  return {
    atMs,
    pids: rows.map((row) => row.pid),
    rssBytes: rows.reduce((total, row) => total + row.rssBytes, 0),
    cpuPercent: rows.reduce((total, row) => total + row.cpuPercent, 0),
    rootFootprintBytes,
    samplingDurationMs: atMs - startedAt,
  };
}

async function startProcessSampler(session, tempRoot) {
  const samples = [];
  let index = 0;
  let stopped = false;
  let inFlight = false;
  let tail = Promise.resolve();
  const collect = async (forceFootprint = false) => {
    samples.push(await sampleProcess(session, tempRoot, index, forceFootprint));
    index += 1;
  };
  const enqueue = (forceFootprint = false) => {
    if (!forceFootprint && inFlight) {
      return tail;
    }
    inFlight = true;
    const run = async () => {
      try {
        await collect(forceFootprint);
      } finally {
        inFlight = false;
      }
    };
    tail = tail.then(run, run);
    return tail;
  };
  await enqueue(true);
  const timer = setInterval(() => {
    void enqueue().catch(() => undefined);
  }, processSampleIntervalMs);
  return {
    async mark() {
      await enqueue(true);
      return samples.length;
    },
    async snapshot() {
      await enqueue(true);
      return summarizeProcessSamples(samples);
    },
    async summarySince(mark) {
      await enqueue(true);
      return summarizeProcessSamples(samples.slice(mark));
    },
    async stop() {
      if (!stopped) {
        clearInterval(timer);
        await enqueue(true);
        stopped = true;
      }
      return summarizeProcessSamples(samples);
    },
  };
}

function waitForPanel(page, ariaLabel) {
  const selector = `section[aria-label="${ariaLabel}"]`;
  const panel = page.locator(selector);
  return (async () => {
    await panel.waitFor({ state: 'visible' });
    await page.waitForFunction(
      (query) => {
        const element = globalThis.document.querySelector(query);
        const state = element?.getAttribute('data-perf-state');
        return state !== null && state !== 'loading';
      },
      selector,
    );
    const evidence = await panel.evaluate((element) => ({
      state: element.getAttribute('data-perf-state'),
      alertCount: element.querySelectorAll('[role="alert"]').length,
      retryCount: [...element.querySelectorAll('button')].filter(
        (button) => button.textContent?.trim() === '重试',
      ).length,
    }));
    if (evidence.state !== 'ready') {
      throw new Error(`${ariaLabel} renderer 未进入 ready 状态：${evidence.state ?? 'missing'}`);
    }
    if (evidence.alertCount > 0 || evidence.retryCount > 0) {
      throw new Error(
        `${ariaLabel} renderer 存在错误状态：alert=${evidence.alertCount}, retry=${evidence.retryCount}`,
      );
    }
  })();
}

async function goToTab(page, name, ariaLabel) {
  const start = performance.now();
  await page.getByRole('button', { name, exact: true }).click();
  await waitForPanel(page, ariaLabel);
  return performance.now() - start;
}

async function getSnapshot(page, timeoutMs = bridgeCallTimeoutMs) {
  const result = await evaluateWithTimeout(
    page,
    () => globalThis.window.cocHelper.snapshot({}),
    undefined,
    timeoutMs,
    'app.snapshot',
  );
  if (!result.ok) {
    throw new Error(`app.snapshot 失败：${result.error.message}`);
  }
  return result.value;
}

async function waitForCommittedImport(page, previousGeneration, expectedTag, deadline) {
  let lastSnapshot = null;
  while (Date.now() < deadline) {
    const remainingMs = deadline - Date.now();
    try {
      lastSnapshot = await getSnapshot(page, Math.min(bridgeCallTimeoutMs, remainingMs));
    } catch (error) {
      if (error instanceof PerfTimeoutError) {
        throw new Error(`等待导入提交时 app.snapshot 超时：${error.message}`);
      }
      throw error;
    }
    const committed =
      lastSnapshot.generation > previousGeneration &&
      lastSnapshot.pendingImport === null &&
      lastSnapshot.villages.some(
        (village) => village.tag === expectedTag && village.hasImportedData === true,
      );
    if (committed) {
      return lastSnapshot;
    }
    await sleep(Math.min(250, Math.max(1, deadline - Date.now())));
  }
  throw new Error(
    `导入提交未完成：${JSON.stringify({
      previousGeneration,
      expectedTag,
      snapshot: lastSnapshot,
    })}`,
  );
}

async function importFixture(page, text, expectedTag, context, label) {
  context.phase = `${label}:open-import`;
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
  context.phase = `${label}:prepare`;
  await page.getByRole('button', { name: '解析预览', exact: true }).click();
  const preview = page.getByRole('region', { name: '导入预览' });
  await preview.waitFor({ state: 'visible' });
  const previewText = await preview.innerText();
  assert.match(previewText, new RegExp(expectedTag.replace('#', '\\#')));
  const preparedSnapshot = await getSnapshot(page);
  context.lastImport = {
    label,
    expectedTag,
    preparedGeneration: preparedSnapshot.generation,
    preparedPendingImport: preparedSnapshot.pendingImport,
  };
  context.phase = `${label}:commit`;
  const confirmButton = preview.getByRole('button', { name: '确认导入', exact: true });
  if (!(await confirmButton.isEnabled())) {
    throw new Error(`确认导入按钮不可用：${previewText}`);
  }

  /**
   * Fixture 注入边界：UI 预览与 enabled 状态仍通过 renderer 验证；实际提交使用同一
   * typed bridge 和 prepared generation，以便 runner 能对 IPC Result 施加 hard timeout，
   * 不依赖 renderer hook 的本地 cursor 生命周期。
  */
  const importDeadline = Date.now() + importTimeoutMs;
  context.phase = `${label}:bridge-commit`;
  const commitTimeoutMs = remainingTimeoutMs(importDeadline, 'import.commit');
  const commitResult = await evaluateWithTimeout(
    page,
    (expectedGeneration) =>
      globalThis.window.cocHelper.commitImport({ expectedGeneration }),
    preparedSnapshot.generation,
    commitTimeoutMs,
    'import.commit',
  );
  context.lastImport = {
    ...context.lastImport,
    commitResult: commitResult.ok
      ? { ok: true, value: commitResult.value }
      : { ok: false, error: commitResult.error },
  };
  if (!commitResult.ok) {
    throw new Error(`导入提交失败：${commitResult.error.message}`);
  }
  assert(
    commitResult.value.generation > preparedSnapshot.generation,
    `导入提交 generation 未推进：${commitResult.value.generation}`,
  );
  const targetVillageId = preparedSnapshot.pendingImport?.targetVillageId ?? null;
  if (targetVillageId !== null) {
    assert.equal(
      commitResult.value.selectedVillageId,
      targetVillageId,
      '导入提交 selectedVillageId 与目标村庄不一致',
    );
  }
  context.phase = `${label}:wait-commit-state`;
  await waitForCommittedImport(page, preparedSnapshot.generation, expectedTag, importDeadline);
  context.lastImport = {
    ...context.lastImport,
    commitStateObserved: true,
  };
  context.phase = `${label}:wait-sidebar`;
  const sidebarTimeoutMs = remainingTimeoutMs(importDeadline, 'import sidebar');
  await page
    .getByRole('complementary', { name: '村庄列表' })
    .getByText(expectedTag, { exact: true })
    .waitFor({ state: 'visible', timeout: sidebarTimeoutMs });
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

function officialState(parserVersion, lastGood, ownership = {}) {
  const now = Date.now();
  return {
    status: 'success',
    ...(ownership.clanTag === undefined ? {} : { clanTag: ownership.clanTag }),
    ...(ownership.playerTag === undefined ? {} : { playerTag: ownership.playerTag }),
    fetchedAt: now,
    lastAttemptAt: now,
    parserVersion,
    lastGood,
    unrecognizedKeys: [],
  };
}

function seedOfficialStates(context, villageId) {
  const clanTag = manifest.official.clanTag;
  const playerTag = manifest.official.playerTag;
  writeJson(path.join(context.dataRoot, 'player-states-v1.json'), [
    {
      [villageId]: officialState('player-snapshot-0.2', {
        tag: '#ANONYMIZED',
        name: 'perf-player',
        clan: { tag: clanTag, name: 'perf-clan' },
      }, { playerTag }),
    },
  ]);
  writeJson(path.join(context.dataRoot, 'clans-v1.json'), [
    {
      [clanTag]: officialState('clan-snapshot-0.4', {
        tag: clanTag,
        name: 'perf-clan',
        clanLevel: 12,
        members: 30,
        isWarLogPublic: manifest.official.warLogPublic,
      }, { clanTag }),
    },
  ]);
  writeJson(path.join(context.dataRoot, 'clan-war-logs-v1.json'), [
    {
      [clanTag]: officialState('clan-war-log-0.4', {
        page: fixturePage(manifest.warLogPages[0]),
        unrecognizedKeys: [],
      }, { clanTag }),
    },
  ]);
  writeJson(path.join(context.dataRoot, 'clan-capitals-v1.json'), [
    {
      [clanTag]: officialState('clan-capital-0.3', {
        page: fixturePage(manifest.capitalRaidPages[0]),
        unrecognizedKeys: [],
      }, { clanTag }),
    },
  ]);
}

async function prepareScenario(scenario, repetition) {
  const context = createContext(scenario, repetition);
  const importedAtMs = 1_785_736_933_000;
  const home = fixtureText(manifest.accountSnapshots.home.file);
  const builder = fixtureText(manifest.accountSnapshots.builder.file);
  const mixed = fixtureText(manifest.accountSnapshots.mixed.file);
  const variant = fixtureText(manifest.accountSnapshots.variant.file);
  let session = null;
  let initialStartup = null;
  let restartStartup = null;
  let preparation = null;

  if (scenario === 'overview') {
    const ids = [
      '00000000-0000-4000-8000-000000000001',
      '00000000-0000-4000-8000-000000000002',
      '00000000-0000-4000-8000-000000000003',
      '00000000-0000-4000-8000-000000000004',
    ];
    writeVillages(context, [
      villageRecord(ids[0], 'perf-home', home, importedAtMs),
      villageRecord(ids[1], 'perf-builder', builder, importedAtMs),
      villageRecord(ids[2], 'perf-mixed', mixed, importedAtMs),
      villageRecord(ids[3], 'perf-variant', variant, importedAtMs),
    ]);
  } else if (scenario === 'official-lists') {
    const id = '00000000-0000-4000-8000-000000000011';
    writeVillages(context, [villageRecord(id, 'perf-official', home, importedAtMs)], id);
    context.apiServer = await startFixtureApiServer();
    seedOfficialStates(context, id);
  }

  try {
    session = await launchApp(context);
    initialStartup = session.startup;
    context.phase = 'prepare:ready';

    if (scenario === 'village-detail') {
      const before = fixtureText(manifest.largeWalls.before);
      const after = fixtureText(manifest.largeWalls.after);
      const imports = [];
      for (const [label, text] of [
        ['before', before],
        ['after', after],
      ]) {
        const startedAt = performance.now();
        const mark = await session.processSampler.mark();
        await importFixture(
          pageOf(session),
          text,
          manifest.largeWalls.tag,
          context,
          `prepare:large-walls:${label}`,
        );
        imports.push({
          label,
          durationMs: performance.now() - startedAt,
          process: await session.processSampler.summarySince(mark),
        });
      }
      preparation = {
        kind: 'large-walls-import',
        imports,
        process: await session.processSampler.snapshot(),
      };
      context.phase = 'restart:close-initial';
      await closeSessionOrThrow(session);
      context.phase = 'restart:launch-final';
      session = await launchApp(context);
      restartStartup = session.startup;
    } else if (scenario === 'history-24') {
      const source = fixtureText(manifest.accountSnapshots[manifest.history24.source].file);
      const imports = [];
      for (let index = 0; index < manifest.history24.entries; index += 1) {
        const startedAt = performance.now();
        const mark = await session.processSampler.mark();
        await importFixture(
          pageOf(session),
          markedFixture(
            source,
            manifest.history24.markerField,
            `history-${String(index + 1).padStart(2, '0')}`,
          ),
          manifest.accountSnapshots[manifest.history24.source].tag,
          context,
          `prepare:history-24:${String(index + 1).padStart(2, '0')}`,
        );
        imports.push({
          index: index + 1,
          durationMs: performance.now() - startedAt,
          process: await session.processSampler.summarySince(mark),
        });
      }
      preparation = {
        kind: 'history-import',
        imports,
        process: await session.processSampler.snapshot(),
      };
      context.phase = 'restart:close-initial';
      await closeSessionOrThrow(session);
      context.phase = 'restart:launch-final';
      session = await launchApp(context);
      restartStartup = session.startup;
    }
  } catch (error) {
    const diagnostics = await captureFailureDiagnostics(context, session, error);
    const cleanupErrors = [];
    const sessionCleanupError = await closeSession(session);
    if (sessionCleanupError !== null) cleanupErrors.push(sessionCleanupError);
    const serverCleanupError = await closeContextServer(context);
    if (serverCleanupError !== null) cleanupErrors.push(serverCleanupError);
    rmSync(context.tempRoot, { recursive: true, force: true });
    if (cleanupErrors.length > 0) {
      throw attachFailureDiagnostics(
        new AggregateError([error, ...cleanupErrors], 'scenario preparation cleanup failed'),
        diagnostics,
      );
    }
    throw attachFailureDiagnostics(error, diagnostics);
  }

  return { context, session, initialStartup, preparation, restartStartup };
}

function pageOf(session) {
  assert(session.page !== null, 'session page 尚未就绪');
  return session.page;
}

async function captureFailureDiagnostics(context, session, error) {
  const diagnostics = {
    phase: context?.phase ?? 'unknown',
    error: {
      message: error instanceof Error ? error.message : String(error),
      stack: error instanceof Error ? error.stack ?? null : null,
    },
    snapshot: null,
    renderer: null,
    process: null,
    import: context?.lastImport ?? null,
    appOutput: session?.output ?? null,
    session: session
      ? {
          startup: session.startup,
          childPid: session.child.pid,
          knownPids: [...session.knownPids],
          exitCode: session.child.exitCode,
          signalCode: session.child.signalCode,
        }
      : null,
  };
  if (session?.page !== null && session?.page !== undefined) {
    try {
      const pageEvidence = await evaluateWithTimeout(
        session.page,
        async (maxTextChars) => {
          const boundedText = (value) => {
            const text = value ?? '';
            return text.length <= maxTextChars ? text : text.slice(-maxTextChars);
          };
          const snapshotResult = await globalThis.window.cocHelper.snapshot({});
          const snapshot = snapshotResult.ok
            ? {
                sessionId: snapshotResult.value.sessionId,
                generation: snapshotResult.value.generation,
                availability: snapshotResult.value.availability,
                villageStatus: snapshotResult.value.villageStatus,
                villageError: snapshotResult.value.villageError,
                selectedVillageId: snapshotResult.value.selectedVillageId,
                canWrite: snapshotResult.value.canWrite,
                hasPendingJournal: snapshotResult.value.hasPendingJournal,
                recoveryNotice: snapshotResult.value.recoveryNotice,
                pendingImport: snapshotResult.value.pendingImport,
                villages: snapshotResult.value.villages.slice(0, 64),
              }
            : { ok: false, error: snapshotResult.error };
          const panelEvidence = (selector) => {
            const panel = globalThis.document.querySelector(selector);
            if (panel === null) return null;
            return {
              state: panel.getAttribute('data-perf-state'),
              text: boundedText(panel.textContent),
              alertCount: panel.querySelectorAll('[role="alert"]').length,
              retryCount: [...panel.querySelectorAll('button')].filter(
                (button) => button.textContent?.trim() === '重试',
              ).length,
              buttons: [...panel.querySelectorAll('button')].slice(0, 64).map((button) => ({
                text: boundedText(button.textContent?.trim() ?? ''),
                disabled: button.disabled,
              })),
              textareas: [...panel.querySelectorAll('textarea')].slice(0, 16).map((textarea) => ({
                disabled: textarea.disabled,
                valueLength: textarea.value.length,
              })),
            };
          };
          return {
            snapshot,
            sidebarText: boundedText(
              globalThis.document.querySelector('[role="complementary"][aria-label="村庄列表"]')
                ?.textContent,
            ),
            statusText: boundedText(globalThis.document.getElementById('status')?.textContent),
            appShell: (() => {
              const shell = globalThis.document.querySelector('.app-shell');
              return shell === null
                ? null
                : {
                    smoke: shell.getAttribute('data-smoke'),
                    availability: shell.getAttribute('data-availability'),
                    canWrite: shell.getAttribute('data-can-write'),
                  };
            })(),
            alerts: [...globalThis.document.querySelectorAll('[role="alert"]')]
              .slice(0, 64)
              .map((element) => boundedText(element.textContent?.trim() ?? '')),
            bodyText: boundedText(globalThis.document.body.innerText ?? ''),
            import: panelEvidence('section[aria-label="账号导入"]'),
            overview: panelEvidence('section[aria-label="升级总览"]'),
            detail: panelEvidence('section[aria-label="村庄详情"]'),
          };
        },
        failureOutputMaxChars,
        diagnosticsTimeoutMs,
        'failure diagnostics',
      );
      diagnostics.snapshot = pageEvidence.snapshot;
      diagnostics.renderer = {
          sidebarText: appendTail(pageEvidence.sidebarText ?? '', '', failureOutputMaxChars),
          statusText: pageEvidence.statusText,
          appShell: pageEvidence.appShell,
          alerts: pageEvidence.alerts,
          bodyText: appendTail(pageEvidence.bodyText ?? '', '', failureOutputMaxChars),
          import: pageEvidence.import,
          overview: pageEvidence.overview,
          detail: pageEvidence.detail,
      };
    } catch (captureError) {
      diagnostics.renderer = {
        captureError: captureError instanceof Error ? captureError.message : String(captureError),
      };
    }
  }
  if (session?.processSampler !== null && session?.processSampler !== undefined) {
    try {
      diagnostics.process = await session.processSampler.snapshot();
    } catch (captureError) {
      diagnostics.process = {
        captureError: captureError instanceof Error ? captureError.message : String(captureError),
      };
    }
  }
  return diagnostics;
}

function attachFailureDiagnostics(error, diagnostics) {
  const target = error instanceof Error ? error : new Error(String(error));
  target.perfDiagnostics = diagnostics;
  return target;
}

async function measureProcessPhase(session, task) {
  assert(session.processSampler !== null, 'process sampler 尚未安装');
  const mark = await session.processSampler.mark();
  const value = await task();
  return { value, process: await session.processSampler.summarySince(mark) };
}

async function measureIpc(page, kind, villageId, clanTag) {
  return evaluateWithTimeout(
    page,
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
      if (!result.ok) {
        throw new Error(
          `${requestKind} IPC 返回失败：${result.error.code} ${result.error.message}`,
        );
      }
      let rendered = null;
      if (requestKind === 'overview' || requestKind === 'detail') {
        const panel = globalThis.document.querySelector(
          requestKind === 'overview'
            ? 'section[aria-label="升级总览"]'
            : 'section[aria-label="村庄详情"]',
        );
        if (panel === null) {
          throw new Error(`${requestKind} renderer section 不存在`);
        }
        const state = panel.getAttribute('data-perf-state');
        const alertCount = panel.querySelectorAll('[role="alert"]').length;
        const retryCount = [...panel.querySelectorAll('button')].filter(
          (button) => button.textContent?.trim() === '重试',
        ).length;
        if (state !== 'ready' || alertCount > 0 || retryCount > 0) {
          throw new Error(
            `${requestKind} renderer 未成功消费 payload：state=${state ?? 'missing'}, alert=${alertCount}, retry=${retryCount}`,
          );
        }
        const expectedCount =
          requestKind === 'overview'
            ? [
                result.value.active,
                result.value.pending,
                result.value.state?.attentionRecords,
                result.value.state?.needsReimportRecords,
              ].reduce(
                (total, records) => total + (Array.isArray(records) ? records.length : 0),
                0,
              )
            : Array.isArray(result.value.flatRows)
              ? result.value.flatRows.length
              : 0;
        const actualCount =
          requestKind === 'overview'
            ? panel.querySelectorAll('.overview-list > li').length
            : panel.querySelectorAll('.detail-rows > *').length;
        if (actualCount !== expectedCount) {
          throw new Error(
            `${requestKind} renderer 数量不匹配：expected=${expectedCount}, actual=${actualCount}`,
          );
        }
        rendered = { state, expectedCount, actualCount, alertCount, retryCount };
      }
      const encoded = JSON.stringify(result);
      return {
        durationMs: performance.now() - started,
        payloadBytes: new TextEncoder().encode(encoded).byteLength,
        rendered,
        ok: true,
      };
    },
    { requestKind: kind, requestVillageId: villageId, requestClanTag: clanTag },
    bridgeCallTimeoutMs,
    `${kind} IPC`,
  );
}

async function resourceSummary(page, probe, mark) {
  assert(probe !== null, 'catalog request probe 尚未安装');
  const requests = probe.summary(mark);
  const images = await evaluateWithTimeout(
    page,
    () => {
      const catalogImages = [...globalThis.document.images].filter((image) =>
        image.currentSrc.startsWith('cochelper://catalog/'),
      );
      return {
        imageCount: catalogImages.length,
        loadedImageCount: catalogImages.filter((image) => image.naturalWidth > 0).length,
        failedImageCount: catalogImages.filter(
          (image) => image.complete && image.naturalWidth === 0,
        ).length,
      };
    },
    undefined,
    diagnosticsTimeoutMs,
    'catalog image summary',
  );
  if (requests.failedCount > 0 || images.failedImageCount > 0) {
    throw new Error(
      `catalog 资源失败：requestFailed=${requests.failedCount}, imageFailed=${images.failedImageCount}`,
    );
  }
  if (requests.completedCount + requests.failedCount !== requests.requestCount) {
    throw new Error(
      `catalog 请求未闭合：request=${requests.requestCount}, completed=${requests.completedCount}, failed=${requests.failedCount}`,
    );
  }
  return {
    ...requests,
    ...images,
    cacheObservation:
      requests.requestCount === 0 ? 'no-new-catalog-requests' : 'catalog-requests-observed',
  };
}

async function measureScroll(page, durationMs) {
  return evaluateWithTimeout(
    page,
    ({ duration }) =>
      new Promise((resolve) => {
        const target = globalThis.document.scrollingElement;
        const initialMax =
          target === null ? 0 : Math.max(0, target.scrollHeight - target.clientHeight);
        if (target === null || initialMax <= 0) {
          resolve({
            notApplicable: true,
            durationMs: 0,
            frameCount: 0,
            longFrameCount: 0,
            hitchCount: 0,
            frameMs: summarize([]),
          });
          return;
        }
        const frameDurations = [];
        const started = performance.now();
        let previous = started;
        let direction = 1;
        let moved = false;
        const step = (now) => {
          frameDurations.push(now - previous);
          previous = now;
          const max = Math.max(0, target.scrollHeight - target.clientHeight);
          if (max > 0) {
            const previousScrollTop = target.scrollTop;
            target.scrollTop += direction * Math.max(12, Math.round(target.clientHeight / 12));
            moved ||= target.scrollTop !== previousScrollTop;
            if (target.scrollTop >= max) direction = -1;
            if (target.scrollTop <= 0) direction = 1;
          }
          if (now - started >= duration) {
            target.scrollTop = 0;
            resolve({
              notApplicable: !moved,
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
    durationMs + scrollGraceTimeoutMs,
    'scroll rAF measurement',
  );
}

async function waitForOfficialList(page, ariaLabel, listSelector, minimumCount) {
  const section = page.locator(`section[aria-label="${ariaLabel}"]`);
  await section.waitFor({ state: 'visible' });
  const items = section.locator(`${listSelector} > li`);
  await items.nth(minimumCount - 1).waitFor({ state: 'visible', timeout: 30_000 });
  return { section, items };
}

async function waitForNoLoadMoreButton(section) {
  const button = section.getByRole('button', { name: '加载更多', exact: true });
  const deadline = Date.now() + 30_000;
  while ((await button.count()) > 0 && Date.now() < deadline) {
    await sleep(25);
  }
  assert.equal(await button.count(), 0, `${await section.getAttribute('aria-label')} 仍有加载更多按钮`);
}

async function exerciseOfficialPagination(page, context) {
  assert(context.apiServer !== null, 'official fixture API server 尚未安装');
  const startedAt = performance.now();
  const warCounts = [];
  for (const file of manifest.warLogPages) {
    warCounts.push((fixturePage(file).items ?? []).length);
  }
  const capitalCounts = [];
  for (const file of manifest.capitalRaidPages) {
    capitalCounts.push((fixturePage(file).items ?? []).length);
  }

  const war = await waitForOfficialList(
    page,
    '部落对战日志',
    'ul.official-war-log-list',
    warCounts[0],
  );
  const capital = await waitForOfficialList(
    page,
    '突袭周末',
    'ul.official-capital-raid-list',
    capitalCounts[0],
  );
  const requestStart = context.apiServer.requests.length;
  const warObservedCounts = [warCounts[0]];
  for (const expectedCount of [warCounts[0] + warCounts[1], warCounts[0] + warCounts[1] + warCounts[2]]) {
    const button = war.section.getByRole('button', { name: '加载更多', exact: true });
    await button.waitFor({ state: 'visible', timeout: 30_000 });
    await button.click();
    await war.items.nth(expectedCount - 1).waitFor({ state: 'visible', timeout: 30_000 });
    warObservedCounts.push(await war.items.count());
  }
  await waitForNoLoadMoreButton(war.section);

  const capitalObservedCounts = [capitalCounts[0]];
  for (const expectedCount of [
    capitalCounts[0] + capitalCounts[1],
    capitalCounts[0] + capitalCounts[1] + capitalCounts[2],
  ]) {
    const button = capital.section.getByRole('button', { name: '加载更多', exact: true });
    await button.waitFor({ state: 'visible', timeout: 30_000 });
    await button.click();
    await capital.items.nth(expectedCount - 1).waitFor({ state: 'visible', timeout: 30_000 });
    capitalObservedCounts.push(await capital.items.count());
  }
  await waitForNoLoadMoreButton(capital.section);

  const observedRequests = context.apiServer.requests.slice(requestStart);
  assert.deepEqual(
    observedRequests.filter((request) => request.endpoint === 'warLog').map((request) => request.file),
    manifest.warLogPages.slice(1),
    'WarLog loadMore 未按 after 游标加载第 2/3 页',
  );
  assert.deepEqual(
    observedRequests
      .filter((request) => request.endpoint === 'capitalRaid')
      .map((request) => request.file),
    manifest.capitalRaidPages.slice(1),
    'Capital Raid loadMore 未按 after 游标加载第 2/3 页',
  );
  return {
    durationMs: performance.now() - startedAt,
    warLog: { expectedCounts: warCounts, observedCounts: warObservedCounts },
    capitalRaid: { expectedCounts: capitalCounts, observedCounts: capitalObservedCounts },
    requests: observedRequests,
  };
}

async function measureViews(session, includeOfficial) {
  const page = pageOf(session);
  const probe = session.catalogProbe;
  assert(probe !== null, 'catalog request probe 尚未安装');
  const snapshot = await getSnapshot(page);
  assert(snapshot.selectedVillageId !== null, '性能场景需要 selectedVillageId');

  // probe 在 renderer ready 前已安装；当前 session 的全部 catalog 请求属于 cold 视图。
  const overviewColdMark = 0;
  const overviewCold = await measureProcessPhase(session, async () => {
    const navigationMs = await goToTab(page, '升级总览', '升级总览');
    await settleCatalogRequests(page, probe);
    return navigationMs;
  });
  const overviewColdResources = await resourceSummary(page, probe, overviewColdMark);
  const overviewIpc = await measureIpc(page, 'overview', snapshot.selectedVillageId, null);

  const detailColdMark = probe.mark();
  const detailCold = await measureProcessPhase(session, async () => {
    const navigationMs = await goToTab(page, '村庄详情', '村庄详情');
    await settleCatalogRequests(page, probe);
    return navigationMs;
  });
  const detailColdResources = await resourceSummary(page, probe, detailColdMark);
  const detailIpc = await measureIpc(page, 'detail', snapshot.selectedVillageId, null);
  const detailScroll = await measureProcessPhase(session, () => measureScroll(page, scrollMs));
  assert.equal(detailScroll.value.notApplicable, false, '村庄详情没有可滚动内容');

  for (let index = 0; index < warmupCount; index += 1) {
    await goToTab(page, '升级总览', '升级总览');
    await settleCatalogRequests(page, probe);
    await goToTab(page, '村庄详情', '村庄详情');
    await settleCatalogRequests(page, probe);
  }

  const overviewHotMark = probe.mark();
  const overviewHot = await measureProcessPhase(session, async () => {
    const navigationMs = await goToTab(page, '升级总览', '升级总览');
    await settleCatalogRequests(page, probe);
    return navigationMs;
  });
  const overviewHotResources = await resourceSummary(page, probe, overviewHotMark);

  const result = {
    navigationMs: {
      overviewCold: overviewCold.value,
      detailCold: detailCold.value,
      overviewHot: overviewHot.value,
    },
    process: {
      navigation: {
        overviewCold: overviewCold.process,
        detailCold: detailCold.process,
        overviewHot: overviewHot.process,
      },
      scroll: {
        detail: detailScroll.process,
      },
    },
    resources: {
      overviewCold: overviewColdResources,
      detailCold: detailColdResources,
      overviewHot: overviewHotResources,
    },
    ipc: { overview: overviewIpc, detail: detailIpc },
    scroll: { detail: detailScroll.value },
  };

  if (includeOfficial) {
    const clanTag = manifest.official.clanTag;
    const officialNavigation = await measureProcessPhase(session, async () => {
      await goToTab(page, '村庄详情', '村庄详情');
      await settleCatalogRequests(page, probe);
      return await exerciseOfficialPagination(page, session.context);
    });
    const warLog = await measureIpc(page, 'warLog', snapshot.selectedVillageId, clanTag);
    const capitalRaid = await measureIpc(page, 'capitalRaid', snapshot.selectedVillageId, clanTag);
    const officialScroll = await measureProcessPhase(session, () => measureScroll(page, scrollMs));
    assert.equal(officialScroll.value.notApplicable, false, '官方列表没有可滚动内容');
    result.ipc.warLog = warLog;
    result.ipc.capitalRaid = capitalRaid;
    result.pagination = officialNavigation.value;
    result.process.navigation.official = officialNavigation.process;
    result.scroll.official = officialScroll.value;
    result.process.scroll.official = officialScroll.process;
  }
  return result;
}

async function readRuntimeDiagnostics(page) {
  try {
    const result = await evaluateWithTimeout(
      page,
      () => globalThis.window.cocHelper.diagnosticsSnapshot({}),
      undefined,
      diagnosticsTimeoutMs,
      'diagnosticsSnapshot',
    );
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
  let runResult = null;
  let runError = null;
  let runDiagnostics = null;
  try {
    prepared.context.phase = 'measure:snapshot';
    const snapshot = await getSnapshot(page);
    prepared.context.phase = 'measure:views';
    const views = await measureViews(session, scenario === 'official-lists');
    const runtime = await readRuntimeDiagnostics(page);
    assert(session.processSampler !== null, 'process sampler 尚未安装');
    const finalProcess = await session.processSampler.snapshot();
    runResult = {
      scenario,
      repetition,
      startup: prepared.initialStartup,
      restartStartup: prepared.restartStartup,
      preparation: prepared.preparation,
      finalProcess,
      selectedVillageId: snapshot.selectedVillageId,
      phaseEvents: session.output.phaseEvents,
      views,
      runtime,
    };
  } catch (error) {
    runError = error;
    runDiagnostics = await captureFailureDiagnostics(prepared.context, session, error);
  }
  const cleanupErrors = [];
  const sessionCleanupError = await closeSession(session);
  if (sessionCleanupError !== null) cleanupErrors.push(sessionCleanupError);
  const serverCleanupError = await closeContextServer(prepared.context);
  if (serverCleanupError !== null) cleanupErrors.push(serverCleanupError);
  rmSync(prepared.context.tempRoot, { recursive: true, force: true });
  if (runError !== null && cleanupErrors.length > 0) {
    throw attachFailureDiagnostics(
      new AggregateError([runError, ...cleanupErrors], 'scenario execution and cleanup failed'),
      runDiagnostics,
    );
  }
  if (runError !== null) {
    throw attachFailureDiagnostics(runError, runDiagnostics);
  }
  if (cleanupErrors.length > 0) {
    throw attachFailureDiagnostics(
      new AggregateError(cleanupErrors, 'scenario cleanup failed'),
      runDiagnostics,
    );
  }
  return runResult;
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

function collectPreparationEntry(runs, kind, label) {
  const values = [];
  for (const run of runs) {
    if (run.preparation?.kind !== kind) {
      continue;
    }
    for (const entry of run.preparation.imports ?? []) {
      if (entry.label === label && typeof entry.durationMs === 'number') {
        values.push(entry.durationMs);
      }
    }
  }
  return summarizeNumbers(values);
}

function collectPreparationTotal(runs, kind) {
  const values = [];
  for (const run of runs) {
    if (run.preparation?.kind !== kind) {
      continue;
    }
    const total = (run.preparation.imports ?? []).reduce(
      (sum, entry) => sum + (typeof entry.durationMs === 'number' ? entry.durationMs : 0),
      0,
    );
    values.push(total);
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
          wallBeforeImportMs: collectPreparationEntry(selected, 'large-walls-import', 'before'),
          wallAfterImportMs: collectPreparationEntry(selected, 'large-walls-import', 'after'),
          historyImportTotalMs: collectPreparationTotal(selected, 'history-import'),
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
          officialScrollFrameP95: collectPath(selected, [
            'views',
            'scroll',
            'official',
            'frameMs',
            'p95',
          ]),
          officialScrollFrameMax: collectPath(selected, [
            'views',
            'scroll',
            'official',
            'frameMs',
            'max',
          ]),
          officialScrollLongFrames: collectPath(selected, [
            'views',
            'scroll',
            'official',
            'longFrameCount',
          ]),
          officialScrollHitches: collectPath(selected, [
            'views',
            'scroll',
            'official',
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
          peakRssBytes: collectProcessMetric(selected, 'rssBytes'),
          cpuPercent: collectProcessMetric(selected, 'cpuPercent'),
          peakFootprintBytes: collectProcessMetric(selected, 'rootFootprintBytes'),
          phaseDurations: Object.fromEntries(
            PERFORMANCE_TRACE_PHASES.map(({ key, scope, phase }) => [
              key,
              collectTracePhase(selected, scope, phase),
            ]),
          ),
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
    `- untracked source inputs: ${report.sourceProvenance.untrackedInputs.length}`,
    `- binary commit: ${report.binaryProvenance.commitSha}`,
    `- binary dirty at package time: ${report.binaryProvenance.dirty}`,
    `- platform: ${report.environment.platform}/${report.environment.arch}`,
    `- repetitions: ${report.options.repetitions}`,
    `- warmup: ${report.options.warmup}`,
    `- scrollMs: ${report.options.scrollMs}`,
    `- profile: ${report.options.profile}`,
    `- processSampleIntervalMs: ${report.sampling.processSampleIntervalMs}`,
    `- footprintSampleEvery: ${report.sampling.footprintSampleEvery}`,
    `- gate: ${report.gate.kind}${report.gate.acceptanceEligible ? '' : ' (diagnostic only)'}`,
    '',
    '> 本报告只记录 observed baseline；unknown 不等于 0，也不等于通过。all 场景是连续 workload 诊断，不是本 PR 的绿色验收门禁。',
    '',
    '| 场景 | 启动/CDP p50 | TTI p50 | Overview cold p50 | Detail cold p50 | Detail IPC p95 | 进程 CPU p95 | Workload 峰值 RSS | Workload 峰值 footprint |',
    '|---|---:|---:|---:|---:|---:|---:|---:|---:|',
  ];
  for (const scenario of SCENARIOS) {
    const summary = report.summary[scenario];
    lines.push(
      `| ${scenario} | ${formatNumber(summary.startupMs.p50)} ms | ${formatNumber(summary.ttiMs.p50)} ms | ${formatNumber(summary.overviewColdMs.p50)} ms | ${formatNumber(summary.detailColdMs.p50)} ms | ${formatNumber(summary.detailPayloadBytes.p95)} B | ${formatNumber(summary.cpuPercent.p95)}% | ${formatBytes(summary.peakRssBytes.max)} | ${formatBytes(summary.peakFootprintBytes.max)} |`,
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
  lines.push('', '## 首次/重启启动', '');
  lines.push(
    '| 场景 | 首次启动/CDP p50 | 首次 TTI p50 | 重启启动/CDP p50 | 重启 TTI p50 |',
    '|---|---:|---:|---:|---:|',
  );
  for (const scenario of SCENARIOS) {
    const summary = report.summary[scenario];
    lines.push(
      `| ${scenario} | ${formatNumber(summary.startupMs.p50)} ms | ${formatNumber(summary.ttiMs.p50)} ms | ${formatNumber(summary.restartStartupMs.p50)} ms | ${formatNumber(summary.restartTtiMs.p50)} ms |`,
    );
  }
  lines.push('', '## 导入 workload', '');
  lines.push(
    '| 场景 | 1005 Wall before p50 | 1005 Wall after p50 | History 24 总导入 p50 |',
    '|---|---:|---:|---:|',
  );
  for (const scenario of SCENARIOS) {
    const summary = report.summary[scenario];
    lines.push(
      `| ${scenario} | ${formatNumber(summary.wallBeforeImportMs.p50)} ms | ${formatNumber(summary.wallAfterImportMs.p50)} ms | ${formatNumber(summary.historyImportTotalMs.p50)} ms |`,
    );
  }
  lines.push('', '## Main 阶段时间', '');
  lines.push(
    '| 场景 | parse p50/p95 | canonicalization p50/p95 | reconciliation diff p50/p95 | history validate input p50/p95 | history validate wire p50/p95 | storage commit p50/p95 | storage write p50/p95 |',
    '|---|---:|---:|---:|---:|---:|---:|---:|',
  );
  for (const scenario of SCENARIOS) {
    const phases = report.summary[scenario].phaseDurations;
    const formatPhase = (key) =>
      `${formatNumber(phases[key].p50)}/${formatNumber(phases[key].p95)} ms`;
    lines.push(
      `| ${scenario} | ${formatPhase('importParse')} | ${formatPhase('historyCanonicalization')} | ${formatPhase('reconciliationDiff')} | ${formatPhase('historyValidateInput')} | ${formatPhase('historyValidateWire')} | ${formatPhase('storageCommit')} | ${formatPhase('storageWrite')} |`,
    );
  }
  lines.push('', '## Projection 阶段时间', '');
  lines.push(
    '| 场景 | catalog p50/p95 | detail rows p50/p95 | detail DTO p50/p95 |',
    '|---|---:|---:|---:|',
  );
  for (const scenario of SCENARIOS) {
    const phases = report.summary[scenario].phaseDurations;
    const formatPhase = (key) =>
      `${formatNumber(phases[key].p50)}/${formatNumber(phases[key].p95)} ms`;
    lines.push(
      `| ${scenario} | ${formatPhase('projectionCatalog')} | ${formatPhase('projectionDetailRows')} | ${formatPhase('projectionDetailDto')} |`,
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
    '| 场景 | Detail frame p95 | Detail max | Official frame p95 | Official max | >16.7ms 帧 | >50ms hitch |',
    '|---|---:|---:|---:|---:|---:|---:|',
  );
  for (const scenario of SCENARIOS) {
    const summary = report.summary[scenario];
    lines.push(
      `| ${scenario} | ${formatNumber(summary.detailScrollFrameP95.p50)} ms | ${formatNumber(summary.detailScrollFrameMax.p50)} ms | ${formatNumber(summary.officialScrollFrameP95.p50)} ms | ${formatNumber(summary.officialScrollFrameMax.p50)} ms | ${formatNumber(summary.detailScrollLongFrames.p50)} | ${formatNumber(summary.detailScrollHitches.p50)} |`,
    );
  }
  lines.push('', '## 采样边界', '');
  lines.push(
    '- 启动/CDP 是从 spawn 到 remote debugging endpoint 可用；TTI 是从 spawn 到 renderer app-shell `data-smoke=ready`。',
    '- RSS/CPU/footprint 在启动、导入、重启、导航和滚动阶段按 250ms 采样；footprint 当前仅统计主进程，平台不支持时为 unknown。',
    '- IPC payload 是 bridge 返回 Result 的 JSON UTF-8 字节数，不声称等于 Chromium 内部 structured-clone 字节数。',
    '- 图标冷/热请求来自 Playwright catalog protocol request 事件；hot=0 表示该视图未观察到新的 catalog 请求，不等于证明所有缓存层命中。',
    '- 滚动指标来自 renderer requestAnimationFrame 间隔；未把空 hitch 表解释为无卡顿。',
    '- 成功 run 不写入原始进程日志；失败 run 会额外写入 bounded stdout/stderr、snapshot、renderer、phase 和最后 process summary 诊断 artifact。',
  );
  if (report.failures.length > 0) {
    lines.push('', '## 失败诊断', '');
    for (const failure of report.failures) {
      lines.push(
        `- ${failure.scenario} repetition=${failure.repetition} phase=${failure.phase ?? 'unknown'}: ${failure.diagnosticsFile ?? 'no diagnostics artifact'}`,
      );
    }
  }
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
        const diagnostics = error?.perfDiagnostics ?? null;
        const diagnosticsFile =
          diagnostics === null
            ? null
            : path.join(outputDir, `failure-${scenario}-${String(repetition).padStart(2, '0')}.json`);
        if (diagnosticsFile !== null) {
          writeFileSync(diagnosticsFile, `${JSON.stringify(diagnostics, null, 2)}\n`);
        }
        const failure = {
          scenario,
          repetition,
          message: error instanceof Error ? error.message : String(error),
          phase: diagnostics?.phase ?? null,
          diagnosticsFile,
        };
        failures.push(failure);
        console.error(`[perf] 失败：${failure.message}`);
      }
    }
  }

  const report = {
    protocol: manifest.protocol,
    generatedAt: new Date().toISOString(),
    commitSha: sourceProvenance.commitSha,
    sourceProvenance,
    binary,
    binaryProvenance,
    environment: {
      platform: process.platform,
      arch: process.arch,
      node: process.version,
    },
    options: { scenario: scenarioArg, repetitions, warmup: warmupCount, scrollMs, profile },
    sampling: {
      processSampleIntervalMs,
      footprintSampleEvery,
    },
    gate: {
      kind: profile === 'baseline' ? FROZEN_RELEASE_BASELINE.profile : 'diagnostic',
      acceptanceEligible: profileContract.acceptanceEligible,
    },
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
    const cleanupError = await closeSession(session);
    if (cleanupError !== null) {
      console.error(`[perf] 最终 cleanup 失败：${cleanupError.message}`);
    }
  }
}
