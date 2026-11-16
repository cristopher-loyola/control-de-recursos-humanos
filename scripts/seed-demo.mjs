// Empresa de demostración «Accesos Demo» (código demo-manual) con datos
// ficticios, para tomar las capturas del manual del panel. Solo desarrollo.
//
//   DEMO_PASSWORD='contraseña de prueba' pnpm demo:manual
//
// Se puede ejecutar las veces que haga falta: deja la empresa en el mismo
// estado y vuelve a generar las checadas de las últimas dos semanas a partir
// de hoy (las anteriores de esta empresa se borran). Usa el código compilado
// en dist/ para provisionar la empresa y recibir las checadas igual que la API.
import 'reflect-metadata';
import { createHash, generateKeyPairSync, randomUUID, sign } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { PrismaPg } from '@prisma/adapter-pg';
import { config } from 'dotenv';

config({
  path: fileURLToPath(new URL('../.env', import.meta.url)),
  quiet: true,
});

function fail(message) {
  console.error(message);
  process.exit(1);
}

if (process.env.NODE_ENV === 'production') {
  fail(
    'La empresa de demostración es solo para desarrollo (NODE_ENV=production).',
  );
}
const ownerUrl = process.env.DATABASE_OWNER_URL;
if (!ownerUrl) fail('Falta la variable de entorno DATABASE_OWNER_URL.');
const password = process.env.DEMO_PASSWORD ?? '';
if (!password) {
  fail('Indica la contraseña de prueba de las cuentas en DEMO_PASSWORD.');
}

const fromDist = (path) =>
  import(new URL(`../dist/${path}`, import.meta.url).href);
const [
  { PrismaClient },
  { provisionCompany, SYSTEM_ROLES },
  { hashPassword, passwordProblem },
  { hashPin },
  { BiometricBox },
  { FACE_DIMENSIONS, FACE_MODEL_ID, normalize },
  { CONSENT_POLICY_VERSION },
  { officialHolidays },
  { localTime },
  { addDays },
  { DeviceEvents },
  { DEVICE_KEY_ALGORITHM, readDevicePublicKey },
  { hashSessionToken, newSessionToken },
  { hashActivationCode, newActivationCode },
] = await Promise.all([
  fromDist('generated/prisma/client.js'),
  fromDist('provider/provision-company.js'),
  fromDist('auth/passwords.js'),
  fromDist('biometrics/pin.js'),
  fromDist('biometrics/biometric-box.js'),
  fromDist('biometrics/face.js'),
  fromDist('biometrics/biometrics.controller.js'),
  fromDist('holidays/official.js'),
  fromDist('attendance/schedule.js'),
  fromDist('kpis/kpi-engine.js'),
  fromDist('device/device-events.js'),
  fromDist('device/device-signature.js'),
  fromDist('auth/session-token.js'),
  fromDist('tablets/tablets.controller.js'),
]);

const problem = passwordProblem(password);
if (problem) fail(`DEMO_PASSWORD: ${problem}`);

// --- Datos ficticios ---------------------------------------------------------

const SLUG = 'demo-manual';
const COMPANY_NAME = 'Accesos Demo';
const ADMIN_EMAIL = 'admin@demo-manual.mx';
const RH_EMAIL = 'rh@demo-manual.mx';
/** Días hacia atrás con checadas, además de hoy. */
const WINDOW_DAYS = 14;
/** Las checadas de estos últimos días quedan pendientes de revisión. */
const PENDING_DAYS = 2;

const hm = (hours, minutes = 0) => hours * 60 + minutes;
const MON_FRI = 0b0011111;
const MON_SAT = 0b0111111;

const BRANCHES = [
  { code: 'MATRIZ', name: 'Matriz' },
  { code: 'NORTE', name: 'Sucursal Norte' },
];

const DEPARTMENTS = [
  {
    code: 'ALMACEN',
    name: 'Almacén',
    entry: hm(9),
    exit: hm(18),
    tolerance: 10,
    workDays: MON_FRI,
    wage: 35_000,
  },
  {
    code: 'PRODUCCION',
    name: 'Producción',
    entry: hm(7),
    exit: hm(15),
    tolerance: 10,
    workDays: MON_SAT,
    wage: 32_000,
  },
  {
    code: 'ADMINISTRACION',
    name: 'Administración',
    entry: hm(8, 30),
    exit: hm(17, 30),
    tolerance: 15,
    workDays: MON_FRI,
    wage: 45_000,
  },
];

