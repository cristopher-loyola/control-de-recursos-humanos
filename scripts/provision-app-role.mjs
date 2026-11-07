// Crea o actualiza el usuario con el que se conecta la API.
// Se ejecuta con DATABASE_OWNER_URL después de aplicar las migraciones.
import { fileURLToPath } from 'node:url';
import { config } from 'dotenv';
import pg from 'pg';

config({
  path: fileURLToPath(new URL('../.env', import.meta.url)),
  quiet: true,
});

function required(key) {
  const value = process.env[key]?.trim();
  if (!value) {
    throw new Error(`Falta la variable de entorno ${key}.`);
  }
  return new URL(value);
}

const owner = required('DATABASE_OWNER_URL');
const runtime = required('DATABASE_URL');
const user = decodeURIComponent(runtime.username);
const password = decodeURIComponent(runtime.password);

if (!user || !password) {
  throw new Error('DATABASE_URL debe incluir usuario y contraseña.');
}
if (user === decodeURIComponent(owner.username)) {
  throw new Error('DATABASE_URL debe usar un usuario distinto al dueño de la base.');
}
if (password.length < 16) {
  throw new Error('La contraseña de DATABASE_URL debe tener al menos 16 caracteres.');
}

const client = new pg.Client({ connectionString: owner.toString() });
await client.connect();
try {
  const role = client.escapeIdentifier(user);
  const secret = client.escapeLiteral(password);
  const { rowCount } = await client.query('SELECT 1 FROM pg_roles WHERE rolname = $1', [user]);
  const verb = rowCount ? 'ALTER' : 'CREATE';
  await client.query(
    `${verb} ROLE ${role} LOGIN PASSWORD ${secret} NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE`,
  );
  await client.query(`GRANT accesos_app TO ${role}`);
  console.log(`Usuario de la API listo: ${user}`);
} finally {
  await client.end();
}
