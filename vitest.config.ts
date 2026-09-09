import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: [
      'apps/**/*.test.ts',
      'apps/**/*.test.tsx',
      'packages/**/*.test.ts',
      'scripts/**/*.test.ts',
    ],
    exclude: ['**/*.parity.test.ts'],
    environment: 'node',
  },
});
