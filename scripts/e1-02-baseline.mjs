#!/usr/bin/env node
/**
 * E1-02 干净基线回读：分别记录 pass / fail / not_run。
 * 未执行的 suite 绝不能记为 pass。
 * E1_02_BASELINE_SUITES 显式提供时 fail-closed：未知名 / 空选择一律非 0 退出。
 */
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { BASELINE_SUITE_IDS, resolveBaselineSuiteSelection } from './e1-02-baseline-selection.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const suites = [
  { id: 'unit', command: 'pnpm', args: ['test'] },
  { id: 'parity', command: 'pnpm', args: ['test:parity'] },
  { id: 'fault-replay', command: 'pnpm', args: ['test:fault-replay'] },
  { id: 'oracle-isolation', command: 'pnpm', args: ['check:oracle-isolation'] },
];

if (suites.map((suite) => suite.id).join(',') !== BASELINE_SUITE_IDS.join(',')) {
  throw new Error('baseline suite 定义与 e1-02-baseline-selection.mjs 不一致');
}

let selectedIds;
try {
  selectedIds = resolveBaselineSuiteSelection(process.env.E1_02_BASELINE_SUITES);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}

const selected = new Set(selectedIds);

/** @type {{ id: string, status: 'pass' | 'fail' | 'not_run', exitCode: number | null, detail: string }[]} */
const results = [];

for (const suite of suites) {
  if (!selected.has(suite.id)) {
    results.push({
      id: suite.id,
      status: 'not_run',
      exitCode: null,
      detail: '未选入本次回读',
    });
    continue;
  }
  const ran = spawnSync(suite.command, suite.args, {
    cwd: root,
    encoding: 'utf8',
    env: process.env,
    stdio: 'inherit',
  });
  if (ran.error) {
    results.push({
      id: suite.id,
      status: 'fail',
      exitCode: null,
      detail: ran.error.message,
    });
    continue;
  }
  const exitCode = ran.status ?? 1;
  results.push({
    id: suite.id,
    status: exitCode === 0 ? 'pass' : 'fail',
    exitCode,
    detail: exitCode === 0 ? 'ok' : `exit ${exitCode}`,
  });
}

const report = {
  generatedAt: new Date().toISOString(),
  rule: 'not_run 不得记为 pass；未知 suite / 空选择 fail-closed',
  results,
};

const outPath = path.join(root, 'docs/electron/e1-02-baseline-latest.json');
writeFileSync(outPath, `${JSON.stringify(report, null, 2)}\n`);

console.log('\nE1-02 baseline:');
for (const item of results) {
  console.log(`- ${item.id}: ${item.status}${item.exitCode === null ? '' : ` (${item.exitCode})`}`);
}

const failed = results.some((item) => item.status === 'fail');
const executed = results.filter((item) => item.status !== 'not_run');
if (executed.length === 0) {
  console.error('E1-02 baseline 未执行任何 suite（不得记为通过）');
  process.exit(1);
}
process.exit(failed ? 1 : 0);
