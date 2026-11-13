// Fase 1 del servidor: varias tablets vinculadas a un mismo backend. La tablet
// se vincula con un código de un solo uso, descarga lo necesario para checar sin
// red y sube checadas firmadas que el servidor acepta, revisa y no duplica.
import {
  createHash,
  generateKeyPairSync,
  randomBytes,
  sign,
} from 'node:crypto';
import type { KeyObject } from 'node:crypto';
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
import { localTime } from '../src/attendance/schedule.js';
import { totpCode, totpStep } from '../src/auth/totp.js';
import { FACE_MODEL_ID } from '../src/biometrics/face.js';
import { PrismaClient } from '../src/generated/prisma/client.js';
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
const slugA = `tablets-a-${run}`;
const slugB = `tablets-b-${run}`;
const TIME_ZONE = 'America/Mexico_City';

const secrets = new Map<string, Buffer>();
const nextStep = new Map<string, number>();

let app: INestApplication;
let owner: PrismaClient;
let runtime: pg.Client;

function http() {
  return request(app.getHttpServer());
}

function codeFor(email: string): string {
  const step = Math.max(totpStep(new Date()), nextStep.get(email) ?? 0);
  nextStep.set(email, step + 1);
  return totpCode(secrets.get(email)!, step);
}

/** Inicia sesión como lo hace la app de la tablet: token Bearer. */
async function bearerSignIn(slug: string, email: string): Promise<string> {
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
  const verified = await http()
    .post('/api/auth/mfa/verify')
    .set('Authorization', pending)
    .send({ code: codeFor(email) })
    .expect(200);
  return `Bearer ${verified.body.token}`;
}

function as(token: string) {
  return {
    get: (path: string) => http().get(path).set('Authorization', token),
    post: (path: string) => http().post(path).set('Authorization', token),
    put: (path: string) => http().put(path).set('Authorization', token),
    patch: (path: string) => http().patch(path).set('Authorization', token),
    delete: (path: string) => http().delete(path).set('Authorization', token),
  };
}

async function inCompany<T>(companyId: string | null, work: () => Promise<T>) {
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

/** Tablet simulada: llave EC P-256 como la de Android Keystore. */
class FakeTablet {
  readonly keys = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  token = '';
  tabletId = '';
  sequence = 0;
  lastHash: string | null = null;

  get publicKey(): string {
    return this.keys.publicKey
      .export({ type: 'spki', format: 'pem' })
      .toString();
  }

  device() {
    return as(`Bearer ${this.token}`);
  }

  event(
    fields: {
      employeeId: string;
      eventType: 'ENTRY' | 'EXIT';
      captureMethod: 'FACIAL' | 'PIN' | 'MANUAL_BACKUP';
      occurredAt?: Date;
      faceTemplateId?: string | null;
      photo?: Buffer;
    },
    signer: KeyObject = this.keys.privateKey,
  ) {
    this.sequence += 1;
    const payload = Buffer.from(
      JSON.stringify({
        v: 1,
        id: crypto.randomUUID(),
        tabletId: this.tabletId,
        sequence: this.sequence,
        previousEventHash: this.lastHash,
        employeeId: fields.employeeId,
        eventType: fields.eventType,
        captureMethod: fields.captureMethod,
        occurredAt: (fields.occurredAt ?? new Date()).toISOString(),
        faceSimilarity: fields.captureMethod === 'FACIAL' ? 0.72 : null,
        faceTemplateId: fields.faceTemplateId ?? null,
        photoSha256: fields.photo
          ? createHash('sha256').update(fields.photo).digest('hex')
          : null,
      }),
    );
    this.lastHash = createHash('sha256').update(payload).digest('hex');
    return {
      id: JSON.parse(payload.toString()).id as string,
      body: {
        payload: payload.toString('base64'),
        signature: sign('sha256', payload, signer).toString('base64'),
        photo: fields.photo?.toString('base64') ?? null,
      },
    };
  }
}

function sampleSet(seed: number, count = 3): number[][] {
  const base = Array.from({ length: 128 }, (_, i) =>
    Math.sin(seed * 31 + i * 7),
  );
  return Array.from({ length: count }, (_, k) =>
    base.map((v, i) => v + 0.01 * Math.cos(i * (k + 1))),
  );
}

let companyA: string;
let companyB: string;
let adminA: string;
let adminB: string;
let rhA: string;
let branchId: string;
let departmentId: string;
let employeeId: string;
let faceTemplateId: string;
let tabletOneId: string;
let tabletTwoId: string;
const one = new FakeTablet();
const two = new FakeTablet();

async function issueCode(tabletId: string) {
  const issued = await as(adminA)
    .post(`/api/tablets/${tabletId}/activation`)
    .expect(200);
  expect(issued.body.code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
  return issued.body.code as string;
}

async function link(tablet: FakeTablet, tabletId: string) {
  const code = await issueCode(tabletId);
  const activated = await http()
    .post('/api/device/activate')
    .send({
      company: slugA,
      code: code.toLowerCase(),
      publicKey: tablet.publicKey,
    })
    .expect(200);
  tablet.token = activated.body.token;
  tablet.tabletId = tabletId;
  return code;
}

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
      name: 'Tablets A',
      slug: slugA,
      adminEmail: `admin@${slugA}.mx`,
      adminPassword: PASSWORD,
    })
  ).companyId;
  companyB = (
    await provisionCompany(owner, {
      name: 'Tablets B',
      slug: slugB,
      adminEmail: `admin@${slugB}.mx`,
      adminPassword: PASSWORD,
    })
  ).companyId;
  adminA = await bearerSignIn(slugA, `admin@${slugA}.mx`);
  adminB = await bearerSignIn(slugB, `admin@${slugB}.mx`);

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
      roleIds: [
        roles.body.find((role: { code: string }) => role.code === 'RH').id,
      ],
    })
    .expect(201);
  rhA = await bearerSignIn(slugA, `rh@${slugA}.mx`);
}, 60_000);

