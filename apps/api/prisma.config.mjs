import { fileURLToPath } from 'node:url';
import { config } from 'dotenv';
import { defineConfig, env } from 'prisma/config';

config({
  path: fileURLToPath(new URL('../../.env', import.meta.url)),
  quiet: true,
});

export default defineConfig({
  schema: 'prisma/schema.prisma',
  migrations: {
    path: 'prisma/migrations',
  },
  // Las migraciones usan el dueño de las tablas; la API usa DATABASE_URL, sujeta a RLS.
  datasource: {
    url: env('DATABASE_OWNER_URL'),
  },
});
