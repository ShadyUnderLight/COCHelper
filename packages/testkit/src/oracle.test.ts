import { describe, expect, it } from 'vitest';

import {
  createSwiftOracleRunner,
  parseSwiftOracleResponse,
  SWIFT_ORACLE_PROTOCOL_VERSION,
  type SwiftOracleRequest,
} from './oracle';

function request(source: string): SwiftOracleRequest {
  return {
    protocolVersion: SWIFT_ORACLE_PROTOCOL_VERSION,
    caseId: 'test/case',
    operation: 'canonical-json',
    source,
  };
}

describe('Swift oracle runner', () => {
  it('通过注入的 executor 校验请求、响应和 caseId 关联', async () => {
    const source = '{"n":1}';
    const runner = createSwiftOracleRunner({
      root: '/repo',
      command: {
        executable: 'swift',
        args: ['run', '--package-path', '/repo', '--configuration', 'debug', 'golden-oracle'],
        cwd: '/repo',
      },
      execute: async (command, input, timeoutMs) => {
        expect(command.executable).toBe('swift');
        expect(command.args).toEqual([
          'run',
          '--package-path',
          '/repo',
          '--configuration',
          'debug',
          'golden-oracle',
        ]);
        expect(timeoutMs).toBe(30_000);
        expect(JSON.parse(input).source).toBe(source);
        return {
          exitCode: 0,
          stdout: JSON.stringify({
            protocolVersion: 2,
            caseId: 'test/case',
            ok: true,
            value: { canonicalHex: '31' },
          }),
          stderr: '',
        };
      },
    });

    await expect(runner(request(source))).resolves.toMatchObject({
      ok: true,
      caseId: 'test/case',
      value: { canonicalHex: '31' },
    });
  });

  it('保留稳定的 rejected 结果，不要求传播 Foundation 错误文本', () => {
    expect(
      parseSwiftOracleResponse({
        protocolVersion: 2,
        caseId: 'test/reject',
        ok: false,
        error: { kind: 'rejected', code: 'invalidJson' },
      }),
    ).toMatchObject({
      ok: false,
      error: { kind: 'rejected', code: 'invalidJson' },
    });
  });

  it('拒绝旧 protocolVersion 1 响应，不加 fallback', () => {
    expect(() =>
      parseSwiftOracleResponse({
        protocolVersion: 1,
        caseId: 'test/case',
        ok: true,
        value: { canonicalHex: '31' },
      }),
    ).toThrow('不受支持');
  });

  it('拒绝非零退出码', async () => {
    const runner = createSwiftOracleRunner({
      root: '/repo',
      execute: async () => ({ exitCode: 2, stdout: '', stderr: 'hidden detail' }),
    });
    await expect(runner(request('{'))).rejects.toThrow('退出码异常');
  });

  it('子进程提前退出且输入很大时返回受控失败', async () => {
    const runner = createSwiftOracleRunner({
      command: {
        executable: process.execPath,
        args: ['-e', 'process.stdin.destroy(); process.exit(0)'],
        cwd: process.cwd(),
      },
    });
    await expect(runner(request('x'.repeat(8 * 1024 * 1024)))).rejects.toThrow();
  });
});
