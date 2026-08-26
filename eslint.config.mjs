import eslint from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  {
    ignores: [
      '**/node_modules/**',
      '**/.webpack/**',
      '**/out/**',
      'Sources/**',
      'Tests/**',
      'Tools/**',
      'docs/**',
      'Resources/**',
    ],
  },
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  {
    rules: {
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
    },
  },
  {
    files: ['scripts/**/*.mjs', 'eslint.config.mjs'],
    languageOptions: {
      globals: globals.node,
    },
  },
  {
    files: ['apps/desktop/webpack.plugins.ts'],
    rules: {
      '@typescript-eslint/no-require-imports': 'off',
    },
  },
  {
    files: ['apps/desktop/src/main/**/*.ts', 'apps/desktop/src/preload/**/*.ts'],
    rules: {
      'no-restricted-imports': [
        'error',
        {
          paths: [{ name: '@coc-helper/testkit', message: 'testkit 不得进入 Electron runtime。' }],
        },
      ],
    },
  },
  {
    files: ['apps/desktop/src/renderer/**/*.ts'],
    rules: {
      'no-restricted-imports': [
        'error',
        {
          paths: [
            { name: 'electron', message: 'renderer 不得 import electron。' },
            { name: 'fs', message: 'renderer 不得使用 Node fs。' },
            { name: 'path', message: 'renderer 不得使用 Node path。' },
            { name: 'child_process', message: 'renderer 不得使用 child_process。' },
            { name: '@coc-helper/testkit', message: 'testkit 不得进入 Electron runtime。' },
          ],
          patterns: [{ group: ['node:*'], message: 'renderer 不得使用 Node 内置模块。' }],
        },
      ],
    },
  },
);
