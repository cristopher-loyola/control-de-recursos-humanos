import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: { tsconfigPaths: true },
  test: {
    globals: true,
    root: './',
    include: ['**/*.e2e-spec.ts'],
    testTimeout: 30_000,
    fileParallelism: false,
    // Las pruebas validan el doble factor aunque el .env local lo apague.
    env: { AUTH_REQUIRE_MFA: 'true' },
  },
});
