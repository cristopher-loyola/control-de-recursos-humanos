// Criterio de cierre de la fase 0: el proveedor crea una empresa; su administrador
// crea una sucursal y una cuenta de RH; cada rol solo ve lo que le corresponde y
// ninguna empresa ve datos de otra, ni por la API ni directamente en PostgreSQL.
import { randomBytes } from 'node:crypto';
import { resolve } from 'node:path';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import { PrismaPg } from '@prisma/adapter-pg';
import { config } from 'dotenv';
import pg from 'pg';
import request from 'supertest';
import type TestAgent from 'supertest/lib/agent.js';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { configureApp } from '../src/app-setup.js';
import { AppModule } from '../src/app.module.js';
import { totpCode, totpStep } from '../src/auth/totp.js';
import { PrismaClient } from '../src/generated/prisma/client.js';
import { provisionCompany } from '../src/provider/provision-company.js';

config({ path: resolve(process.cwd(), '../../.env'), quiet: true });

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function fromBase32(text: string): Buffer {
  let bits = 0;
  let value = 0;
  const bytes: number[] = [];
  for (const char of text) {
    value = (value << 5) | BASE32.indexOf(char);
    bits += 5;
    if (bits >= 8) {
      bytes.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(bytes);
}

const run = randomBytes(4).toString('hex');
const PASSWORD = 'contraseña de prueba segura';
const companyA = { slug: `prueba-a-${run}`, admin: `admin@a-${run}.mx` };
const companyB = { slug: `prueba-b-${run}`, admin: `admin@b-${run}.mx` };

/** Secretos TOTP capturados durante la configuración, por cuenta. */
const secrets = new Map<string, Buffer>();
/** Siguiente paso utilizable por cuenta: el servidor rechaza códigos repetidos. */
const nextStep = new Map<string, number>();

let app: INestApplication;
let owner: PrismaClient;
let runtime: pg.Client;

function agent(): TestAgent {
  return request.agent(app.getHttpServer());
}

function codeFor(email: string): string {
  const secret = secrets.get(email);
  if (!secret) {
    throw new Error(`Sin secreto TOTP para ${email}`);
  }
  const step = Math.max(totpStep(new Date()), nextStep.get(email) ?? 0);
  nextStep.set(email, step + 1);
  return totpCode(secret, step);
}

async function signIn(
  slug: string,
  email: string,
  password = PASSWORD,
): Promise<TestAgent> {
  const client = agent();
  const login = await client
    .post('/api/auth/login')
    .send({ company: slug, email, password })
    .expect(200);
  if (login.body.nextStep === 'MFA_SETUP') {
    const setup = await client.post('/api/auth/mfa/setup').expect(200);
    expect(setup.body.uri).toMatch(/^otpauth:\/\/totp\//);
    secrets.set(email, fromBase32(setup.body.secret));
  }
  await client
    .post('/api/auth/mfa/verify')
    .send({ code: codeFor(email) })
    .expect(200);
  return client;
}

async function roleId(client: TestAgent, code: string): Promise<string> {
  const roles = await client.get('/api/roles').expect(200);
  return roles.body.find((role: { code: string }) => role.code === code).id;
}

async function inCompany<T>(
  companyId: string | null,
  work: () => Promise<T>,
): Promise<T> {
  await runtime.query('BEGIN');
  try {
    if (companyId) {
      await runtime.query(`SELECT set_config('app.company_id', $1, true)`, [
        companyId,
      ]);
    }
    return await work();
  } finally {
    await runtime.query('ROLLBACK');
  }
}

let idsA: { companyId: string };
let idsB: { companyId: string };
let adminA: TestAgent;
let adminB: TestAgent;
let rhA: TestAgent;
let rhAccountId: string;
let branchA: { id: string };

beforeAll(async () => {
  const ownerUrl = process.env.DATABASE_OWNER_URL;
  const runtimeUrl = process.env.DATABASE_URL;
  if (!ownerUrl || !runtimeUrl) {
    throw new Error(
      'Las pruebas e2e necesitan DATABASE_OWNER_URL y DATABASE_URL.',
    );
  }
  owner = new PrismaClient({
    adapter: new PrismaPg({ connectionString: ownerUrl }),
  });
  runtime = new pg.Client({ connectionString: runtimeUrl });
  await runtime.connect();

  const module = await Test.createTestingModule({
    imports: [AppModule],
  }).compile();
  app = module.createNestApplication();
  configureApp(app);
  await app.listen(0, '127.0.0.1');

  idsA = await provisionCompany(owner, {
    name: 'Empresa A',
    slug: companyA.slug,
    adminEmail: companyA.admin,
    adminPassword: PASSWORD,
  });
  idsB = await provisionCompany(owner, {
    name: 'Empresa B',
    slug: companyB.slug,
    adminEmail: companyB.admin,
    adminPassword: PASSWORD,
  });
  adminA = await signIn(companyA.slug, companyA.admin);
  adminB = await signIn(companyB.slug, companyB.admin);
}, 60_000);

/** Borra las empresas de prueba con el usuario dueño; la API no tiene permiso de borrar. */
async function removeCompany(companyId: string): Promise<void> {
  await owner.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT set_config('app.company_id', ${companyId}, true)`;
    await tx.auditEntry.deleteMany({ where: { companyId } });
    await tx.session.deleteMany({ where: { companyId } });
    await tx.accountRole.deleteMany({ where: { companyId } });
    await tx.rolePermission.deleteMany({ where: { companyId } });
    await tx.account.deleteMany({ where: { companyId } });
    await tx.employee.deleteMany({ where: { companyId } });
    await tx.branch.deleteMany({ where: { companyId } });
    await tx.role.deleteMany({ where: { companyId } });
    await tx.company.delete({ where: { id: companyId } });
  });
}

afterAll(async () => {
  await app?.close();
  await runtime?.end();
  for (const ids of [idsA, idsB]) {
    if (ids) {
      await removeCompany(ids.companyId);
    }
  }
  await owner?.$disconnect();
});

describe('Inicio de sesión', () => {
  it('el estado del servicio es público y lo demás exige sesión', async () => {
    await agent().get('/api/health').expect(200);
    await agent().get('/api/branches').expect(401);
  });

  it('la contraseña sola no da acceso: falta el segundo factor', async () => {
    const client = agent();
    await client
      .post('/api/auth/login')
      .send({
        company: companyA.slug,
        email: companyA.admin,
        password: PASSWORD,
      })
      .expect(200)
      .expect(({ body }) => expect(body.nextStep).toBe('MFA_CODE'));
    await client.get('/api/branches').expect(401);
    await client.post('/api/auth/mfa/setup').expect(403);
  });

  it('rechaza el mismo código dos veces', async () => {
    const client = agent();
    await client
      .post('/api/auth/login')
      .send({
        company: companyA.slug,
        email: companyA.admin,
        password: PASSWORD,
      })
      .expect(200);
    const used = totpCode(
      secrets.get(companyA.admin)!,
      (nextStep.get(companyA.admin) ?? 1) - 1,
    );
    await client.post('/api/auth/mfa/verify').send({ code: used }).expect(401);
  });

  it('no revela si falla la empresa, el correo o la contraseña', async () => {
    const attempts = [
      { company: 'no-existe', email: companyA.admin, password: PASSWORD },
      { company: companyA.slug, email: 'nadie@a.mx', password: PASSWORD },
      { company: companyB.slug, email: companyA.admin, password: PASSWORD },
    ];
    for (const attempt of attempts) {
      const response = await agent()
        .post('/api/auth/login')
        .send(attempt)
        .expect(401);
      expect(response.body.message).toBe(
        'Empresa, correo o contraseña incorrectos.',
      );
    }
  });

  it('bloquea la cuenta tras 5 contraseñas incorrectas', async () => {
    const email = `bloqueo@a-${run}.mx`;
    await adminA
      .post('/api/accounts')
      .send({
        email,
        password: PASSWORD,
        roleIds: [await roleId(adminA, 'EMPLOYEE')],
      })
      .expect(201);
    for (let i = 1; i <= 4; i++) {
      await agent()
        .post('/api/auth/login')
        .send({
          company: companyA.slug,
          email,
          password: 'contraseña equivocada',
        })
        .expect(401);
    }
    await agent()
      .post('/api/auth/login')
      .send({
        company: companyA.slug,
        email,
        password: 'contraseña equivocada',
      })
      .expect(429);
    await agent()
      .post('/api/auth/login')
      .send({ company: companyA.slug, email, password: PASSWORD })
      .expect(429);
  });

  it('rechaza escrituras desde otro origen', async () => {
    await adminA
      .post('/api/branches')
      .set('Origin', 'https://sitio-ajeno.example')
      .send({ code: 'X', name: 'X' })
      .expect(403);
  });
});

describe('Criterio de cierre: administrador, sucursal y cuenta de RH', () => {
  it('el administrador crea una sucursal y una cuenta de RH', async () => {
    const branch = await adminA
      .post('/api/branches')
      .send({ code: 'MATRIZ', name: 'Matriz' })
      .expect(201);
    branchA = branch.body;

    const rh = await adminA
      .post('/api/accounts')
      .send({
        email: `rh@a-${run}.mx`,
        password: PASSWORD,
        roleIds: [await roleId(adminA, 'RH')],
      })
      .expect(201);
    rhAccountId = rh.body.id;
    expect(
      rh.body.roles.map((entry: { role: { code: string } }) => entry.role.code),
    ).toEqual(['RH']);
    expect(rh.body).not.toHaveProperty('passwordHash');

    rhA = await signIn(companyA.slug, `rh@a-${run}.mx`);
  });

  it('RH ve sucursales y administra empleados, pero no cuentas, bitácora ni sucursales', async () => {
    const branches = await rhA.get('/api/branches').expect(200);
    expect(branches.body.map((branch: { id: string }) => branch.id)).toContain(
      branchA.id,
    );

    await rhA
      .post('/api/employees')
      .send({
        branchId: branchA.id,
        employeeNumber: 'E-001',
        givenNames: 'Ana',
        familyNames: 'López',
        hiredOn: '2026-11-01',
      })
      .expect(201);
    await rhA.get('/api/employees').expect(200);

    await rhA
      .post('/api/branches')
      .send({ code: 'OTRA', name: 'Otra' })
      .expect(403);
    await rhA.get('/api/accounts').expect(403);
    await rhA.get('/api/audit').expect(403);
    await rhA
      .put(`/api/accounts/${idsA.companyId}/roles`)
      .send({ roleIds: [] })
      .expect(403);
  });

  it('el administrador no ve ni crea empleados', async () => {
    await adminA.get('/api/employees').expect(403);
    await adminA.post('/api/employees').send({}).expect(403);
  });

  it('el empleado solo consulta su propia cuenta', async () => {
    const email = `empleado@a-${run}.mx`;
    await adminA
      .post('/api/accounts')
      .send({
        email,
        password: PASSWORD,
        roleIds: [await roleId(adminA, 'EMPLOYEE')],
      })
      .expect(201);
    const employee = await signIn(companyA.slug, email);

    const me = await employee.get('/api/auth/me').expect(200);
    expect(me.body.email).toBe(email);
    expect(me.body.permissions).toEqual(['self.read']);
    for (const path of [
      '/api/company',
      '/api/branches',
      '/api/employees',
      '/api/accounts',
      '/api/roles',
      '/api/audit',
    ]) {
      await employee.get(path).expect(403);
    }
  });

  it('los cambios de rol y de cuenta quedan en la bitácora', async () => {
    await adminA
      .put(`/api/accounts/${rhAccountId}/roles`)
      .send({
        roleIds: [await roleId(adminA, 'RH'), await roleId(adminA, 'EMPLOYEE')],
      })
      .expect(200);

    const audit = await adminA.get('/api/audit').expect(200);
    const actions = audit.body.map((entry: { action: string }) => entry.action);
    expect(actions).toEqual(
      expect.arrayContaining([
        'company.provisioned',
        'branch.created',
        'account.created',
        'account.roles_changed',
      ]),
    );
    const change = audit.body.find(
      (entry: { action: string }) => entry.action === 'account.roles_changed',
    );
    expect(change.details).toEqual({
      before: ['RH'],
      after: ['EMPLOYEE', 'RH'],
    });
    expect(change.actorAccount.email).toBe(companyA.admin);
  });

  it('desactivar una cuenta cierra sus sesiones al instante', async () => {
    const email = `temporal@a-${run}.mx`;
    const created = await adminA
      .post('/api/accounts')
      .send({
        email,
        password: PASSWORD,
        roleIds: [await roleId(adminA, 'EMPLOYEE')],
      })
      .expect(201);
    const temporary = await signIn(companyA.slug, email);
    await temporary.get('/api/auth/me').expect(200);

    await adminA
      .post(`/api/accounts/${created.body.id}/disable`)
      .send({ reason: 'Baja de prueba' })
      .expect(200);
    await temporary.get('/api/auth/me').expect(401);
  });

  it('nadie cambia sus propios roles ni se desactiva a sí mismo', async () => {
    const me = await adminA.get('/api/auth/me').expect(200);
    await adminA
      .post(`/api/accounts/${me.body.id}/disable`)
      .send({ reason: 'x' })
      .expect(403);
    await adminA
      .put(`/api/accounts/${me.body.id}/roles`)
      .send({ roleIds: [await roleId(adminA, 'RH')] })
      .expect(403);
  });

  it('cerrar sesión invalida la cookie', async () => {
    const client = await signIn(companyA.slug, `rh@a-${run}.mx`);
    await client.post('/api/auth/logout').expect(204);
    await client.get('/api/auth/me').expect(401);
  });
});

describe('Aislamiento entre empresas en la API', () => {
  it('la empresa B no ve sucursales, cuentas ni bitácora de A', async () => {
    const branches = await adminB.get('/api/branches').expect(200);
    expect(branches.body).toEqual([]);
    const accounts = await adminB.get('/api/accounts').expect(200);
    expect(
      accounts.body.map((account: { email: string }) => account.email),
    ).toEqual([companyB.admin]);
    const audit = await adminB.get('/api/audit').expect(200);
    expect(JSON.stringify(audit.body)).not.toContain(idsA.companyId);
  });

  it('la empresa B no puede modificar cuentas de A aunque conozca su id', async () => {
    await adminB
      .put(`/api/accounts/${rhAccountId}/roles`)
      .send({ roleIds: [await roleId(adminB, 'ADMIN')] })
      .expect(404);
    await adminB
      .post(`/api/accounts/${rhAccountId}/disable`)
      .send({ reason: 'x' })
      .expect(404);
  });

  it('la empresa B no puede usar roles de A', async () => {
    await adminB
      .post('/api/accounts')
      .send({
        email: `cruzada@b-${run}.mx`,
        password: PASSWORD,
        roleIds: [await roleId(adminA, 'ADMIN')],
      })
      .expect(400);
  });

  it('una cookie de A con la empresa cambiada no sirve en B', async () => {
    const forged = `accesos_sesion=${idsB.companyId}.${'x'.repeat(43)}`;
    await agent().get('/api/auth/me').set('Cookie', forged).expect(401);
  });
});

describe('Aislamiento en PostgreSQL (Row Level Security)', () => {
  it('el usuario de la API no es superusuario ni evita RLS', async () => {
    const { rows } = await runtime.query(
      'SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user',
    );
    expect(rows[0]).toEqual({ rolsuper: false, rolbypassrls: false });
  });

  it('toda tabla con company_id tiene RLS activado y forzado', async () => {
    const { rows } = await runtime.query(`
      SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r'
        AND (c.relname = 'companies' OR EXISTS (
          SELECT 1 FROM pg_attribute a
          WHERE a.attrelid = c.oid AND a.attname = 'company_id' AND NOT a.attisdropped))`);
    expect(rows.length).toBeGreaterThanOrEqual(16);
    for (const row of rows) {
      expect(row, row.relname).toMatchObject({
        relrowsecurity: true,
        relforcerowsecurity: true,
      });
    }
  });

  it('sin empresa fijada no se ve ninguna fila', async () => {
    const { rows } = await inCompany(null, () =>
      runtime.query(
        'SELECT (SELECT count(*) FROM companies) AS companies, (SELECT count(*) FROM accounts) AS accounts',
      ),
    );
    expect(rows[0]).toEqual({ companies: '0', accounts: '0' });
  });

  it('con la empresa A fijada solo se ven filas de A', async () => {
    const { rows } = await inCompany(idsA.companyId, () =>
      runtime.query('SELECT DISTINCT company_id FROM accounts'),
    );
    expect(rows).toEqual([{ company_id: idsA.companyId }]);
  });

  it('no se puede escribir una fila de B mientras se opera como A', async () => {
    await expect(
      inCompany(idsA.companyId, () =>
        runtime.query(
          `INSERT INTO branches (id, company_id, code, name, updated_at)
           VALUES (gen_random_uuid(), $1, 'INTRUSA', 'Intrusa', now())`,
          [idsB.companyId],
        ),
      ),
    ).rejects.toThrow(/row-level security/);
  });

  it('la bitácora no se puede editar ni borrar', async () => {
    await expect(
      inCompany(idsA.companyId, () =>
        runtime.query(`UPDATE audit_entries SET action = 'alterada'`),
      ),
    ).rejects.toThrow(/permission denied/);
    await expect(
      inCompany(idsA.companyId, () =>
        runtime.query('DELETE FROM audit_entries'),
      ),
    ).rejects.toThrow(/permission denied/);
  });

  it('las cuentas y empresas no se pueden borrar desde la API', async () => {
    await expect(
      inCompany(idsA.companyId, () => runtime.query('DELETE FROM accounts')),
    ).rejects.toThrow(/permission denied/);
    await expect(
      inCompany(idsA.companyId, () =>
        runtime.query(
          `INSERT INTO companies (id, name, slug, updated_at) VALUES (gen_random_uuid(), 'x', 'x', now())`,
        ),
      ),
    ).rejects.toThrow(/permission denied/);
  });
});
