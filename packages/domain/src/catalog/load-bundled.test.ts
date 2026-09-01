import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { describe, expect, it } from 'vitest';

import { createGeneratedFileIntegrityProbe } from './load-bundled';

describe('createGeneratedFileIntegrityProbe root containment', () => {
  it('拒绝 ../ 与绝对路径', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-catalog-probe-'));
    const probe = createGeneratedFileIntegrityProbe(root);
    expect(probe.fileExists('../outside.png')).toBe(false);
    expect(probe.fileExists('../../etc/passwd')).toBe(false);
    expect(probe.fileExists('/etc/passwd')).toBe(false);
    expect(probe.fileExists('icons\\ui\\x.png')).toBe(false);
  });

  it('允许 root 内合法相对路径', () => {
    const root = mkdtempSync(join(tmpdir(), 'coc-catalog-probe-'));
    mkdirSync(join(root, 'icons/ui'), { recursive: true });
    writeFileSync(join(root, 'icons/ui/x.png'), 'png');

    const probe = createGeneratedFileIntegrityProbe(root);
    expect(probe.fileExists('icons/ui/x.png')).toBe(true);
    expect(probe.fileSize('icons/ui/x.png')).toBe(3);
  });
});