// prettier-ignore
// Nombres inventados a propósito. face: consentimiento y rostro; pin: PIN de
// respaldo. Sin ninguno de los dos, RH captura sus checadas a mano.
const EMPLOYEES = [
  { number: '1001', given: 'Ana', family: 'Ejemplo Muestra', branch: 'MATRIZ', dept: 'ALMACEN', hired: '2023-02-06', face: true, pin: '4826' },
  { number: '1002', given: 'Bruno', family: 'Prueba Demo', branch: 'MATRIZ', dept: 'ALMACEN', hired: '2024-05-13', face: true },
  { number: '1003', given: 'Carla', family: 'Ficticia Modelo', branch: 'NORTE', dept: 'ALMACEN', hired: '2022-09-19', face: true, pin: '7391' },
  { number: '1004', given: 'Diego', family: 'Simulado Ensayo', branch: 'MATRIZ', dept: 'PRODUCCION', hired: '2021-11-08', face: true, pin: '5068' },
  { number: '1005', given: 'Elena', family: 'Muestra Piloto', branch: 'MATRIZ', dept: 'PRODUCCION', hired: '2024-01-15', face: true },
  { number: '1006', given: 'Fernando', family: 'Demo Ejemplar', branch: 'NORTE', dept: 'PRODUCCION', hired: '2023-07-03', face: true },
  { number: '1007', given: 'Gabriela', family: 'Ensayo Prueba', branch: 'NORTE', dept: 'PRODUCCION', hired: '2025-03-10', face: true, pin: '2957' },
  { number: '1008', given: 'Héctor', family: 'Modelo Ficticio', branch: 'MATRIZ', dept: 'PRODUCCION', hired: '2020-06-01', face: true, wage: 38_000 },
  { number: '1009', given: 'Irene', family: 'Piloto Simulada', branch: 'MATRIZ', dept: 'ADMINISTRACION', hired: '2022-04-04', face: true },
  { number: '1010', given: 'Jorge', family: 'Ejemplar Demo', branch: 'MATRIZ', dept: 'ADMINISTRACION', hired: '2025-08-18', face: true },
  { number: '1011', given: 'Karla', family: 'Prototipo Muestra', branch: 'NORTE', dept: 'ALMACEN', hired: '2025-10-06', pin: '8140' },
  // Alta reciente sin rostro ni PIN: hiredDaysAgo se cuenta desde hoy.
  { number: '1012', given: 'Luis', family: 'Borrador Ensayo', branch: 'MATRIZ', dept: 'PRODUCCION', hiredDaysAgo: 6 },
  // Baja antes de la ventana de checadas.
  { number: '1013', given: 'Mario', family: 'Antiguo Ejemplo', branch: 'NORTE', dept: 'ALMACEN', hired: '2021-03-01', face: true, terminatedDaysAgo: 28 },
];

const TABLETS = [
  { code: 'TAB-1', name: 'Entrada principal', branch: 'MATRIZ', linked: true },
  { code: 'TAB-2', name: 'Acceso Norte', branch: 'NORTE', linked: true },
  // Registrada en el panel y todavía sin vincular.
  { code: 'TAB-3', name: 'Sin ubicación', branch: 'NORTE', linked: false },
];

// Casos fijos para que las capturas siempre los muestren. La clave es
// «empleado@n»: n-ésimo día laborable antes de hoy (0 = el más reciente).
const SCENARIOS = {
  '1001@0': 'livenessFailed',
  '1002@5': 'absent',
  '1002@6': 'manualDay',
  '1003@3': 'forgotExitFixed',
  '1004@0': 'pinFallback',
  '1004@2': 'pinFallback',
  '1005@1': 'absent',
  '1006@4': 'doubleEntry',
  '1007@0': 'late',
  '1008@0': 'forgotExit',
  '1009@2': 'earlyExit',
  '1009@7': 'absent',
  '1010@1': 'late',
};

const MANUAL_REASONS = {
  newHire:
    'Alta reciente sin rostro registrado; RH captura la checada con la lista de firmas.',
  manualDay:
    'La tablet de la entrada se quedó sin energía; se capturó con la lista de asistencia.',
  forgotExit: 'Olvidó checar la salida; lo confirmó su supervisor.',
};
const REJECT_REASON =
  'Checada repetida por error; se conserva la primera entrada del día.';

// --- Utilidades ----------------------------------------------------------------

