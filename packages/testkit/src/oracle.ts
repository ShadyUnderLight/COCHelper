import { spawn } from 'node:child_process';
import { isAbsolute, resolve } from 'node:path';

import { isSha256Fingerprint, sha256Fingerprint, type Sha256Fingerprint } from '@coc-helper/wire';

export const SWIFT_ORACLE_PROTOCOL_VERSION = 1 as const;

export type SwiftOracleRequest = {
  readonly protocolVersion: typeof SWIFT_ORACLE_PROTOCOL_VERSION;
  readonly caseId: string;
  readonly operation: 'canonical-json';
  readonly source: string;
};

export type SwiftOracleSuccess = {
  readonly protocolVersion: typeof SWIFT_ORACLE_PROTOCOL_VERSION;
  readonly caseId: string;
  readonly ok: true;
  readonly inputFingerprint: Sha256Fingerprint;
  readonly outputFingerprint: Sha256Fingerprint;
  readonly value: { readonly canonicalHex: string };
};

export type SwiftOracleFailure = {
  readonly protocolVersion: typeof SWIFT_ORACLE_PROTOCOL_VERSION;
  readonly caseId: string;
  readonly ok: false;
  readonly inputFingerprint: Sha256Fingerprint;
  readonly outputFingerprint?: undefined;
  readonly error: { readonly kind: string; readonly code: string };
};

export type SwiftOracleResponse = SwiftOracleSuccess | SwiftOracleFailure;

export type OracleCommand = {
  readonly executable: string;
  readonly args: readonly string[];
  readonly cwd: string;
};

export type OracleProcessResult = {
  readonly exitCode: number | null;
  readonly stdout: string;
  readonly stderr: string;
};

export type OracleProcessExecutor = (
  command: OracleCommand,
  input: string,
  timeoutMs: number,
) => Promise<OracleProcessResult>;

export type SwiftOracleRunnerOptions = {
  readonly root?: string;
  readonly timeoutMs?: number;
  readonly execute?: OracleProcessExecutor;
};

export type SwiftOracleRunner = (request: SwiftOracleRequest) => Promise<SwiftOracleResponse>;

const MAX_PROCESS_OUTPUT_BYTES = 1_048_576;
const DEFAULT_TIMEOUT_MS = 30_000;

export function createSwiftOracleRunner(options: SwiftOracleRunnerOptions = {}): SwiftOracleRunner {
  const root = resolve(options.root ?? process.cwd());
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const command = resolveOracleCommand(root);
  const execute = options.execute ?? executeOracleCommand;

  return async (request) => {
    validateRequest(request);
    const result = await execute(command, `${JSON.stringify(request)}\n`, timeoutMs);
    if (result.exitCode !== 0) {
      throw new Error(`Swift oracle 退出码异常：${String(result.exitCode)}`);
    }

    const output = result.stdout.trim();
    if (output.length === 0 || output.includes('\n')) {
      throw new Error('Swift oracle 必须输出单个 JSON 响应。');
    }

    let decoded: unknown;
    try {
      decoded = JSON.parse(output) as unknown;
    } catch {
      throw new Error('Swift oracle 输出不是合法 JSON。');
    }
    const response = parseSwiftOracleResponse(decoded);
    if (response.caseId !== request.caseId) {
      throw new Error('Swift oracle caseId 与请求不一致。');
    }
    const expectedInputFingerprint = sha256Fingerprint(request.source);
    if (response.inputFingerprint !== expectedInputFingerprint) {
      throw new Error('Swift oracle inputFingerprint 与请求不一致。');
    }
    return response;
  };
}

export async function runSwiftOracle(
  request: SwiftOracleRequest,
  options: SwiftOracleRunnerOptions = {},
): Promise<SwiftOracleResponse> {
  return createSwiftOracleRunner(options)(request);
}

