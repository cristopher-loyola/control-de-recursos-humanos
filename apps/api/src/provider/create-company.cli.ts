// Alta de empresa por el proveedor, mientras no exista el panel de proveedor (fase 4).
// Uso: pnpm --dir apps/api run empresa:crear -- --nombre "Empresa" --codigo empresa --correo admin@empresa.mx
import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { PrismaPg } from '@prisma/adapter-pg';
import { config } from 'dotenv';
import { PrismaClient } from '../generated/prisma/client.js';
import { provisionCompany } from './provision-company.js';

config({ path: resolve(process.cwd(), '../../.env'), quiet: true });

const { values } = parseArgs({
  options: {
    nombre: { type: 'string' },
    codigo: { type: 'string' },
    correo: { type: 'string' },
  },
});
if (!values.nombre || !values.codigo || !values.correo) {
  console.error('Indica --nombre, --codigo y --correo.');
  process.exit(1);
}
const ownerUrl = process.env.DATABASE_OWNER_URL;
if (!ownerUrl) {
  console.error('Falta la variable de entorno DATABASE_OWNER_URL.');
  process.exit(1);
}

const temporaryPassword = randomBytes(12).toString('base64url');
const owner = new PrismaClient({
  adapter: new PrismaPg({ connectionString: ownerUrl }),
});
try {
  await provisionCompany(owner, {
    name: values.nombre,
    slug: values.codigo,
    adminEmail: values.correo,
    adminPassword: temporaryPassword,
  });
  console.log(`Empresa creada. Código: ${values.codigo}`);
  console.log(`Administrador: ${values.correo.toLowerCase()}`);
  console.log(
    `Contraseña temporal (se muestra una sola vez): ${temporaryPassword}`,
  );
  console.log('Al entrar se pedirá configurar la verificación en dos pasos.');
} finally {
  await owner.$disconnect();
}
