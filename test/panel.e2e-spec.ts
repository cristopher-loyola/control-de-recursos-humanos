// API del panel de administración: CORS, lecturas, reporte de asistencia,
// checadas manuales y pre-nómina en el servidor.
import { randomBytes, randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import { PrismaPg } from '@prisma/adapter-pg';
import { config } from 'dotenv';
import pg from 'pg';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { configureApp } from '../src/app-setup.js';
import { AppModule } from '../src/app.module.js';
import { totpCode, totpStep } from '../src/auth/totp.js';
import { PrismaClient } from '../src/generated/prisma/client.js';
import { addDays, periodFor } from '../src/kpis/kpi-engine.js';
import { provisionCompany } from '../src/provider/provision-company.js';

config({ path: resolve(process.cwd(), '.env'), quiet: true });

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
const slugA = `panel-a-${run}`;
const slugB = `panel-b-${run}`;

let app: INestApplication;
let owner: PrismaClient;
let runtime: pg.Client;
let companyA: string;
let adminA: string;
let adminB: string;
let rhA: string;
let branchId: string;
let otherBranchId: string;
let departmentId: string;
let employeeId: string;
let tabletId: string;
let deviceKeyId: string;
let sequence = 0;
const events: Record<string, string> = {};

function http() {
  return request(app.getHttpServer());
}
function as(token: string) {
  return {
    get: (path: string) => http().get(path).set('Authorization', token),
    post: (path: string) => http().post(path).set('Authorization', token),
    put: (path: string) => http().put(path).set('Authorization', token),
    patch: (path: string) => http().patch(path).set('Authorization', token),
  };
}

const secrets = new Map<string, Buffer>();
const steps = new Map<string, number>();
async function signIn(slug: string, email: string): Promise<string> {
  const login = await http()
    .post('/api/auth/login')
    .send({ company: slug, email, password: PASSWORD })
    .expect(200);
  const pending = `Bearer ${login.body.token}`;
  if (login.body.nextStep === 'MFA_SETUP') {
    const setup = await http()
      .post('/api/auth/mfa/setup')
      .set('Authorization', pending)
      .expect(200);
    secrets.set(email, fromBase32(setup.body.secret));
  }
  const step = Math.max(totpStep(new Date()), steps.get(email) ?? 0);
  steps.set(email, step + 1);
  const verified = await http()
    .post('/api/auth/mfa/verify')
    .set('Authorization', pending)
    .send({ code: totpCode(secrets.get(email)!, step) })
    .expect(200);
  return `Bearer ${verified.body.token}`;
}

async function asOwner<T>(
  companyId: string,
  work: (
    tx: Parameters<Parameters<PrismaClient['$transaction']>[0]>[0],
  ) => Promise<T>,
) {
  return owner.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT set_config('app.company_id', ${companyId}, true)`;
    return work(tx);
  });
}

async function event(
  key: string,
  type: 'ENTRY' | 'EXIT',
  at: Date,
  requiresReview = false,
) {
  sequence += 1;
  const id = randomUUID();
  events[key] = id;
  await asOwner(companyA, (tx) =>
    tx.attendanceEvent.create({
      data: {
        id,
        companyId: companyA,
        branchId,
        tabletId,
        deviceKeyId,
        employeeId,
        eventType: type,
        captureMethod: 'FACIAL',
        deviceOccurredAt: at,
        sequence: BigInt(sequence),
        requiresReview,
        eventHash: randomBytes(32).toString('hex'),
        signedPayload: new Uint8Array([1]),
        signature: new Uint8Array([1]),
      },
    }),
  );
}

// Ciudad de México (UTC-6): una hora local del día indicado.
const local = (day: string, hhmm: string) => {
  const [h, m] = hhmm.split(':').map(Number);
  return new Date(Date.parse(`${day}T00:00:00Z`) + ((h + 6) * 60 + m) * 60_000);
};
const today = new Date(Date.now() - 6 * 3_600_000).toISOString().slice(0, 10);
// Semana completa ya transcurrida (lunes a domingo) de hace dos semanas.
const week = periodFor('week', addDays(today, -14));
const day = (offset: number) => addDays(week.start, offset);

beforeAll(async () => {
  owner = new PrismaClient({
    adapter: new PrismaPg({
      connectionString: process.env.DATABASE_OWNER_URL!,
    }),
  });
  runtime = new pg.Client({ connectionString: process.env.DATABASE_URL! });
  await runtime.connect();
  const module = await Test.createTestingModule({
    imports: [AppModule],
  }).compile();
  app = module.createNestApplication();
  configureApp(app);
  await app.listen(0, '127.0.0.1');

  companyA = (
    await provisionCompany(owner, {
      name: 'Panel A',
      slug: slugA,
      adminEmail: `admin@${slugA}.mx`,
      adminPassword: PASSWORD,
    })
  ).companyId;
  await provisionCompany(owner, {
    name: 'Panel B',
    slug: slugB,
    adminEmail: `admin@${slugB}.mx`,
    adminPassword: PASSWORD,
  });
  adminA = await signIn(slugA, `admin@${slugA}.mx`);
  adminB = await signIn(slugB, `admin@${slugB}.mx`);
  branchId = (
    await as(adminA)
      .post('/api/branches')
      .send({ code: 'MATRIZ', name: 'Matriz' })
      .expect(201)
  ).body.id;
  otherBranchId = (
    await as(adminA)
      .post('/api/branches')
      .send({ code: 'NORTE', name: 'Planta norte' })
      .expect(201)
  ).body.id;
  const roles = await as(adminA).get('/api/roles').expect(200);
  await as(adminA)
    .post('/api/accounts')
    .send({
      email: `rh@${slugA}.mx`,
      password: PASSWORD,
      roleIds: [roles.body.find((r: { code: string }) => r.code === 'RH').id],
    })
    .expect(201);
  rhA = await signIn(slugA, `rh@${slugA}.mx`);
  departmentId = (
    await as(rhA)
      .post('/api/departments')
      .send({
        name: 'Oficina',
        entryMinutes: 540,
        exitMinutes: 1080,
        toleranceMinutes: 10,
        workDays: 31,
      })
      .expect(201)
  ).body.id;
  employeeId = (
    await as(rhA)
      .post('/api/employees')
      .send({
        branchId,
        departmentId,
        givenNames: 'Ana',
        familyNames: 'López',
        hiredOn: week.start,
        dailyWageCents: 30000,
      })
      .expect(201)
  ).body.id;
  await as(rhA)
    .post('/api/employees')
    .send({
      branchId: otherBranchId,
      givenNames: 'Luis',
      familyNames: 'Pérez',
      hiredOn: week.start,
    })
    .expect(201);
  await asOwner(companyA, async (tx) => {
    tabletId = (
      await tx.tablet.create({
        data: {
          companyId: companyA,
          branchId,
          code: 'T1',
          name: 'Entrada',
          status: 'ACTIVE',
        },
      })
    ).id;
    deviceKeyId = (
      await tx.deviceKey.create({
        data: {
          companyId: companyA,
          tabletId,
          algorithm: 'ECDSA_P256_SHA256',
          publicKeyPem: 'x',
          fingerprint: randomBytes(32).toString('hex'),
        },
      })
    ).id;
  });
  // Lunes a tiempo · martes retardo (por revisar) · miércoles a viernes sin entrada.
  await event('mon-in', 'ENTRY', local(day(0), '09:00'));
  await event('mon-out', 'EXIT', local(day(0), '18:00'));
  await event('tue-in', 'ENTRY', local(day(1), '09:25'), true);
  await event('tue-out', 'EXIT', local(day(1), '18:00'));
}, 90_000);

afterAll(async () => {
  await app?.close();
  await runtime?.end();
  await owner?.$disconnect();
});

describe('Acceso desde el navegador', () => {
  it('responde CORS solo a los orígenes de ADMIN_ORIGINS', async () => {
    const allowed = await http()
      .options('/api/auth/me')
      .set('Origin', 'http://localhost:5000')
      .set('Access-Control-Request-Method', 'GET')
      .set('Access-Control-Request-Headers', 'authorization');
    expect(allowed.headers['access-control-allow-origin']).toBe(
      'http://localhost:5000',
    );
    expect(allowed.headers['access-control-allow-headers']).toMatch(
      /Authorization/i,
    );
    const denied = await http()
      .options('/api/auth/me')
      .set('Origin', 'https://otro.example')
      .set('Access-Control-Request-Method', 'GET');
    expect(denied.headers['access-control-allow-origin']).toBeUndefined();
  });
});

describe('Empleados y sucursales', () => {
  it('el administrador modifica empleados y queda en la auditoría', async () => {
    const list = await as(adminA).get('/api/employees').expect(200);
    expect(list.body.total).toBe(2);
    await as(adminA)
      .patch(`/api/employees/${employeeId}`)
      .send({ givenNames: 'Otra' })
      .expect(200);
    await as(adminA)
      .patch(`/api/employees/${employeeId}`)
      .send({ givenNames: 'Ana' })
      .expect(200);
    const audit = await as(adminA).get('/api/audit').expect(200);
    const updates = audit.body.items.filter(
      (entry: { action: string; entityId: string }) =>
        entry.action === 'employee.updated' && entry.entityId === employeeId,
    );
    expect(updates.map((entry: { details: object }) => entry.details)).toEqual(
      expect.arrayContaining([{ givenNames: 'Otra' }, { givenNames: 'Ana' }]),
    );
    expect(
      updates.map(
        (entry: { actorAccount: { email: string } }) =>
          entry.actorAccount.email,
      ),
    ).toEqual([`admin@${slugA}.mx`, `admin@${slugA}.mx`]);
  });

  it('filtra, busca y pagina', async () => {
    const byBranch = await as(rhA)
      .get(`/api/employees?branchId=${otherBranchId}`)
      .expect(200);
    expect(
      byBranch.body.items.map((e: { givenNames: string }) => e.givenNames),
    ).toEqual(['Luis']);
    const search = await as(rhA).get('/api/employees?q=lóp').expect(200);
    expect(search.body.items).toHaveLength(1);
    const none = await as(rhA)
      .get('/api/employees?departmentId=none')
      .expect(200);
    expect(none.body.items[0].givenNames).toBe('Luis');
    const page = await as(rhA)
      .get('/api/employees?pageSize=1&page=2')
      .expect(200);
    expect(page.body).toMatchObject({ total: 2, page: 2, pageSize: 1 });
    expect(page.body.items).toHaveLength(1);
    await as(rhA).get('/api/employees?pageSize=500').expect(400);
    const one = await as(rhA).get(`/api/employees/${employeeId}`).expect(200);
    expect(one.body).toMatchObject({ givenNames: 'Ana', hasFace: false });
    await as(adminB).get(`/api/employees/${employeeId}`).expect(404);
  });

  it('da de baja con motivo y reingresa', async () => {
    const luis = (
      await as(rhA).get(`/api/employees?branchId=${otherBranchId}`).expect(200)
    ).body.items[0].id;
    await as(rhA)
      .patch(`/api/employees/${luis}`)
      .send({ status: 'TERMINATED', terminationEffectiveOn: today })
      .expect(400);
    await as(rhA)
      .patch(`/api/employees/${luis}`)
      .send({
        status: 'TERMINATED',
        terminationEffectiveOn: today,
        terminationReason: 'Renuncia voluntaria por cambio de ciudad',
      })
      .expect(200);
    expect((await as(rhA).get('/api/employees').expect(200)).body.total).toBe(
      1,
    );
    expect(
      (await as(rhA).get('/api/employees?status=TERMINATED').expect(200)).body
        .items[0].terminationReason,
    ).toContain('Renuncia');
    // Sin empleados activos, la sucursal se puede desactivar.
    await as(adminA)
      .patch(`/api/branches/${otherBranchId}`)
      .send({ isActive: false })
      .expect(200);
    const back = await as(rhA)
      .patch(`/api/employees/${luis}`)
      .send({ status: 'ACTIVE', branchId })
      .expect(200);
    expect(back.body).toMatchObject({
      employmentStatus: 'ACTIVE',
      terminationReason: null,
      branch: { id: branchId },
    });
  });

  it('no desactiva una sucursal con empleados activos', async () => {
    await as(adminA)
      .patch(`/api/branches/${branchId}`)
      .send({ isActive: false })
      .expect(400);
    const renamed = await as(adminA)
      .patch(`/api/branches/${branchId}`)
      .send({ name: 'Matriz centro' })
      .expect(200);
    expect(renamed.body.name).toBe('Matriz centro');
    await as(rhA)
      .patch(`/api/branches/${branchId}`)
      .send({ name: 'x' })
      .expect(403);
  });

  it('pagina la bitácora y la filtra por acción', async () => {
    const audit = await as(adminA)
      .get('/api/audit?action=branch.&pageSize=2')
      .expect(200);
    expect(audit.body.total).toBeGreaterThanOrEqual(3);
    expect(audit.body.items).toHaveLength(2);
    expect(
      audit.body.items.every((e: { action: string }) =>
        e.action.startsWith('branch.'),
      ),
    ).toBe(true);
  });
});

describe('Reporte de asistencia y checadas manuales', () => {
  const summaryOf = async (from: string, to: string) => {
    const report = await as(rhA)
      .get(
        `/api/reports/attendance?from=${from}&to=${to}&departmentId=${departmentId}`,
      )
      .expect(200);
    return report.body;
  };

  it('resume el rango por empleado con las reglas de los KPIs', async () => {
    const report = await summaryOf(day(0), day(3));
    expect(report.period).toEqual({ start: day(0), end: day(3) });
    expect(report.summaries).toHaveLength(1);
    expect(report.summaries[0].values).toMatchObject({
      onTime: 1,
      lates: 1,
      absences: 1,
    });
    expect(
      report.summaries[0].days.map((d: { status: string }) => d.status),
    ).toEqual(['onTime', 'late', 'absent']);
    expect(report.pendingReviews).toBe(1);
    expect(report.withoutFace).toBe(1);
    await as(rhA)
      .get(`/api/reports/attendance?from=${day(3)}&to=${day(0)}`)
      .expect(400);
    await as(rhA)
      .get(`/api/reports/attendance?from=${day(0)}&to=${addDays(day(0), 120)}`)
      .expect(400);
    await as(adminB).get('/api/reports/attendance').expect(200);
  });

  it('captura una checada manual con motivo y cuenta en el reporte', async () => {
    await as(rhA)
      .post('/api/attendance/manual')
      .send({
        employeeId,
        type: 'ENTRY',
        occurredAt: local(day(2), '09:05').toISOString(),
        reason: 'corto',
      })
      .expect(400);
    await as(rhA)
      .post('/api/attendance/manual')
      .send({
        employeeId,
        type: 'ENTRY',
        occurredAt: new Date(Date.now() + 3_600_000).toISOString(),
        reason: 'Olvidó checar al llegar a la oficina',
      })
      .expect(400);
    const created = await as(rhA)
      .post('/api/attendance/manual')
      .send({
        employeeId,
        type: 'ENTRY',
        occurredAt: local(day(2), '09:05').toISOString(),
        reason: 'Olvidó checar al llegar a la oficina',
      })
      .expect(201);
    expect(created.body.author.email).toBe(`rh@${slugA}.mx`);
    const report = await summaryOf(day(0), day(3));
    expect(report.summaries[0].values).toMatchObject({
      onTime: 2,
      lates: 1,
      absences: 0,
    });
    const list = await as(rhA)
      .get(`/api/attendance/manual?from=${day(0)}&to=${day(7)}`)
      .expect(200);
    expect(list.body).toHaveLength(1);
    const audit = await as(adminA)
      .get('/api/audit?action=attendance.manual_recorded')
      .expect(200);
    expect(audit.body.total).toBe(1);
  });
});

describe('Pre-nómina', () => {
  it('guarda reglas, calcula, cierra, congela y reabre con motivo', async () => {
    await as(rhA)
      .put('/api/payroll/policy')
      .send({
        kind: 'weekly',
        weekStart: 1,
        paidDays: 40,
        absenceDays: 1,
        latesPerAbsence: 0,
      })
      .expect(400);
    await as(rhA)
      .put('/api/payroll/policy')
      .send({
        kind: 'weekly',
        weekStart: 1,
        paidDays: 7,
        absenceDays: 1,
        latesPerAbsence: 0,
      })
      .expect(200);
    await as(adminA).put('/api/payroll/policy').send({}).expect(403);

    const open = await as(rhA)
      .get(`/api/payroll?anchor=${day(2)}`)
      .expect(200);
    expect(open.body.period).toEqual({ start: week.start, end: week.end });
    expect(open.body.ended).toBe(true);
    const ana = open.body.lines.find(
      (l: { name: string }) => l.name === 'Ana López',
    );
    // Jueves y viernes sin entrada: 2 faltas × $300 sobre 7 días pagados.
    expect(ana).toMatchObject({
      absences: 2,
      lates: 1,
      gross: 210000,
      deduction: 60000,
      total: 150000,
    });

    // Queda el retardo del martes por revisar.
    await as(rhA)
      .post('/api/payroll/close')
      .send({ anchor: day(2) })
      .expect(400);
    await as(rhA)
      .post(`/api/attendance/${events['tue-in']}/review`)
      .send({ decision: 'approved', reason: 'Tráfico reportado al jefe' })
      .expect(200);
    const closed = await as(rhA)
      .post('/api/payroll/close')
      .send({ anchor: day(2) })
      .expect(200);
    expect(closed.body.closure.actor).toBe(`rh@${slugA}.mx`);
    await as(rhA)
      .post('/api/payroll/close')
      .send({ anchor: day(2) })
      .expect(400);

    // Cerrado: no admite checadas manuales en el periodo.
    await as(rhA)
      .post('/api/attendance/manual')
      .send({
        employeeId,
        type: 'ENTRY',
        occurredAt: local(day(3), '09:00').toISOString(),
        reason: 'Olvidó checar al llegar a la oficina',
      })
      .expect(400);

    // Reabrir es del administrador.
    await as(rhA)
      .post('/api/payroll/reopen')
      .send({ anchor: day(2), reason: 'Faltó capturar una incapacidad' })
      .expect(403);
    await as(adminA)
      .post('/api/payroll/reopen')
      .send({ anchor: day(2), reason: 'corto' })
      .expect(400);
    const reopened = await as(adminA)
      .post('/api/payroll/reopen')
      .send({ anchor: day(2), reason: 'Faltó capturar una incapacidad' })
      .expect(200);
    expect(reopened.body.closure).toBeNull();
    expect(reopened.body.reopened.actor).toBe(`admin@${slugA}.mx`);
    await as(rhA)
      .post('/api/attendance/manual')
      .send({
        employeeId,
        type: 'ENTRY',
        occurredAt: local(day(3), '09:00').toISOString(),
        reason: 'Olvidó checar al llegar a la oficina',
      })
      .expect(201);
  });

  it('aísla las tablas nuevas por empresa y no deja editar evidencia', async () => {
    for (const table of [
      'manual_attendance_entries',
      'payroll_policies',
      'payroll_closures',
    ]) {
      await runtime.query('BEGIN');
      const hidden = await runtime.query(
        `SELECT count(*)::int AS n FROM ${table}`,
      );
      await runtime.query('ROLLBACK');
      expect(hidden.rows[0].n).toBe(0);
    }
    await runtime.query('BEGIN');
    await runtime.query(`SELECT set_config('app.company_id', $1, true)`, [
      companyA,
    ]);
    await expect(
      runtime.query(
        `UPDATE manual_attendance_entries SET reason = 'cambiada a mano'`,
      ),
    ).rejects.toThrow(/permission denied/);
    await runtime.query('ROLLBACK');
    await runtime.query('BEGIN');
    await runtime.query(`SELECT set_config('app.company_id', $1, true)`, [
      companyA,
    ]);
    await expect(runtime.query(`DELETE FROM payroll_closures`)).rejects.toThrow(
      /permission denied/,
    );
    await runtime.query('ROLLBACK');
  });
});
