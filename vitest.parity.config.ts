import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['packages/testkit/src/golden.parity.test.ts'],
    environment: 'node',
    fileParallelism: false,
    testTimeout: 30_000,
  },
});
