#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

import { chromium } from 'playwright-core';

import { resolvePackagedBinary } from './electron-package.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixtureRoot = path.join(root, 'e2e/fixtures');
const artifactRoot = path.join(root, 'e2e-artifacts');
const runId = `${new Date().toISOString().replaceAll(':', '-')}-${process.pid}`;
const scenarioName = 'import-and-restart';
const rendererReadyTimeoutMs = 45_000;
const importedVillageTimeoutMs = 30_000;
const manifest = JSON.parse(
  readFileSync(path.join(fixtureRoot, 'manifest.json'), 'utf8'),
);
const scenario = manifest.scenarios?.[scenarioName];
if (scenario === undefined) {
  throw new Error(`fixture manifest 缺少场景：${scenarioName}`);
}

const accountText = readFileSync(path.join(fixtureRoot, scenario.account), 'utf8');
const binary = resolvePackagedBinary(root);
const tempRoot = mkdtempSync(path.join(os.tmpdir(), 'coc-helper-packaged-e2e-'));
const homeDirectory = path.join(tempRoot, 'home');
const electronDataRoot = path.join(tempRoot, 'electron-data');
const electronUserDataDirectory = path.join(tempRoot, 'electron-user-data');
mkdirSync(homeDirectory, { recursive: true });
mkdirSync(electronDataRoot, { recursive: true });
mkdirSync(electronUserDataDirectory, { recursive: true });

const environment = {
  ...process.env,
  COCHELPER_E2E_DATA_ROOT: electronDataRoot,
  ELECTRON_ENABLE_LOGGING: '1',
  ...(process.platform !== 'darwin'
    ? {
        HOME: homeDirectory,
        XDG_CONFIG_HOME: path.join(homeDirectory, 'config'),
      }
    : {}),
  ...(process.platform === 'win32'
    ? { APPDATA: path.join(homeDirectory, 'AppData', 'Roaming') }
    : {}),
};

const sessions = [];
let currentSession = null;
let phase = 'launch';
let importStep = null;

