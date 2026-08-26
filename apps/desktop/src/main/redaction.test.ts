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
      Authorization: authorizationMessage('Basic', credential),
      headers: {
        Cookie: `session=${credential}`,
        'Set-Cookie': `session=${credential}; HttpOnly`,
      },
    });
    const result = redactDiagnosticText(
      `${jsonMessage}\nCookie: session=${credential}\nSet-Cookie: session=${credential}`,
    );

    expect(result).not.toContain(credential);
    expect(result).toContain('[REDACTED]');
  });

  it('清洗 JSON 嵌套字段和转义 URL', () => {
    const result = redactDiagnosticText(
      '{"details":{"message":"https:\\/\\/example.test\\/private?token=opaque"}}',
    );

    expect(result).not.toContain('example.test');
    expect(result).not.toContain('opaque');
    expect(result).toContain('[REDACTED_URL]');
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