async function removeCompany(companyId: string) {
  await owner.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT set_config('app.company_id', ${companyId}, true)`;
    await tx.attendancePhoto.deleteMany({ where: { companyId } });
    await tx.attendanceEvent.deleteMany({ where: { companyId } });
    await tx.faceTemplate.deleteMany({ where: { companyId } });
    await tx.employeePin.deleteMany({ where: { companyId } });
    await tx.biometricConsent.deleteMany({ where: { companyId } });
    await tx.tabletActivation.deleteMany({ where: { companyId } });
    await tx.deviceKey.deleteMany({ where: { companyId } });
    await tx.auditEntry.deleteMany({ where: { companyId } });
    await tx.tablet.deleteMany({ where: { companyId } });
    await tx.session.deleteMany({ where: { companyId } });
    await tx.accountRole.deleteMany({ where: { companyId } });
    await tx.rolePermission.deleteMany({ where: { companyId } });
    await tx.employee.deleteMany({ where: { companyId } });
    await tx.account.deleteMany({ where: { companyId } });
    await tx.department.deleteMany({ where: { companyId } });
    await tx.branch.deleteMany({ where: { companyId } });
    await tx.role.deleteMany({ where: { companyId } });
    await tx.company.delete({ where: { id: companyId } });
  });
}

afterAll(async () => {
  await app?.close();
  await runtime?.end();
  for (const id of [companyA, companyB]) if (id) await removeCompany(id);
  await owner?.$disconnect();
});

describe('Sesión de RH desde la tablet', () => {
  it('RH usa su token Bearer con los permisos de su rol', async () => {
    const me = await as(rhA).get('/api/auth/me').expect(200);
    expect(me.body.roles.map((role: { code: string }) => role.code)).toEqual([
      'RH',
    ]);
    expect(me.body.permissions).toContain('biometrics.manage');
  });

  it('un Bearer inventado no da acceso', async () => {
    await as(`Bearer ${companyA}.${'x'.repeat(43)}`)
      .get('/api/auth/me')
      .expect(401);
  });
});

describe('Alta y vinculación de tablets', () => {
  it('el administrador da de alta dos tablets; RH solo las consulta', async () => {
    tabletOneId = (
      await as(adminA)
        .post('/api/tablets')
        .send({ branchId, code: 'ENTRADA-1', name: 'Entrada principal' })
        .expect(201)
    ).body.id;
    tabletTwoId = (
      await as(adminA)
        .post('/api/tablets')
        .send({ branchId, code: 'ENTRADA-2', name: 'Almacén' })
        .expect(201)
    ).body.id;
    await as(rhA)
      .post('/api/tablets')
      .send({ branchId, code: 'X', name: 'X' })
      .expect(403);
    const listed = await as(rhA).get('/api/tablets').expect(200);
    expect(listed.body.map((t: { status: string }) => t.status)).toEqual([
      'PENDING',
      'PENDING',
    ]);
  });

  it('el código sirve una sola vez y entrega el token del dispositivo', async () => {
    const code = await link(one, tabletOneId);
    await http()
      .post('/api/device/activate')
      .send({ company: slugA, code, publicKey: new FakeTablet().publicKey })
      .expect(401);
    const listed = await as(adminA).get('/api/tablets').expect(200);
    expect(
      listed.body.find((t: { id: string }) => t.id === tabletOneId).status,
    ).toBe('ACTIVE');
  });

  it('un código vencido o de otra empresa no vincula', async () => {
    const code = await issueCode(tabletTwoId);
    await http()
      .post('/api/device/activate')
      .send({ company: slugB, code, publicKey: two.publicKey })
      .expect(401);
    await owner.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT set_config('app.company_id', ${companyA}, true)`;
      await tx.tabletActivation.updateMany({
        where: { tabletId: tabletTwoId, usedAt: null },
        data: { expiresAt: new Date(Date.now() - 1000) },
      });
    });
    await http()
      .post('/api/device/activate')
      .send({ company: slugA, code, publicKey: two.publicKey })
      .expect(401);
    await link(two, tabletTwoId);
  });

  it('una llave que no es EC P-256 se rechaza', async () => {
    const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
    await http()
      .post('/api/device/activate')
      .send({
        company: slugA,
        code: await issueCode(tabletTwoId),
        publicKey: rsa.publicKey.export({ type: 'spki', format: 'pem' }),
      })
      .expect(400);
  });

  it('sin clave ni ubicación se crea igual; la ubicación se pone después', async () => {
    const created = await as(adminA)
      .post('/api/tablets')
      .send({ branchId })
      .expect(201);
    expect(created.body.code).toBe('TAB-3');
    expect(created.body.name).toBe('Sin ubicación');
    const renamed = await as(adminA)
      .patch(`/api/tablets/${created.body.id}`)
      .send({ name: 'Recepción' })
      .expect(200);
    expect(renamed.body.name).toBe('Recepción');
    await as(rhA)
      .patch(`/api/tablets/${created.body.id}`)
      .send({ name: 'Otra' })
      .expect(403);
    await as(adminA)
      .patch(`/api/tablets/${created.body.id}`)
      .send({})
      .expect(400);
    const issued = await as(adminA)
      .post(`/api/tablets/${created.body.id}/activation`)
      .expect(200);
    expect(issued.body.code).toMatch(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
    expect(issued.body.company).toBe(slugA);
    expect(issued.body.qr).toBeNull();
    expect(issued.body.serverUrl).toBeNull();
  });

  it('las rutas de tablet no aceptan una sesión de RH ni al revés', async () => {
    await as(rhA).get('/api/device/sync').expect(401);
    await one.device().get('/api/employees').expect(401);
  });
});

