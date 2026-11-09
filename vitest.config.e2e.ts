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
    // ADMIN_ORIGINS: un origen permitido para probar CORS del panel.
    env: { AUTH_REQUIRE_MFA: 'true', ADMIN_ORIGINS: 'http://localhost:5000' },
  },
});
