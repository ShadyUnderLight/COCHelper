import { describe, expect, it } from 'vitest';

import { redactDiagnosticText } from './redaction';

describe('redactDiagnosticText', () => {
  it('移除 URL、Bearer/token 内容和控制字符', () => {
    const bearerMessage = authorizationMessage('Bearer', 'super-secret');
    const result = redactDiagnosticText(
      `https://api.example.test/v1?token=secret\n${bearerMessage}\n下一行`,
    );

    expect(result).not.toContain('super-secret');
    expect(result).not.toContain('https://api.example.test');
    expect(result).not.toContain('token=secret');
    expect(result).not.toContain('\n');
    expect(result).toContain('[REDACTED]');
    expect(result).toContain('[REDACTED_URL]');
  });

  it('无论 Authorization scheme 是什么都移除整个 header value', () => {
    for (const scheme of ['Basic', 'Token', 'Digest']) {
      expect(redactDiagnosticText(authorizationMessage(scheme, 'opaque-credential'))).toBe(
        'Authorization: [REDACTED]',
      );
    }
  });

  it('移除 JSON 和普通文本中的 Authorization、Cookie、Set-Cookie', () => {
    const credential = 'opaque-credential';
    const jsonMessage = JSON.stringify({
      headers: [
        { name: 'Authorization', value: authorizationMessage('Basic', credential) },
        { name: 'Cookie', value: `session=${credential}` },
        { name: 'Set-Cookie', value: `session=${credential}; HttpOnly` },
      ],
    });
    const result = [
      redactDiagnosticText(jsonMessage),
      redactDiagnosticText(`Cookie: session=${credential}`),
      redactDiagnosticText(`Set-Cookie: session=${credential}`),
    ].join('\n');

    expect(result).not.toContain(credential);
    expect(result).toContain('[REDACTED]');
  });

  it('清洗 JSON 嵌套字段和转义 URL', () => {
    const result = redactDiagnosticText(
      [
        '{"details":{"message":"https:\\/\\/example.test\\/private?token=opaque"}}',
        'ftp://user:secret@example.test/private',
        'file:///Users/private/secret.txt',
        'data:text/plain,private-secret',
      ].join('\n'),
    );

    expect(result).not.toContain('example.test');
    expect(result).not.toContain('user:secret');
    expect(result).not.toContain('private-secret');
    expect(result).toContain('[REDACTED_URL]');
  });

  it('先规范化控制字符再清洗多行 header', () => {
    const result = redactDiagnosticText(
      ['Authorization', ': ', 'Basic', '\n', 'multiline-secret'].join(''),
    );

    expect(result).toBe('Authorization: [REDACTED]');
    expect(result).not.toContain('multiline-secret');
  });

  it('截断过长诊断文本', () => {
    const result = redactDiagnosticText('x'.repeat(300));
    expect(result).toHaveLength(200);
    expect(result.endsWith('…')).toBe(true);
  });
});

function authorizationMessage(scheme: string, credential: string): string {
  return ['Authorization', ': ', scheme, ' ', credential].join('');
}