describe('Datos que la tablet necesita para checar sin red', () => {
  it('RH registra departamento, empleado, consentimiento, rostro y PIN', async () => {
    // Entrada a la hora actual de la empresa: la checada de la prueba es a tiempo.
    const now = localTime(new Date(), TIME_ZONE).minuteOfDay;
    departmentId = (
      await as(rhA)
        .post('/api/departments')
        .send({
          name: 'Almacén',
          entryMinutes: now,
          exitMinutes: (now + 480) % 1440,
          toleranceMinutes: 30,
          workDays: 127,
        })
        .expect(201)
    ).body.id;
    const employee = await as(rhA)
      .post('/api/employees')
      .send({ branchId, departmentId, givenNames: 'Ana', familyNames: 'López' })
      .expect(201);
    employeeId = employee.body.id;
    expect(employee.body.employeeNumber).toBe('1');

    await as(rhA)
      .post(`/api/employees/${employeeId}/face`)
      .send({ modelId: FACE_MODEL_ID, samples: sampleSet(1) })
      .expect(400);
    await as(rhA)
      .post(`/api/employees/${employeeId}/consents`)
      .send({ kind: 'recorded', documentReference: 'FOLIO-0001' })
      .expect(200);
    faceTemplateId = (
      await as(rhA)
        .post(`/api/employees/${employeeId}/face`)
        .send({ modelId: FACE_MODEL_ID, samples: sampleSet(1) })
        .expect(201)
    ).body.id;
    await as(rhA)
      .put(`/api/employees/${employeeId}/pin`)
      .send({ pin: '1234' })
      .expect(400);
    await as(rhA)
      .put(`/api/employees/${employeeId}/pin`)
      .send({ pin: '4821' })
      .expect(204);
  });

  it('el mismo rostro no se registra para otro empleado', async () => {
    const other = await as(rhA)
      .post('/api/employees')
      .send({ branchId, givenNames: 'Luis', familyNames: 'Pérez' })
      .expect(201);
    expect(other.body.employeeNumber).toBe('2');
    await as(rhA)
      .post(`/api/employees/${other.body.id}/consents`)
      .send({ kind: 'recorded', documentReference: 'FOLIO-0002' })
      .expect(200);
    await as(rhA)
      .post(`/api/employees/${other.body.id}/face`)
      .send({ modelId: FACE_MODEL_ID, samples: sampleSet(1) })
      .expect(409);
  });

  it('la sincronización entrega rostro y PIN, y responde 304 si no cambió', async () => {
    const first = await one.device().get('/api/device/sync').expect(200);
    const ana = first.body.employees.find(
      (e: { id: string }) => e.id === employeeId,
    );
    expect(ana.face.id).toBe(faceTemplateId);
    expect(ana.face.samples).toHaveLength(3);
    expect(ana.pin.iterations).toBe(20000);
    expect(first.body.departments[0].name).toBe('Almacén');
    expect(first.body.lastSequence).toBe(0);
    await one
      .device()
      .get('/api/device/sync')
      .set('If-None-Match', first.headers.etag)
      .expect(304);
  });
});