function getCommitSha() {
  try {
    return execFileSync('git', ['rev-parse', 'HEAD'], {
      cwd: root,
      encoding: 'utf8',
    }).trim();
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
  const deadline = Date.now() + 20_000;
  let lastError = null;
  while (Date.now() < deadline) {
    if (child.exitCode !== null || child.signalCode !== null) {
      throw new Error(
        `packaged app 在 CDP 可用前退出，exit code=${child.exitCode} signal=${child.signalCode}`,
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

async function waitForReady(browser, session) {
  const context = browser.contexts()[0];
  assert(context !== undefined, 'CDP 未提供 browser context');
  const deadline = Date.now() + rendererReadyTimeoutMs;
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

  session.page = page;
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
      return page;
    }
    if (state?.smoke === 'fatal' || state?.status.includes('宿主健康检查失败')) {
      const body = await withTimeout(page.locator('body').innerText(), 1_000, '');
      throw new Error(`Renderer 未就绪：${body || state.status || state.smoke}`);
    }
    await sleep(100);
  }
  const body = await withTimeout(page.locator('body').innerText(), 1_000, '');
  throw new Error(`等待 packaged app renderer ready 超时${body === '' ? '' : `：${body}`}`);
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

async function launchApp() {
  const port = await findFreePort();
  const args = [
    `--user-data-dir=${electronUserDataDirectory}`,
    `--remote-debugging-address=127.0.0.1`,
    `--remote-debugging-port=${port}`,
    ...(process.platform === 'linux' ? ['--no-sandbox'] : []),
  ];
  const child = spawn(binary, args, {
    cwd: root,
    env: {
      ...environment,
      ...(process.platform === 'linux' ? { ELECTRON_DISABLE_SANDBOX: '1' } : {}),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const output = collectOutput(child);
  const session = { child, output, browser: null, page: null, port };
  sessions.push(session);
  currentSession = session;

  const endpoint = await waitForDevTools(child, port);
  session.browser = await withTimeout(chromium.connectOverCDP(endpoint), 20_000, null);
  if (session.browser === null) {
    throw new Error('连接 packaged app CDP 超时');
  }
  session.page = await waitForReady(session.browser, session);
  session.page.setDefaultTimeout(10_000);
  return session;
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
  if (session.browser !== null) {
    await withTimeout(session.browser.close().catch(() => {}), 5_000, undefined);
    session.browser = null;
  }
  if (session.child.exitCode === null && session.child.signalCode === null) {
    session.child.kill('SIGTERM');
    await waitForExit(session.child, 10_000);
  }
  if (session.child.exitCode === null && session.child.signalCode === null) {
    session.child.kill('SIGKILL');
    const forceExited = await waitForExit(session.child, 5_000);
    if (!forceExited && session.child.exitCode === null && session.child.signalCode === null) {
      console.error('packaged app 进程未能在 SIGKILL 后退出');
    }
  }
  if (currentSession === session) {
    currentSession = null;
  }
}

async function waitForText(page, selector, expected, timeout = 10_000) {
  await page.waitForFunction(
    ({ selector: query, expected: text }) =>
      globalThis.document.querySelector(query)?.textContent?.includes(text) === true,
    { selector, expected },
    { timeout },
  );
}

async function importFixture(page) {
  phase = 'import';
  importStep = 'fill-account';
  await page.locator('#account-json').fill(accountText);
  importStep = 'click-parse-preview';
  await page.getByRole('button', { name: '解析预览' }).click();
  const preview = page.getByRole('region', { name: '导入预览' });
  importStep = 'wait-for-preview';
  await preview.waitFor({ state: 'visible' });
  importStep = 'read-preview';
  const previewText = await preview.innerText();
  assert.match(previewText, /将更新村庄「[^」]+」/);
  assert.match(previewText, new RegExp(scenario.expectedTag.replace('#', '\\#')));

  importStep = 'confirm-import';
  await preview.getByRole('button', { name: '确认导入' }).click();
  importStep = 'wait-for-imported-village';
  await waitForText(
    page,
    '[aria-label="村庄列表"]',
    scenario.expectedTag,
    importedVillageTimeoutMs,
  );
  importStep = null;
}

async function assertPersistedFixture(page) {
  phase = 'assert-persistence';
  await waitForText(
    page,
    '[aria-label="村庄列表"]',
    scenario.expectedTag,
    importedVillageTimeoutMs,
  );
  const sidebarText = await page.getByRole('complementary', { name: '村庄列表' }).innerText();
  assert.match(sidebarText, new RegExp(scenario.expectedVillageName));
  assert.match(sidebarText, new RegExp(scenario.expectedTag.replace('#', '\\#')));
}

function classifyFailure(currentPhase) {
  switch (currentPhase) {
    case 'launch':
      return 'launcher';
    case 'import':
      return 'renderer-flow';
    case 'restart':
      return 'lifecycle';
    case 'assert-persistence':
      return 'persistence';
    default:
      return 'harness';
  }
}

async function captureFailure(error) {
  const directory = path.join(artifactRoot, runId);
  mkdirSync(directory, { recursive: true });
  const page = currentSession?.page;
  if (page !== null && page !== undefined && !page.isClosed()) {
    await withTimeout(
      page.screenshot({ path: path.join(directory, 'renderer.png'), fullPage: true }).catch(() => {}),
      5_000,
      undefined,
    );
    await withTimeout(
      page
        .content()
        .then((html) => writeFileSync(path.join(directory, 'renderer.html'), html))
        .catch(() => {}),
      5_000,
      undefined,
    );
    const diagnostics = await withTimeout(
      page
        .evaluate(async () => {
          const result = await globalThis.window.cocHelper.diagnosticsSnapshot({});
          return result;
        })
        .catch(() => null),
      5_000,
      null,
    );
    const failureState = await withTimeout(
      page
        .evaluate((currentImportStep) => {
          const summarize = (element) => {
            if (element === null) return null;
            const rect = element.getBoundingClientRect();
            const style = globalThis.getComputedStyle(element);
            return {
              visible:
                rect.width > 0 &&
                rect.height > 0 &&
                style.display !== 'none' &&
                style.visibility !== 'hidden',
              text: element.innerText?.trim().slice(0, 1200) ?? '',
              bounds: {
                x: Math.round(rect.x),
                y: Math.round(rect.y),
                width: Math.round(rect.width),
                height: Math.round(rect.height),
              },
            };
          };
          const parseButton =
            [...globalThis.document.querySelectorAll('button')].find(
              (button) => button.textContent?.trim() === '解析预览',
            ) ?? null;
          const buttonRect = parseButton?.getBoundingClientRect();
          const hitTarget =
            buttonRect === undefined
              ? null
              : globalThis.document.elementFromPoint(
                  buttonRect.x + buttonRect.width / 2,
                  buttonRect.y + buttonRect.height / 2,
                );
          const buttonStyle =
            parseButton === null ? null : globalThis.getComputedStyle(parseButton);
          const activeElement = globalThis.document.activeElement;
          return {
            importStep: currentImportStep,
            parseButton:
              parseButton === null
                ? null
                : {
                    ...summarize(parseButton),
                    disabled: parseButton.disabled,
                    ariaDisabled: parseButton.getAttribute('aria-disabled'),
                    pointerEvents: buttonStyle?.pointerEvents ?? null,
                    opacity: buttonStyle?.opacity ?? null,
                    transitionDuration: buttonStyle?.transitionDuration ?? null,
                    animations: parseButton.getAnimations().length,
                    centerHitTarget:
                      hitTarget === null
                        ? null
                        : {
                            tagName: hitTarget.tagName,
                            text: hitTarget.textContent?.trim().slice(0, 160) ?? '',
                          },
                  },
            preview: summarize(globalThis.document.querySelector('[aria-label="导入预览"]')),
            villageList: summarize(globalThis.document.querySelector('[aria-label="村庄列表"]')),
            importPanel: summarize(globalThis.document.querySelector('[aria-label="账号导入"]')),
            alerts: [...globalThis.document.querySelectorAll('[role="alert"]')]
              .slice(0, 8)
              .map((alert) => alert.innerText?.trim().slice(0, 512) ?? ''),
            activeElement:
              activeElement === null
                ? null
                : {
                    tagName: activeElement.tagName,
                    ariaLabel: activeElement.getAttribute('aria-label'),
                    name: activeElement.getAttribute('name'),
                  },
          };
        }, importStep)
        .catch(() => null),
      5_000,
      null,
    );
    if (diagnostics === null) {
      writeFileSync(path.join(directory, 'diagnostics-error.txt'), '诊断采集超时或失败。\n');
    } else {
      writeFileSync(
        path.join(directory, 'diagnostics.json'),
        `${JSON.stringify(diagnostics, null, 2)}\n`,
      );
    }
    if (failureState === null) {
      writeFileSync(path.join(directory, 'failure-state-error.txt'), '界面状态采集超时或失败。\n');
    } else {
      const serializedFailureState = JSON.stringify(failureState, null, 2);
      writeFileSync(path.join(directory, 'failure-state.json'), `${serializedFailureState}\n`);
      console.error(`failure UI state: ${JSON.stringify(failureState)}`);
    }
  }

  writeFileSync(
    path.join(directory, 'environment.json'),
    `${JSON.stringify(
      {
        commitSha: getCommitSha(),
        platform: process.platform,
        arch: process.arch,
        node: process.version,
        scenario: scenarioName,
        phase,
        importStep,
        failureClass: classifyFailure(phase),
        error: error instanceof Error ? error.message : String(error),
      },
      null,
      2,
    )}\n`,
  );
  writeFileSync(
    path.join(directory, 'fixture-manifest.json'),
    `${JSON.stringify({ schemaVersion: manifest.schemaVersion, scenarioName, scenario }, null, 2)}\n`,
  );
  for (const [index, session] of sessions.entries()) {
    writeFileSync(
      path.join(directory, `process-${index + 1}.stdout.log`),
      session.output.stdout,
    );
    writeFileSync(
      path.join(directory, `process-${index + 1}.stderr.log`),
      session.output.stderr,
    );
  }
  cpSync(tempRoot, path.join(directory, 'isolated-home'), { recursive: true });
  return directory;
}

async function main() {
  phase = 'launch';
  currentSession = await launchApp();
  await importFixture(currentSession.page);

  phase = 'restart';
  await closeSession(currentSession);
  currentSession = await launchApp();
  await assertPersistedFixture(currentSession.page);

  console.log(`packaged E2E passed: ${scenarioName}`);
}

let failureDirectory = null;
try {
  await main();
} catch (error) {
  failureDirectory = await captureFailure(error);
  console.error(
    `packaged E2E 失败 [${classifyFailure(phase)}/${phase}]：${
      error instanceof Error ? error.message : String(error)
    }`,
  );
  console.error(`failure artifacts: ${failureDirectory}`);
  process.exitCode = 1;
} finally {
  for (const session of [...sessions].reverse()) {
    await closeSession(session);
  }
  rmSync(tempRoot, { recursive: true, force: true });
}
