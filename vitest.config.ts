import { defineConfig } from 'vitest/config';

const ignore = ['**/node_modules/**', '**/.webpack/**', '**/out/**'];

export default defineConfig({
  test: {
    environment: 'node',
    projects: [
      {
        test: {
          name: 'unit',
          environment: 'node',
          include: ['apps/**/*.test.ts', 'packages/**/*.test.ts', 'scripts/**/*.test.ts'],
          exclude: [...ignore, '**/*.parity.test.ts', '**/*.replay.test.ts'],
        },
      },
      {
        test: {
          name: 'parity',
          environment: 'node',
          include: ['packages/**/*.parity.test.ts'],
          exclude: ignore,
        },
      },
      {
        test: {
          name: 'replay',
          environment: 'node',
          include: ['packages/**/*.replay.test.ts'],
          exclude: ignore,
        },
      },
    ],
  },
});