export function parseSwiftOracleResponse(value: unknown): SwiftOracleResponse {
  const object = asRecord(value, 'oracle response');
  if (object.protocolVersion !== SWIFT_ORACLE_PROTOCOL_VERSION) {
    throw new Error('Swift oracle protocolVersion 不受支持。');
  }
  const caseId = requireNonEmptyString(object.caseId, 'oracle response.caseId');
  const inputFingerprint = requireFingerprint(
    object.inputFingerprint,
    'oracle response.inputFingerprint',
  );

  if (object.ok === true) {
    const outputFingerprint = requireFingerprint(
      object.outputFingerprint,
      'oracle response.outputFingerprint',
    );
    const valueObject = asRecord(object.value, 'oracle response.value');
    const canonicalHex = requireNonEmptyString(
      valueObject.canonicalHex,
      'oracle response.value.canonicalHex',
    );
    if (!/^[0-9a-f]+$/.test(canonicalHex) || canonicalHex.length % 2 !== 0) {
      throw new Error('oracle response.value.canonicalHex 格式无效。');
    }
    return {
      protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
      caseId,
      ok: true,
      inputFingerprint,
      outputFingerprint,
      value: { canonicalHex },
    };
  }

  if (object.ok === false) {
    const error = asRecord(object.error, 'oracle response.error');
    return {
      protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
      caseId,
      ok: false,
      inputFingerprint,
      error: {
        kind: requireNonEmptyString(error.kind, 'oracle response.error.kind'),
        code: requireNonEmptyString(error.code, 'oracle response.error.code'),
      },
    };
  }

  throw new Error('Swift oracle response.ok 必须是 boolean。');
}

function resolveOracleCommand(root: string): OracleCommand {
  const configured = process.env.COCHELPER_SWIFT_ORACLE;
  if (configured !== undefined && configured.length > 0) {
    return {
      executable: isAbsolute(configured) ? configured : resolve(root, configured),
      args: [],
      cwd: root,
    };
  }
  return {
    executable: 'swift',
    args: ['run', '--package-path', root, '--configuration', 'debug', 'golden-oracle'],
    cwd: root,
  };
}

function validateRequest(request: SwiftOracleRequest): void {
  if (
    request.protocolVersion !== SWIFT_ORACLE_PROTOCOL_VERSION ||
    request.operation !== 'canonical-json' ||
    request.caseId.length === 0 ||
    request.caseId.length > 200
  ) {
    throw new Error('Swift oracle request 不符合 protocol v1。');
  }
}

function executeOracleCommand(
  command: OracleCommand,
  input: string,
  timeoutMs: number,
): Promise<OracleProcessResult> {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command.executable, [...command.args], {
      cwd: command.cwd,
      env: oracleEnvironment(),
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let settled = false;
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGKILL');
    }, timeoutMs);

    const fail = (error: Error): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      child.kill('SIGKILL');
      reject(error);
    };

    child.stdout.on('data', (chunk: Buffer) => {
      stdout += chunk.toString('utf8');
      if (Buffer.byteLength(stdout, 'utf8') > MAX_PROCESS_OUTPUT_BYTES) {
        fail(new Error('Swift oracle stdout 超过大小限制。'));
      }
    });
    child.stderr.on('data', (chunk: Buffer) => {
      stderr += chunk.toString('utf8');
      if (Buffer.byteLength(stderr, 'utf8') > MAX_PROCESS_OUTPUT_BYTES) {
        fail(new Error('Swift oracle stderr 超过大小限制。'));
      }
    });
    child.once('error', () => {
      fail(new Error('Swift oracle 进程无法启动。'));
    });
    child.once('close', (exitCode) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      if (timedOut) {
        reject(new Error('Swift oracle 执行超时。'));
        return;
      }
      resolveResult({ exitCode, stdout, stderr });
    });
    child.stdin.end(input);
  });
}

function oracleEnvironment(): NodeJS.ProcessEnv {
  const environment = { ...process.env };
  // Oracle 只处理 tracked fixtures；不要把可选 API token 传入子进程。
  delete environment.COC_TOKEN;
  return environment;
}

function asRecord(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error(`${label} 必须是对象。`);
  }
  return value as Record<string, unknown>;
}

function requireNonEmptyString(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`${label} 必须是非空字符串。`);
  }
  return value;
}

function requireFingerprint(value: unknown, label: string): Sha256Fingerprint {
  if (typeof value !== 'string' || !isSha256Fingerprint(value)) {
    throw new Error(`${label} 不是合法 SHA-256 fingerprint。`);
  }
  return value;
}