describe('Logo de la empresa', () => {
  // PNG de 1×1 px.
  const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==';

  it('el administrador lo sube; RH no puede y no se aceptan SVG', async () => {
    await as(rhA)
      .put('/api/company/logo')
      .send({ mime: 'image/png', data: png })
      .expect(403);
    const svg = Buffer.from(
      '<svg xmlns="http://www.w3.org/2000/svg"/>',
    ).toString('base64');
    await as(adminA)
      .put('/api/company/logo')
      .send({ mime: 'image/svg+xml', data: svg })
      .expect(400);
    await as(adminA)
      .put('/api/company/logo')
      .send({ mime: 'image/jpeg', data: png })
      .expect(400);
    const saved = await as(adminA)
      .put('/api/company/logo')
      .send({ mime: 'image/png', data: png })
      .expect(200);
    expect(saved.body.logoUpdatedAt).toBeTruthy();
    const me = await as(adminA).get('/api/auth/me').expect(200);
    expect(me.body.company.logoUpdatedAt).toBe(saved.body.logoUpdatedAt);
  });

  it('se ve sin sesión por código de empresa y lo baja la tablet', async () => {
    const image = await http().get(`/api/companies/${slugA}/logo`).expect(200);
    expect(image.headers['content-type']).toBe('image/png');
    expect(image.headers['x-content-type-options']).toBe('nosniff');
    expect(Buffer.from(image.body).toString('base64')).toBe(png);
    await http().get(`/api/companies/${slugB}/logo`).expect(404);

    const sync = await one.device().get('/api/device/sync').expect(200);
    expect(sync.body.company.logoUpdatedAt).toBeTruthy();
    const logo = await one.device().get('/api/device/logo').expect(200);
    expect(logo.body).toMatchObject({ mime: 'image/png', data: png });
    await as(adminA).get('/api/device/logo').expect(401);
  });

  it('al quitarlo deja de mostrarse', async () => {
    await as(adminA).delete('/api/company/logo').expect(200);
    await http().get(`/api/companies/${slugA}/logo`).expect(404);
    const logo = await one.device().get('/api/device/logo').expect(200);
    expect(logo.body.data).toBeNull();
    const me = await as(adminA).get('/api/auth/me').expect(200);
    expect(me.body.company.logoUpdatedAt).toBeNull();
  });
});

