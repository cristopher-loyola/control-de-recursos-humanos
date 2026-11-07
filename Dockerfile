# API para el servidor de la oficina. Desde la raíz del repositorio:
#   docker compose --profile servidor up -d --build
FROM node:24.22.2-bookworm-slim

ENV PNPM_HOME=/pnpm PATH=/pnpm:$PATH CI=true
RUN corepack enable

WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
# Incluye prisma CLI: el contenedor aplica las migraciones al arrancar.
RUN pnpm install --frozen-lockfile

COPY . .
# generate no se conecta a la base, pero prisma.config.mjs exige la variable.
RUN DATABASE_OWNER_URL=postgresql://build@localhost/build pnpm exec prisma generate \
 && pnpm run build

USER node
EXPOSE 3000
# Migraciones + usuario de la API (sin RLS bypass) y luego el servidor.
CMD ["sh", "-c", "pnpm run db:prepare && node dist/main.js"]
