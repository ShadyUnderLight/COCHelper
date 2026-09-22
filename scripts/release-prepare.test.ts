import { spawnSync } from 'node:child_process';

import { describe, expect, it } from 'vitest';

import { createNativeBuildEnvironment } from './release-prepare.mjs';

describe('release prepare native build environment', () => {
  it('只向 node-gyp 传递 allowlist 环境变量', () => {
    const environment = createNativeBuildEnvironment({
      PATH: '/usr/bin',
      HOME: '/tmp/coc-helper-home',
      TMPDIR: '/tmp',
      LANG: 'C.UTF-8',
      GITHUB_TOKEN: 'sentinel-github-token',
      TWITTER_AUTH_TOKEN: 'sentinel-cookie',
      NODE_OPTIONS: '--require=secret-loader',
      npm_config_userconfig: '/tmp/secret.npmrc',
    });

    expect(environment).toMatchObject({
      PATH: '/usr/bin',
      HOME: '/tmp/coc-helper-home',
      npm_config_loglevel: 'error',
    });
    expect(environment).not.toHaveProperty('GITHUB_TOKEN');
    expect(environment).not.toHaveProperty('TWITTER_AUTH_TOKEN');
    expect(environment).not.toHaveProperty('NODE_OPTIONS');
    expect(environment).not.toHaveProperty('npm_config_userconfig');

    const child = spawnSync(
      process.execPath,
      ['-e', "process.stdout.write(JSON.stringify(process.env))"],
      { env: environment, encoding: 'utf8' },
    );
    expect(child.status).toBe(0);
    expect(`${child.stdout}${child.stderr}`).not.toContain('sentinel');
  });
});