describe('Checadas firmadas', () => {
  let firstEvent: ReturnType<FakeTablet['event']>;

  it('una checada facial a tiempo se acepta sin revisión', async () => {
    firstEvent = one.event({
      employeeId,
      eventType: 'ENTRY',
      captureMethod: 'FACIAL',
      faceTemplateId,
    });
    const sent = await one
      .device()
      .post('/api/device/events')
      .send({ events: [firstEvent.body] })
      .expect(200);
    expect(sent.body.results).toEqual([
      { id: firstEvent.id, status: 'accepted', requiresReview: false },
    ]);
  });

  it('reenviar la misma checada no la duplica', async () => {
    const sent = await one
      .device()
      .post('/api/device/events')
      .send({ events: [firstEvent.body] })
      .expect(200);
    expect(sent.body.results[0].status).toBe('duplicate');
  });

  it('una firma de otra llave se rechaza sin guardar nada', async () => {
    const forged = one.event(
      {
        employeeId,
        eventType: 'EXIT',
        captureMethod: 'FACIAL',
        faceTemplateId,
      },
      generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey,
    );
    one.sequence -= 1;
    one.lastHash = createHash('sha256')
      .update(Buffer.from(firstEvent.body.payload, 'base64'))
      .digest('hex');
    const sent = await one
      .device()
      .post('/api/device/events')
      .send({ events: [forged.body] })
      .expect(200);
    expect(sent.body.results[0]).toMatchObject({ status: 'rejected' });
  });

  it('la salida con PIN guarda la foto cifrada y queda para revisión', async () => {
    const photo = Buffer.from([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]);
    const exit = one.event({
      employeeId,
      eventType: 'EXIT',
      captureMethod: 'PIN',
      photo,
    });
    const sent = await one
      .device()
      .post('/api/device/events')
      .send({ events: [exit.body] })
      .expect(200);
    expect(sent.body.results[0]).toEqual({
      id: exit.id,
      status: 'accepted',
      requiresReview: true,
    });
    const stored = await owner.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT set_config('app.company_id', ${companyA}, true)`;
      return tx.attendancePhoto.findUnique({ where: { eventId: exit.id } });
    });
    expect(Buffer.from(stored!.encryptedJpeg).includes(photo)).toBe(false);
  });

  it('otra tablet que checa de nuevo la entrada del día la deja para revisión', async () => {
    const again = two.event({
      employeeId,
      eventType: 'ENTRY',
      captureMethod: 'FACIAL',
      faceTemplateId,
    });
    await two
      .device()
      .post('/api/device/events')
      .send({ events: [again.body] })
      .expect(200);
    const event = await owner.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT set_config('app.company_id', ${companyA}, true)`;
      return tx.attendanceEvent.findUniqueOrThrow({ where: { id: again.id } });
    });
    expect(event.requiresReview).toBe(true);
    expect(event.reviewReasons).toContain(
      'Ya había una entrada de este empleado ese día.',
    );
    expect(event.tabletId).toBe(tabletTwoId);
  });

  it('la tablet nueva ve las checadas hechas en otra', async () => {
    const synced = await two.device().get('/api/device/sync').expect(200);
    expect(
      synced.body.recentEvents.map((e: { eventType: string }) => e.eventType),
    ).toEqual(['ENTRY', 'EXIT', 'ENTRY']);
    expect(synced.body.lastSequence).toBe(1);
  });

  it('revocar el consentimiento retira el rostro de las tablets', async () => {
    await as(rhA)
      .post(`/api/employees/${employeeId}/consents`)
      .send({ kind: 'revoked', documentReference: 'FOLIO-0001' })
      .expect(200);
    const synced = await one.device().get('/api/device/sync').expect(200);
    expect(
      synced.body.employees.find((e: { id: string }) => e.id === employeeId)
        .face,
    ).toBeNull();
  });

  it('una tablet revocada deja de sincronizar', async () => {
    await as(adminA).post(`/api/tablets/${tabletTwoId}/revoke`).expect(200);
    await two.device().get('/api/device/sync').expect(401);
    await as(adminA).post(`/api/tablets/${tabletTwoId}/activation`).expect(400);
  });
});

describe('Aislamiento de los datos nuevos', () => {
  it('la empresa B no ve tablets ni empleados de A', async () => {
    expect((await as(adminB).get('/api/tablets').expect(200)).body).toEqual([]);
    await as(adminB).post(`/api/tablets/${tabletOneId}/activation`).expect(404);
  });

  it('RLS limita las tablas nuevas y las fotos no se editan', async () => {
    for (const table of [
      'face_templates',
      'employee_pins',
      'attendance_photos',
      'tablet_activations',
    ]) {
      const hidden = await inCompany(null, () =>
        runtime.query(`SELECT count(*)::int AS n FROM ${table}`),
      );
      expect(hidden.rows[0].n).toBe(0);
      const other = await inCompany(companyB, () =>
        runtime.query(`SELECT count(*)::int AS n FROM ${table}`),
      );
      expect(other.rows[0].n).toBe(0);
    }
    await expect(
      inCompany(companyA, () =>
        runtime.query(`UPDATE attendance_photos SET sha256 = sha256`),
      ),
    ).rejects.toThrow(/permission denied/);
    await expect(
      inCompany(companyA, () => runtime.query('DELETE FROM face_templates')),
    ).rejects.toThrow(/permission denied/);
  });
});
