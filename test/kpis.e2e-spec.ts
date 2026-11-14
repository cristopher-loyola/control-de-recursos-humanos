// Revisiones de RH, festivos y KPIs de empleado calculados en el servidor.
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
import { officialHolidays } from '../src/holidays/official.js';
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
const slugA = `kpis-a-${run}`;
const slugB = `kpis-b-${run}`;

let app: INestApplication;
let owner: PrismaClient;
let runtime: pg.Client;
let companyA: string;
let companyB: string;
let rhA: string;
let adminA: string;
let adminB: string;
let employeeId: string;
let departmentId: string;
let tabletId: string;
let deviceKeyId: string;
let branchId: string;
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
    delete: (path: string) => http().delete(path).set('Authorization', token),
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

/** Checada como la guardaría el servidor al recibirla de la tablet. */
async function event(
  key: string,
  type: 'ENTRY' | 'EXIT',
  at: Date,
  requiresReview = false,
  captureMethod: 'FACIAL' | 'PIN' = 'FACIAL',
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
        captureMethod,
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

// Semana completa ya transcurrida: la del lunes de hace dos semanas.
const today = new Date(Date.now() - 6 * 3_600_000).toISOString().slice(0, 10);
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
      name: 'KPIs A',
      slug: slugA,
      adminEmail: `admin@${slugA}.mx`,
      adminPassword: PASSWORD,
    })
  ).companyId;
  companyB = (
    await provisionCompany(owner, {
      name: 'KPIs B',
      slug: slugB,
      adminEmail: `admin@${slugB}.mx`,
      adminPassword: PASSWORD,
    })
  ).companyId;
  adminA = await signIn(slugA, `admin@${slugA}.mx`);
  adminB = await signIn(slugB, `admin@${slugB}.mx`);
  branchId = (
    await as(adminA)
      .post('/api/branches')
      .send({ code: 'MATRIZ', name: 'Matriz' })
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
      })
      .expect(201)
  ).body.id;
  await asOwner(companyA, async (tx) => {
    // Registrados antes de la semana de checadas: si no, esos días no se miden.
    await tx.employee.updateMany({
      data: { createdAt: new Date(`${week.start}T06:00:00Z`) },
    });
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

  // Lunes a tiempo · martes retardo de 20 min · miércoles entrada con PIN (para revisión) ·
  // jueves festivo de la empresa · viernes falta.
  await event('mon-in', 'ENTRY', local(day(0), '09:00'));
  await event('mon-out', 'EXIT', local(day(0), '18:00'));
  await event('tue-in', 'ENTRY', local(day(1), '09:20'), true);
  await event('tue-out', 'EXIT', local(day(1), '18:00'));
  await event('wed-in', 'ENTRY', local(day(2), '08:55'), true, 'PIN');
  await event('wed-out', 'EXIT', local(day(2), '17:30'), true);
}, 90_000);

afterAll(async () => {
  await app?.close();
  await runtime?.end();
  for (const id of [companyA, companyB]) {
    if (!id) continue;
    await asOwner(id, async (tx) => {
      await tx.attendanceReview.deleteMany({ where: { companyId: id } });
      await tx.holiday.deleteMany({ where: { companyId: id } });
      await tx.kpiTarget.deleteMany({ where: { companyId: id } });
      await tx.attendanceEvent.deleteMany({ where: { companyId: id } });
      await tx.deviceKey.deleteMany({ where: { companyId: id } });
      await tx.auditEntry.deleteMany({ where: { companyId: id } });
      await tx.tablet.deleteMany({ where: { companyId: id } });
      await tx.session.deleteMany({ where: { companyId: id } });
      await tx.accountRole.deleteMany({ where: { companyId: id } });
      await tx.rolePermission.deleteMany({ where: { companyId: id } });
      await tx.employee.deleteMany({ where: { companyId: id } });
      await tx.account.deleteMany({ where: { companyId: id } });
      await tx.department.deleteMany({ where: { companyId: id } });
      await tx.branch.deleteMany({ where: { companyId: id } });
      await tx.role.deleteMany({ where: { companyId: id } });
      await tx.company.delete({ where: { id } });
    });
  }
  await owner?.$disconnect();
});

describe('Festivos en el servidor', () => {
  it('agrega los de la LFT sin duplicarlos y uno propio de la empresa', async () => {
    const year = Number(day(3).slice(0, 4));
    const first = await as(rhA)
      .post('/api/holidays/official')
      .send({ year })
      .expect(200);
    expect(first.body.added).toBe(officialHolidays(year).length);
    expect(
      (await as(rhA).post('/api/holidays/official').send({ year }).expect(200))
        .body.added,
    ).toBe(0);
    await as(rhA)
      .post('/api/holidays')
      .send({ day: day(3), name: 'Aniversario' })
      .expect(201);
    await as(rhA)
      .post('/api/holidays')
      .send({ day: day(3), name: 'Otro' })
      .expect(409);
  });
});