/** Generador determinista (mulberry32) para que cada día salga igual. */
function rng(seed) {
  let state = createHash('sha256').update(seed).digest().readUInt32LE(0);
  return () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const between = (random, min, max) =>
  min + Math.floor(random() * (max - min + 1));
const round3 = (value) => Math.round(value * 1000) / 1000;
const dateOnly = (day) => new Date(`${day}T00:00:00Z`);
/** 0 = lunes … 6 = domingo, como la máscara work_days. */
const weekday = (day) => (dateOnly(day).getUTCDay() + 6) % 7;
const minutesLater = (date, minutes) =>
  new Date(date.getTime() + minutes * 60_000);

const owner = new PrismaClient({
  adapter: new PrismaPg({ connectionString: ownerUrl }),
});

try {
  await seed();
} finally {
  await owner.$disconnect();
}

async function seed() {
  const now = new Date();
  const [{ id: existingId }] = await owner.$queryRaw`
    SELECT app_company_id_by_slug(${SLUG}) AS id`;
  const companyId =
    existingId ??
    (
      await provisionCompany(owner, {
        name: COMPANY_NAME,
        slug: SLUG,
        adminEmail: ADMIN_EMAIL,
        adminPassword: password,
      })
    ).companyId;
  console.log(
    existingId
      ? `Empresa ${SLUG} encontrada: se actualiza.`
      : `Empresa ${SLUG} creada.`,
  );

  // El dueño de la base puede ser superusuario y saltarse RLS: cada consulta
  // filtra por company_id explícitamente, además de fijar app.company_id.
  const run = (work) =>
    owner.$transaction(
      async (tx) => {
        await tx.$executeRaw`SELECT set_config('app.company_id', ${companyId}, true)`;
        return work(tx);
      },
      { maxWait: 10_000, timeout: 120_000 },
    );
  const box = new BiometricBox({
    getOrThrow(key) {
      const value = process.env[key];
      if (!value) throw new Error(`Falta la variable de entorno ${key}.`);
      return value;
    },
  });

  const { timeZone } = await run((tx) =>
    tx.company.findUniqueOrThrow({
      where: { id: companyId },
      select: { timeZone: true },
    }),
  );
  /** Instante de un día y minuto locales de la empresa. */
  const at = (day, minute, second = 0) => {
    const wanted = Date.parse(`${day}T00:00:00Z`) + minute * 60_000;
    let guess = wanted;
    for (let i = 0; i < 3; i++) {
      const local = localTime(new Date(guess), timeZone);
      const shown =
        Date.parse(`${local.day}T00:00:00Z`) + local.minuteOfDay * 60_000;
      if (shown === wanted) break;
      guess += wanted - shown;
    }
    return new Date(guess + second * 1000);
  };
  const notAfterNow = (date) => (date > now ? now : date);

  const today = localTime(now, timeZone).day;
  const start = addDays(today, -WINDOW_DAYS);
  const setupDay = addDays(today, -45);
  const employees = EMPLOYEES.map((employee) => ({
    ...employee,
    hired: employee.hired ?? addDays(today, -employee.hiredDaysAgo),
    terminatedOn:
      employee.terminatedDaysAgo === undefined
        ? null
        : addDays(today, -employee.terminatedDaysAgo),
  }));

  const audits = [];
  const audit = (actor, action, entityType, entityId, details, occurredAt) =>
    audits.push({
      companyId,
      actorType: actor.tabletId ? 'TABLET' : 'ACCOUNT',
      actorAccountId: actor.accountId ?? null,
      actorTabletId: actor.tabletId ?? null,
      action,
      entityType,
      entityId,
      details,
      occurredAt,
    });

  const [adminHash, rhHash] = await Promise.all([
    hashPassword(password),
    hashPassword(password),
  ]);
  const pins = new Map();
  for (const employee of employees) {
    if (employee.pin) pins.set(employee.number, await hashPin(employee.pin));
  }
  const tabletKeys = new Map(
    TABLETS.filter((tablet) => tablet.linked).map((tablet) => {
      const { privateKey, publicKey } = generateKeyPairSync('ec', {
        namedCurve: 'prime256v1',
      });
      return [
        tablet.code,
        {
          privateKey,
          ...readDevicePublicKey(
            publicKey.export({ type: 'spki', format: 'pem' }),
          ),
        },
      ];
    }),
  );

  const base = await run(async (tx) => {
    await tx.company.update({
      where: { id: companyId },
      data: { name: COMPANY_NAME, isActive: true },
    });

    // Lo que se genera de nuevo en cada ejecución.
    const scope = { where: { companyId } };
    await tx.attendancePhoto.deleteMany(scope);
    await tx.attendanceReview.deleteMany(scope);
    await tx.attendanceCorrection.deleteMany(scope);
    await tx.attendanceEvent.deleteMany(scope);
    await tx.manualAttendanceEntry.deleteMany(scope);
    await tx.payrollClosure.deleteMany(scope);
    await tx.faceTemplate.deleteMany(scope);
    await tx.biometricConsent.deleteMany(scope);
    await tx.employeePin.deleteMany(scope);
    await tx.deviceKey.deleteMany(scope);
    await tx.tabletActivation.deleteMany(scope);
    await tx.auditEntry.deleteMany({
      where: { companyId, action: { not: 'company.provisioned' } },
    });
    await tx.auditEntry.updateMany({
      where: { companyId, action: 'company.provisioned' },
      data: { occurredAt: at(setupDay, hm(9)) },
    });

    // Roles del sistema con los permisos actuales del código.
    const catalog = new Map(
      (await tx.permission.findMany()).map((p) => [p.code, p.id]),
    );
    const roles = {};
    for (const [code, role] of Object.entries(SYSTEM_ROLES)) {
      const row = await tx.role.findUniqueOrThrow({
        where: { companyId_code: { companyId, code } },
      });
      await tx.rolePermission.createMany({
        data: role.permissions.map((permission) => ({
          companyId,
          roleId: row.id,
          permissionId: catalog.get(permission),
        })),
        skipDuplicates: true,
      });
      roles[code] = row.id;
    }

    const upsertAccount = async (email, passwordHash, roleId, createdAt) => {
      const data = {
        passwordHash,
        status: 'ACTIVE',
        disabledAt: null,
        disabledReason: null,
        failedLoginCount: 0,
        lockedUntil: null,
      };
      const account = await tx.account.upsert({
        where: { companyId_email: { companyId, email } },
        create: { companyId, email, createdAt, ...data },
        update: data,
      });
      await tx.accountRole.deleteMany({
        where: { companyId, accountId: account.id },
      });
      await tx.accountRole.create({
        data: { companyId, accountId: account.id, roleId },
      });
      return account.id;
    };
    const adminId = await upsertAccount(
      ADMIN_EMAIL,
      adminHash,
      roles.ADMIN,
      at(setupDay, hm(9)),
    );
    const rhId = await upsertAccount(
      RH_EMAIL,
      rhHash,
      roles.RH,
      at(setupDay, hm(10, 30)),
    );
    const admin = { accountId: adminId };
    const rh = { accountId: rhId };
    audit(
      admin,
      'account.created',
      'account',
      rhId,
      { email: RH_EMAIL, roles: ['RH'], employeeId: null },
      at(setupDay, hm(10, 30)),
    );

    const branchIds = {};
    for (const [i, branch] of BRANCHES.entries()) {
      const createdAt = at(setupDay, hm(9, 10 + i * 3));
      const row = await tx.branch.upsert({
        where: { companyId_code: { companyId, code: branch.code } },
        create: { companyId, code: branch.code, name: branch.name, createdAt },
        update: { name: branch.name, timeZone: null, isActive: true },
      });
      branchIds[branch.code] = row.id;
      audit(
        admin,
        'branch.created',
        'branch',
        row.id,
        { code: branch.code, name: branch.name },
        createdAt,
      );
    }

    const departments = {};
    for (const [i, dept] of DEPARTMENTS.entries()) {
      const createdAt = at(setupDay, hm(9, 25 + i * 4));
      const data = {
        name: dept.name,
        entryMinutes: dept.entry,
        exitMinutes: dept.exit,
        toleranceMinutes: dept.tolerance,
        workDays: dept.workDays,
        dailyWageCents: dept.wage,
        isActive: true,
      };
      const row = await tx.department.upsert({
        where: { companyId_code: { companyId, code: dept.code } },
        create: { companyId, code: dept.code, createdAt, ...data },
        update: data,
      });
      departments[dept.code] = { ...dept, id: row.id };
      audit(
        admin,
        'department.created',
        'department',
        row.id,
        { code: dept.code, ...data },
        createdAt,
      );
    }

    const employeeIds = {};
    for (const [i, employee] of employees.entries()) {
      const createdAt = employee.hiredDaysAgo
        ? at(employee.hired, hm(8, 40))
        : at(addDays(setupDay, 1), hm(9, 5 + i * 3));
      const terminated = employee.terminatedOn !== null;
      const data = {
        branchId: branchIds[employee.branch],
        departmentId: departments[employee.dept].id,
        givenNames: employee.given,
        familyNames: employee.family,
        hiredOn: dateOnly(employee.hired),
        dailyWageCents: employee.wage ?? null,
        employmentStatus: terminated ? 'TERMINATED' : 'ACTIVE',
        terminationEffectiveOn: terminated
          ? dateOnly(employee.terminatedOn)
          : null,
        terminationReason: terminated ? 'Renuncia voluntaria.' : null,
        terminationByAccountId: terminated ? rhId : null,
      };
      const row = await tx.employee.upsert({
        where: {
          companyId_employeeNumber: {
            companyId,
            employeeNumber: employee.number,
          },
        },
        create: {
          companyId,
          employeeNumber: employee.number,
          createdAt,
          ...data,
        },
        // El alta en el sistema va antes de las checadas: la asistencia solo se
        // mide desde que el empleado está registrado.
        update: { createdAt, ...data },
      });
      employeeIds[employee.number] = row.id;
      audit(
        rh,
        'employee.created',
        'employee',
        row.id,
        { employeeNumber: employee.number },
        createdAt,
      );
      if (terminated) {
        audit(
          rh,
          'employee.updated',
          'employee',
          row.id,
          {
            employmentStatus: 'TERMINATED',
            terminationEffectiveOn: employee.terminatedOn,
            terminationReason: data.terminationReason,
          },
          at(employee.terminatedOn, hm(12)),
        );
      }
    }

    // Consentimiento, rostro (vectores al azar, no de una persona) y PIN.
    const faceTemplates = {};
    for (const [i, employee] of employees.entries()) {
      const employeeId = employeeIds[employee.number];
      const recordedAt = at(addDays(setupDay, 2), hm(10, i * 4));
      if (employee.face) {
        const documentReference = `DEMO-CONS-${employee.number}`;
        const revokedAt = employee.terminatedOn
          ? at(employee.terminatedOn, hm(12, 5))
          : null;
        const consent = await tx.biometricConsent.create({
          data: {
            companyId,
            employeeId,
            recordedByAccountId: rhId,
            policyVersion: CONSENT_POLICY_VERSION,
            signedDocumentObjectKey: documentReference,
            grantedAt: recordedAt,
            revokedAt,
            createdAt: recordedAt,
          },
        });
        audit(
          rh,
          'consent.recorded',
          'employee',
          employeeId,
          { consentId: consent.id, documentReference },
          recordedAt,
        );

        const random = rng(`rostro:${employee.number}`);
        const face = Array.from(
          { length: FACE_DIMENSIONS },
          () => random() * 2 - 1,
        );
        const samples = Array.from({ length: 5 }, () =>
          normalize(face.map((v) => v + (random() * 2 - 1) * 0.05)),
        );
        const templateId = randomUUID();
        const enrolledAt = minutesLater(recordedAt, 2);
        await tx.faceTemplate.create({
          data: {
            id: templateId,
            companyId,
            employeeId,
            consentId: consent.id,
            modelId: FACE_MODEL_ID,
            sampleCount: samples.length,
            encryptedSamples: box.sealFace(
              companyId,
              employeeId,
              templateId,
              samples,
            ),
            createdByAccountId: rhId,
            createdAt: enrolledAt,
            revokedAt,
          },
        });
        audit(
          rh,
          'face.enrolled',
          'employee',
          employeeId,
          { faceTemplateId: templateId, consentId: consent.id },
          enrolledAt,
        );
        if (revokedAt) {
          audit(
            rh,
            'consent.revoked',
            'employee',
            employeeId,
            {
              consentId: consent.id,
              documentReference,
              faceTemplatesRevoked: 1,
            },
            revokedAt,
          );
        } else {
          faceTemplates[employee.number] = templateId;
        }
      }
      const pin = pins.get(employee.number);
      if (pin) {
        await tx.employeePin.create({
          data: {
            companyId,
            employeeId,
            salt: new Uint8Array(pin.salt),
            pinHash: new Uint8Array(pin.hash),
            iterations: pin.iterations,
          },
        });
        audit(
          rh,
          'pin.assigned',
          'employee',
          employeeId,
          undefined,
          minutesLater(recordedAt, 3),
        );
      }
    }

    // Festivos de la LFT del año (y del anterior si la ventana lo cruza) y uno
    // propio de Producción.
    const holidays = [];
    for (const year of new Set(
      [start, today].map((day) => Number(day.slice(0, 4))),
    )) {
      const existing = new Set(
        (
          await tx.holiday.findMany({
            where: {
              companyId,
              departmentId: null,
              day: {
                gte: dateOnly(`${year}-01-01`),
                lte: dateOnly(`${year}-12-31`),
              },
            },
            select: { day: true },
          })
        ).map((holiday) => holiday.day.toISOString().slice(0, 10)),
      );
      const missing = officialHolidays(year).filter(
        (holiday) => !existing.has(holiday.day),
      );
      if (missing.length > 0) {
        await tx.holiday.createMany({
          data: missing.map((holiday) => ({
            companyId,
            day: dateOnly(holiday.day),
            name: holiday.name,
          })),
        });
      }
      audit(
        rh,
        'holiday.official_added',
        'holiday',
        String(year),
        { added: officialHolidays(year).length },
        at(addDays(setupDay, 3), hm(11)),
      );
      const plantDay = dateOnly(`${year}-12-11`);
      const departmentId = departments.PRODUCCION.id;
      if (
        !(await tx.holiday.findFirst({
          where: { companyId, day: plantDay, departmentId },
        }))
      ) {
        const created = await tx.holiday.create({
          data: {
            companyId,
            day: plantDay,
            name: 'Mantenimiento de planta',
            departmentId,
          },
        });
        audit(
          rh,
          'holiday.created',
          'holiday',
          created.id,
          { day: `${year}-12-11`, name: created.name, departmentId },
          at(addDays(setupDay, 3), hm(11, 5)),
        );
      }
    }
    for (const holiday of await tx.holiday.findMany({
      where: { companyId, day: { gte: dateOnly(start), lte: dateOnly(today) } },
      select: { day: true, departmentId: true },
    })) {
      holidays.push({
        day: holiday.day.toISOString().slice(0, 10),
        departmentId: holiday.departmentId,
      });
    }

    await tx.kpiTarget.upsert({
      where: { companyId },
      create: { companyId },
      update: {
        attendanceMin: 95,
        punctualityMin: 90,
        bradfordWarning: 51,
        bradfordAlert: 201,
      },
    });
    const policy = {
      periodKind: 'WEEKLY',
      weekStart: 1,
      paidDays: 7,
      absenceDays: 1,
      latesPerAbsence: 3,
    };
    await tx.payrollPolicy.upsert({
      where: { companyId },
      create: { companyId, ...policy },
      update: policy,
    });
    audit(
      admin,
      'payroll.policy_changed',
      'payroll_policy',
      companyId,
      policy,
      at(addDays(setupDay, 3), hm(12)),
    );

    // Tablets: dos vinculadas (una por sucursal) y una pendiente.
    const tablets = {};
    for (const [i, tablet] of TABLETS.entries()) {
      const createdAt = at(addDays(setupDay, 4), hm(9, i * 10));
      const key = tabletKeys.get(tablet.code);
      const data = {
        branchId: branchIds[tablet.branch],
        name: tablet.name,
        status: key ? 'ACTIVE' : 'PENDING',
        tokenHash: key ? hashSessionToken(newSessionToken(companyId)) : null,
        lastSeenAt: key ? now : null,
        lastSynchronizedAt: null,
      };
      const row = await tx.tablet.upsert({
        where: { companyId_code: { companyId, code: tablet.code } },
        create: { companyId, code: tablet.code, createdAt, ...data },
        update: data,
      });
      audit(
        admin,
        'tablet.created',
        'tablet',
        row.id,
        { code: tablet.code, branchId: data.branchId },
        createdAt,
      );
      if (!key) continue;
      const activatedAt = minutesLater(createdAt, 4);
      await tx.tabletActivation.create({
        data: {
          companyId,
          tabletId: row.id,
          codeHash: hashActivationCode(newActivationCode()),
          createdByAccountId: adminId,
          expiresAt: minutesLater(createdAt, 16),
          usedAt: activatedAt,
          createdAt: minutesLater(createdAt, 1),
        },
      });
      const deviceKey = await tx.deviceKey.create({
        data: {
          companyId,
          tabletId: row.id,
          algorithm: DEVICE_KEY_ALGORITHM,
          publicKeyPem: key.pem,
          fingerprint: key.fingerprint,
          activatedAt,
        },
      });
      audit(
        admin,
        'tablet.activation_issued',
        'tablet',
        row.id,
        undefined,
        minutesLater(createdAt, 1),
      );
      audit(
        { tabletId: row.id },
        'tablet.activated',
        'tablet',
        row.id,
        { deviceKeyId: deviceKey.id, keyFingerprint: key.fingerprint },
        activatedAt,
      );
      tablets[tablet.branch] = {
        privateKey: key.privateKey,
        device: {
          companyId,
          tabletId: row.id,
          branchId: row.branchId,
          deviceKeyId: deviceKey.id,
          publicKeyPem: key.pem,
        },
      };
    }

    return {
      rhId,
      branchIds,
      employeeIds,
      departments,
      faceTemplates,
      holidays,
      tablets,
    };
  });

  // --- Plan de checadas -------------------------------------------------------

  const tabletPlan = [];
  const manualPlan = [];
  const rejected = new Set();
  const latest = minutesLater(now, -1);
  for (const employee of employees) {
    if (employee.terminatedOn) continue;
    const dept = base.departments[employee.dept];
    const employeeId = base.employeeIds[employee.number];
    const templateId = base.faceTemplates[employee.number] ?? null;
    const usual = templateId ? 'FACIAL' : employee.pin ? 'PIN' : 'MANUAL';
    const days = [];
    for (
      let day = employee.hired > start ? employee.hired : start;
      day <= today;
      day = addDays(day, 1)
    ) {
      const holiday = base.holidays.some(
        (h) =>
          h.day === day &&
          (h.departmentId === null || h.departmentId === dept.id),
      );
      if ((dept.workDays & (1 << weekday(day))) !== 0 && !holiday)
        days.push(day);
    }
    const past = days.filter((day) => day < today).reverse();

    for (const day of days) {
      const random = rng(`${employee.number}:${day}`);
      const scenario = SCENARIOS[`${employee.number}@${past.indexOf(day)}`];
      let absent = random() < 0.05;
      let late = random() < 0.14;
      let early = random() < 0.07;
      const pinInstead = random() < 0.04;
      if (scenario) {
        absent = scenario === 'absent';
        late = scenario === 'late';
        early = scenario === 'earlyExit';
      }
      if (absent) continue;
      const entryAt = at(
        day,
        late
          ? dept.entry + dept.tolerance + between(random, 3, 38)
          : dept.entry + between(random, -14, Math.min(6, dept.tolerance)),
        between(random, 0, 59),
      );
      const exitAt = at(
        day,
        early
          ? dept.exit - between(random, 15, 70)
          : dept.exit + between(random, 0, 22),
        between(random, 0, 59),
      );
      const similarity = round3(0.62 + random() * 0.3);
      const liveness = round3(0.86 + random() * 0.13);
      const challenged = random() < 0.1;

      const manual = (type, occurredAt, reason) => {
        if (day < today) {
          manualPlan.push({
            employeeId,
            branchId: base.branchIds[employee.branch],
            type,
            occurredAt,
            reason,
          });
        }
      };
      const tablet = (type, occurredAt, method, extra = {}) => {
        const id = randomUUID();
        tabletPlan.push({
          id,
          branch: employee.branch,
          occurredAt,
          payload: {
            employeeId,
            eventType: type,
            captureMethod: method,
            faceSimilarity: method === 'FACIAL' ? similarity : null,
            livenessScore: method === 'FACIAL' ? liveness : null,
            livenessMethod:
              method === 'FACIAL'
                ? challenged
                  ? 'passive+challenge'
                  : 'passive'
                : null,
            faceTemplateId: method === 'FACIAL' ? templateId : null,
            photoSha256: null,
            ...extra,
          },
        });
        return id;
      };

      if (usual === 'MANUAL') {
        manual('ENTRY', entryAt, MANUAL_REASONS.newHire);
        manual('EXIT', exitAt, MANUAL_REASONS.newHire);
        continue;
      }
      if (scenario === 'manualDay') {
        manual('ENTRY', entryAt, MANUAL_REASONS.manualDay);
        manual('EXIT', exitAt, MANUAL_REASONS.manualDay);
        continue;
      }
      const entryMethod =
        employee.pin &&
        (scenario === 'pinFallback' || (!scenario && pinInstead))
          ? 'PIN'
          : usual;
      tablet(
        'ENTRY',
        entryAt,
        entryMethod,
        scenario === 'livenessFailed'
          ? { livenessScore: 0.18, livenessMethod: 'failed' }
          : {},
      );
      if (scenario === 'doubleEntry') {
        rejected.add(
          tablet('ENTRY', minutesLater(entryAt, between(random, 5, 9)), usual),
        );
      }
      if (scenario === 'forgotExit') continue;
      if (scenario === 'forgotExitFixed') {
        manual('EXIT', exitAt, MANUAL_REASONS.forgotExit);
        continue;
      }
      tablet('EXIT', exitAt, usual);
    }
  }

  // --- Checadas firmadas, recibidas con la misma lógica que la API --------------

  const events = new DeviceEvents(
    { run: (_companyId, work) => run(work) },
    box,
  );
  const due = tabletPlan
    .filter((event) => event.occurredAt <= latest)
    .sort((a, b) => a.occurredAt - b.occurredAt);
  let accepted = 0;
  for (const [branch, { device, privateKey }] of Object.entries(base.tablets)) {
    let previousEventHash = null;
    const signed = due
      .filter((event) => event.branch === branch)
      .map((event, i) => {
        const payload = Buffer.from(
          JSON.stringify({
            v: 1,
            id: event.id,
            tabletId: device.tabletId,
            sequence: i + 1,
            previousEventHash,
            ...event.payload,
            occurredAt: event.occurredAt.toISOString(),
          }),
          'utf8',
        );
        previousEventHash = createHash('sha256').update(payload).digest('hex');
        return {
          payload: payload.toString('base64'),
          signature: sign('sha256', payload, privateKey).toString('base64'),
        };
      });
    for (let i = 0; i < signed.length; i += 100) {
      for (const result of await events.ingest(
        device,
        signed.slice(i, i + 100),
      )) {
        if (result.status !== 'accepted') {
          throw new Error(
            `Checada ${result.id} no aceptada: ${result.message ?? result.status}`,
          );
        }
        accepted++;
      }
    }
  }

  // --- Checadas manuales, revisiones de RH y bitácora --------------------------

  const summary = await run(async (tx) => {
    const rh = { accountId: base.rhId };
    // Las tablets envían cada checada al momento.
    await tx.$executeRaw`
      UPDATE attendance_events
      SET server_received_at = device_occurred_at + interval '4 seconds'
      WHERE company_id = ${companyId}::uuid`;

    for (const entry of manualPlan) {
      const createdAt = notAfterNow(minutesLater(entry.occurredAt, 95));
      const row = await tx.manualAttendanceEntry.create({
        data: {
          companyId,
          branchId: entry.branchId,
          employeeId: entry.employeeId,
          eventType: entry.type,
          occurredAt: entry.occurredAt,
          reason: entry.reason,
          authorAccountId: base.rhId,
          createdAt,
        },
      });
      audit(
        rh,
        'attendance.manual_recorded',
        'manual_attendance_entry',
        row.id,
        {
          employeeId: entry.employeeId,
          type: entry.type,
          occurredAt: entry.occurredAt.toISOString(),
          reason: entry.reason,
        },
        createdAt,
      );
    }

    const pendingFrom = addDays(today, -PENDING_DAYS);
    const toReview = await tx.attendanceEvent.findMany({
      where: { companyId, requiresReview: true },
      select: {
        id: true,
        captureMethod: true,
        scheduleNote: true,
        deviceOccurredAt: true,
      },
    });
    let pending = 0;
    for (const event of toReview) {
      if (localTime(event.deviceOccurredAt, timeZone).day >= pendingFrom) {
        pending++;
        continue;
      }
      const reject = rejected.has(event.id);
      const reason = reject
        ? REJECT_REASON
        : event.captureMethod === 'PIN'
          ? 'Se confirmó con su supervisor que el empleado checó con PIN.'
          : event.scheduleNote?.startsWith('Retardo')
            ? 'Retardo justificado: avisó a su supervisor antes de llegar.'
            : event.scheduleNote?.startsWith('Salida anticipada')
              ? 'Salida anticipada autorizada por su supervisor.'
              : 'Revisada con el supervisor; la checada es correcta.';
      const reviewedAt = notAfterNow(
        minutesLater(event.deviceOccurredAt, 22 * 60),
      );
      await tx.attendanceReview.create({
        data: {
          companyId,
          eventId: event.id,
          decision: reject ? 'REJECTED' : 'APPROVED',
          reviewerAccountId: base.rhId,
          reason,
          reviewedAt,
        },
      });
      audit(
        rh,
        reject ? 'attendance.rejected' : 'attendance.approved',
        'attendance_event',
        event.id,
        { reason },
        reviewedAt,
      );
    }

    await tx.auditEntry.createMany({ data: audits });
    return { reviewed: toReview.length - pending, pending };
  });

  console.log(
    `Checadas de tablet: ${accepted} (${summary.pending} pendientes de revisión, ${summary.reviewed} revisadas).`,
  );
  console.log(`Checadas manuales de RH: ${manualPlan.length}.`);
  console.log(`Empleados: ${employees.length} · Periodo: ${start} a ${today}.`);
  console.log(
    `Cuentas: ${ADMIN_EMAIL} (Administrador) y ${RH_EMAIL} (RH), con la contraseña de DEMO_PASSWORD.`,
  );
  if (process.env.AUTH_REQUIRE_MFA !== 'false') {
    console.log(
      'Nota: con AUTH_REQUIRE_MFA distinto de false, el panel pedirá doble factor.',
    );
  }
}