describe('Revisión de checadas', () => {
  it('lista las del día con su estado y la aprobación del sistema', async () => {
    const list = await as(rhA)
      .get(`/api/attendance?day=${day(1)}`)
      .expect(200);
    expect(list.body.map((e: { status: string }) => e.status)).toEqual([
      'pending',
      'approved',
    ]);
    const monday = await as(rhA)
      .get(`/api/attendance?day=${day(0)}`)
      .expect(200);
    expect(monday.body[0]).toMatchObject({
      status: 'approved',
      review: null,
      hasPhoto: false,
    });
  });

  it('aprueba y rechaza una sola vez, y deja motivo', async () => {
    await as(rhA)
      .post(`/api/attendance/${events['tue-in']}/review`)
      .send({ decision: 'approved', reason: 'corto' })
      .expect(400);
    await as(rhA)
      .post(`/api/attendance/${events['tue-in']}/review`)
      .send({ decision: 'approved', reason: 'Tráfico reportado al jefe' })
      .expect(200);
    await as(rhA)
      .post(`/api/attendance/${events['tue-in']}/review`)
      .send({ decision: 'rejected', reason: 'Tráfico reportado al jefe' })
      .expect(409);
    // La entrada con PIN del miércoles no era de Ana: se rechaza.
    await as(rhA)
      .post(`/api/attendance/${events['wed-in']}/review`)
      .send({ decision: 'rejected', reason: 'La foto muestra a otra persona' })
      .expect(200);
    await as(rhA)
      .post(`/api/attendance/${events['mon-in']}/review`)
      .send({ decision: 'approved', reason: 'Ya estaba aprobada' })
      .expect(409);
  });
});

describe('KPIs de empleado', () => {
  it('el tablero calcula asistencia, puntualidad, horas y semáforo', async () => {
    const board = await as(rhA)
      .get(`/api/kpis/employees?period=week&anchor=${day(2)}`)
      .expect(200);
    expect(board.body.period).toEqual(week);
    expect(board.body.targets).toEqual({
      attendanceMin: 95,
      punctualityMin: 90,
      bradfordWarning: 51,
      bradfordAlert: 201,
    });
    const ana = board.body.rows[0];
    // lun a tiempo · mar retardo · mié rechazada = falta · jue festivo · vie falta.
    expect(ana.values).toMatchObject({
      scheduledDays: 4,
      attendedDays: 2,
      absences: 2,
      onTime: 1,
      lates: 1,
      lateMinutes: 20,
      workedMinutes: 540 + 520,
      pendingReview: 1, // la salida del miércoles sigue por revisar
      attendanceRate: 0.5,
      punctualityRate: 0.5,
    });
    expect(ana.lights).toMatchObject({
      attendance: 'alert',
      punctuality: 'alert',
    });
    expect(ana.bradford).toMatchObject({ spells: 1, days: 2 });
    expect(ana).not.toHaveProperty('days');
  });

  it('la ficha trae el detalle por día y 6 periodos de serie', async () => {
    const detail = await as(rhA)
      .get(`/api/kpis/employees/${employeeId}?period=week&anchor=${day(2)}`)
      .expect(200);
    expect(detail.body.series).toHaveLength(6);
    expect(detail.body.series.at(-1).period).toEqual(week);
    expect(detail.body.days.map((d: { status: string }) => d.status)).toEqual([
      'onTime',
      'late',
      'absent',
      'absent',
    ]);
  });

  it('no cuenta faltas en una sucursal que todavía no checa', async () => {
    const otherBranch = (
      await as(adminA)
        .post('/api/branches')
        .send({ code: 'NORTE', name: 'Norte' })
        .expect(201)
    ).body.id;
    const zoe = (
      await as(rhA)
        .post('/api/employees')
        .send({
          branchId: otherBranch,
          departmentId,
          givenNames: 'Zoe',
          familyNames: 'Zapata',
          hiredOn: week.start,
        })
        .expect(201)
    ).body.id;
    await asOwner(companyA, (tx) =>
      tx.employee.update({
        where: { id: zoe },
        data: { createdAt: new Date(`${week.start}T06:00:00Z`) },
      }),
    );
    const board = await as(rhA)
      .get(`/api/kpis/employees?period=week&anchor=${day(2)}`)
      .expect(200);
    const row = board.body.rows.find(
      (r: { employee: { id: string } }) => r.employee.id === zoe,
    );
    expect(row.values).toMatchObject({ scheduledDays: 0, absences: 0 });
    expect(row.bradford).toMatchObject({ spells: 0, days: 0, score: 0 });
    await asOwner(companyA, (tx) =>
      tx.employee.update({
        where: { id: zoe },
        data: { employmentStatus: 'TERMINATED' },
      }),
    );
  });

  it('las metas cambian el semáforo y solo se guardan valores válidos', async () => {
    await as(rhA)
      .put('/api/kpis/targets')
      .send({
        attendanceMin: 50,
        punctualityMin: 50,
        bradfordWarning: 10,
        bradfordAlert: 5,
      })
      .expect(400);
    await as(rhA)
      .put('/api/kpis/targets')
      .send({
        attendanceMin: 50,
        punctualityMin: 50,
        bradfordWarning: 2,
        bradfordAlert: 5,
      })
      .expect(200);
    const board = await as(rhA)
      .get(`/api/kpis/employees?period=week&anchor=${day(2)}`)
      .expect(200);
    expect(board.body.rows[0].lights).toEqual({
      attendance: 'ok',
      punctuality: 'ok',
      bradford: 'warning',
    });
  });
});

describe('Aislamiento', () => {
  it('otra empresa no ve KPIs, festivos ni checadas de A', async () => {
    expect(
      (await as(adminB).get('/api/kpis/employees?period=week').expect(200)).body
        .rows,
    ).toEqual([]);
    expect((await as(adminB).get('/api/holidays').expect(200)).body).toEqual(
      [],
    );
    expect(
      (
        await as(adminB)
          .get(`/api/attendance?day=${day(0)}`)
          .expect(200)
      ).body,
    ).toEqual([]);
    await as(adminB)
      .get(`/api/kpis/employees/${employeeId}?period=week`)
      .expect(404);
  });

  it('RLS en las tablas nuevas y revisiones que no se editan', async () => {
    for (const table of ['attendance_reviews', 'holidays', 'kpi_targets']) {
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
      runtime.query(`UPDATE attendance_reviews SET reason = 'cambiada a mano'`),
    ).rejects.toThrow(/permission denied/);
    await runtime.query('ROLLBACK');
  });
});
