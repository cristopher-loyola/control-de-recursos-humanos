import { createHash } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import type { DeviceContext } from '../auth/access.js';
import { localTime, scheduleIssue } from '../attendance/schedule.js';
import { BiometricBox } from '../biometrics/biometric-box.js';
import { TenantDatabase } from '../database/tenant-database.js';
import type { TenantTransaction } from '../database/tenant-database.js';
import { eventHash, verifyDeviceSignature } from './device-signature.js';

export const MAX_EVENTS_PER_BATCH = 100;
/** Una entrada sin salida deja de estar abierta pasado este tiempo (como en el kiosco). */
const OPEN_ENTRY_LIMIT_MS = 18 * 60 * 60_000;
const CLOCK_TOLERANCE_MS = 5 * 60_000;
const MAX_PHOTO_BYTES = 2 * 1024 * 1024;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HEX64 = /^[0-9a-f]{64}$/;

/** Lo que firma la tablet. Versión 1. */
export interface DeviceEventPayload {
  v: 1;
  id: string;
  tabletId: string;
  sequence: number;
  previousEventHash: string | null;
  employeeId: string;
  eventType: 'ENTRY' | 'EXIT';
  captureMethod: 'FACIAL' | 'PIN' | 'MANUAL_BACKUP';
  occurredAt: string;
  faceSimilarity: number | null;
  /** Prueba de vida pasiva de 0 a 1; null si no hubo (PIN o app anterior). */
  livenessScore?: number | null;
  livenessMethod?: LivenessMethod | null;
  faceTemplateId: string | null;
  photoSha256: string | null;
}

export const LIVENESS_METHODS = [
  'passive',
  'passive+challenge',
  'failed',
] as const;
export type LivenessMethod = (typeof LIVENESS_METHODS)[number];

export interface IncomingEvent {
  payload: string;
  signature: string;
  photo?: string | null;
}

export type EventResult =
  | { id: string | null; status: 'accepted'; requiresReview: boolean }
  | { id: string | null; status: 'duplicate' }
  | { id: string | null; status: 'rejected'; message: string };

class Rejected extends Error {}

function base64(value: unknown, label: string, max: number): Buffer {
  if (
    typeof value !== 'string' ||
    value.length === 0 ||
    value.length > max ||
    !/^[A-Za-z0-9+/]+={0,2}$/.test(value)
  ) {
    throw new Rejected(`${label} no es válido.`);
  }
  return Buffer.from(value, 'base64');
}

export function parsePayload(
  raw: Buffer,
  tabletId: string,
): DeviceEventPayload {
  let value: Record<string, unknown>;
  try {
    value = JSON.parse(raw.toString('utf8')) as Record<string, unknown>;
  } catch {
    throw new Rejected('El contenido de la checada no es JSON.');
  }
  const nullableUuid = (v: unknown) =>
    v === null || (typeof v === 'string' && UUID.test(v));
  const occurredAt =
    typeof value.occurredAt === 'string' ? new Date(value.occurredAt) : null;
  if (
    value === null ||
    typeof value !== 'object' ||
    value.v !== 1 ||
    typeof value.id !== 'string' ||
    !UUID.test(value.id) ||
    value.tabletId !== tabletId ||
    !Number.isSafeInteger(value.sequence) ||
    (value.sequence as number) < 1 ||
    !(
      value.previousEventHash === null ||
      (typeof value.previousEventHash === 'string' &&
        HEX64.test(value.previousEventHash))
    ) ||
    typeof value.employeeId !== 'string' ||
    !UUID.test(value.employeeId) ||
    !['ENTRY', 'EXIT'].includes(value.eventType as string) ||
    !['FACIAL', 'PIN', 'MANUAL_BACKUP'].includes(
      value.captureMethod as string,
    ) ||
    !occurredAt ||
    Number.isNaN(occurredAt.getTime()) ||
    !(
      value.faceSimilarity === null ||
      (typeof value.faceSimilarity === 'number' &&
        Number.isFinite(value.faceSimilarity))
    ) ||
    !(
      value.livenessScore === undefined ||
      value.livenessScore === null ||
      (typeof value.livenessScore === 'number' &&
        Number.isFinite(value.livenessScore) &&
        value.livenessScore >= 0 &&
        value.livenessScore <= 1)
    ) ||
    !(
      value.livenessMethod === undefined ||
      value.livenessMethod === null ||
      LIVENESS_METHODS.includes(value.livenessMethod as LivenessMethod)
    ) ||
    !nullableUuid(value.faceTemplateId) ||
    !(
      value.photoSha256 === null ||
      (typeof value.photoSha256 === 'string' && HEX64.test(value.photoSha256))
    )
  ) {
    throw new Rejected('La checada no tiene el formato esperado.');
  }
  return value as unknown as DeviceEventPayload;
}

/**
 * Recibe checadas firmadas por la tablet. La evidencia bien firmada nunca se
 * rechaza por reglas de negocio: se guarda y se marca para revisión de RH con
 * el motivo. Solo se rechaza lo que no se puede atribuir a la tablet.
 */
@Injectable()
export class DeviceEvents {
  constructor(
    @Inject(TenantDatabase) private readonly db: TenantDatabase,
    @Inject(BiometricBox) private readonly box: BiometricBox,
  ) {}

  async ingest(
    device: DeviceContext,
    events: IncomingEvent[],
  ): Promise<EventResult[]> {
    const results: EventResult[] = [];
    for (const event of events) {
      results.push(await this.one(device, event));
    }
    await this.db.run(device.companyId, (tx) =>
      tx.tablet.update({
        where: { id: device.tabletId },
        data: { lastSynchronizedAt: new Date() },
      }),
    );
    return results;
  }

  private async one(
    device: DeviceContext,
    event: IncomingEvent,
  ): Promise<EventResult> {
    let id: string | null = null;
    try {
      const payloadBytes = base64(event?.payload, 'El contenido', 8000);
      const signature = base64(event?.signature, 'La firma', 400);
      if (
        !verifyDeviceSignature(device.publicKeyPem, payloadBytes, signature)
      ) {
        throw new Rejected('La firma no corresponde a esta tablet.');
      }
      const payload = parsePayload(payloadBytes, device.tabletId);
      id = payload.id;
      const photo =
        event.photo == null
          ? null
          : base64(
              event.photo,
              'La foto',
              Math.ceil((MAX_PHOTO_BYTES * 4) / 3) + 4,
            );
      return await this.db.run(device.companyId, (tx) =>
        this.store(tx, device, payload, payloadBytes, signature, photo),
      );
    } catch (error) {
      if (error instanceof Rejected) {
        return { id, status: 'rejected', message: error.message };
      }
      throw error;
    }
  }

  private async store(
    tx: TenantTransaction,
    device: DeviceContext,
    payload: DeviceEventPayload,
    payloadBytes: Buffer,
    signature: Buffer,
    photo: Buffer | null,
  ): Promise<EventResult> {
    const hash = eventHash(payloadBytes);
    const existing = await tx.attendanceEvent.findUnique({
      where: { id: payload.id },
      select: { eventHash: true },
    });
    if (existing) {
      if (existing.eventHash === hash)
        return { id: payload.id, status: 'duplicate' };
      throw new Rejected('El identificador de la checada ya se usó.');
    }
    const sequence = BigInt(payload.sequence);
    const sameSequence = await tx.attendanceEvent.findUnique({
      where: {
        companyId_tabletId_sequence: {
          companyId: device.companyId,
          tabletId: device.tabletId,
          sequence,
        },
      },
      select: { id: true },
    });
    if (sameSequence) {
      throw new Rejected('La secuencia de la tablet ya se usó.');
    }

    const now = new Date();
    const occurredAt = new Date(payload.occurredAt);
    const reasons: string[] = [];

    const previous =
      payload.sequence === 1
        ? null
        : await tx.attendanceEvent.findUnique({
            where: {
              companyId_tabletId_sequence: {
                companyId: device.companyId,
                tabletId: device.tabletId,
                sequence: sequence - 1n,
              },
            },
            select: { eventHash: true },
          });
    const chainOk =
      payload.sequence === 1
        ? payload.previousEventHash === null
        : previous?.eventHash === payload.previousEventHash;
    if (!chainOk) reasons.push('Falta una checada anterior de esta tablet.');

    if (occurredAt.getTime() > now.getTime() + CLOCK_TOLERANCE_MS) {
      reasons.push('La hora de la tablet está adelantada.');
    }

    const employee = await tx.employee.findUnique({
      where: { id: payload.employeeId },
      select: {
        id: true,
        employmentStatus: true,
        company: { select: { timeZone: true } },
        department: {
          select: {
            name: true,
            entryMinutes: true,
            exitMinutes: true,
            toleranceMinutes: true,
          },
        },
      },
    });
    if (!employee) reasons.push('El empleado no existe en el servidor.');
    else if (employee.employmentStatus !== 'ACTIVE') {
      reasons.push('El empleado está dado de baja.');
    }

    let faceTemplateId: string | null = null;
    if (payload.faceTemplateId) {
      const template = await tx.faceTemplate.findUnique({
        where: { id: payload.faceTemplateId },
        select: {
          id: true,
          employeeId: true,
          revokedAt: true,
          consent: { select: { revokedAt: true } },
        },
      });
      faceTemplateId = template?.id ?? null;
      const validAt = (revokedAt: Date | null) =>
        revokedAt === null || revokedAt > occurredAt;
      if (
        payload.captureMethod === 'FACIAL' &&
        (!template ||
          template.employeeId !== payload.employeeId ||
          !validAt(template.revokedAt) ||
          !validAt(template.consent.revokedAt))
      ) {
        reasons.push('El rostro usado ya no estaba vigente.');
      }
    } else if (payload.captureMethod === 'FACIAL') {
      reasons.push('La checada facial no indica la plantilla usada.');
    }

    // Prueba de vida: una checada facial que no la superó, o que no la trae
    // (app anterior), la revisa RH con su foto.
    if (payload.captureMethod === 'FACIAL') {
      if (payload.livenessMethod === 'failed') {
        reasons.push('Prueba de vida no superada (posible suplantación).');
        if (!payload.photoSha256) {
          reasons.push('Falta la foto de la checada sin prueba de vida.');
        }
      } else if (!payload.livenessMethod) {
        reasons.push(
          'Checada sin prueba de vida (versión anterior de la app).',
        );
      }
    }

    if (photo) {
      const digest = createHash('sha256').update(photo).digest('hex');
      if (photo.length > MAX_PHOTO_BYTES || digest !== payload.photoSha256) {
        reasons.push('La foto no coincide con la checada firmada.');
      }
    } else if (payload.photoSha256) {
      reasons.push('La foto de la checada no llegó.');
    }

    let scheduleNote: string | null = null;
    if (employee) {
      const timeZone = employee.company.timeZone;
      const local = localTime(occurredAt, timeZone);
      scheduleNote = scheduleIssue({
        isEntry: payload.eventType === 'ENTRY',
        minuteOfDay: local.minuteOfDay,
        schedule: employee.department
          ? {
              departmentName: employee.department.name,
              entryMinutes: employee.department.entryMinutes,
              exitMinutes: employee.department.exitMinutes,
              toleranceMinutes: employee.department.toleranceMinutes,
            }
          : null,
      });

      // Reglas del kiosco, ahora entre todas las tablets: alternar entrada y
      // salida, y una de cada una por día.
      const nearby = await tx.attendanceEvent.findMany({
        where: {
          employeeId: employee.id,
          eventType: { in: ['ENTRY', 'EXIT'] },
          deviceOccurredAt: {
            gte: new Date(occurredAt.getTime() - 36 * 60 * 60_000),
            lte: new Date(occurredAt.getTime() + 36 * 60 * 60_000),
          },
        },
        select: { eventType: true, deviceOccurredAt: true },
        orderBy: { deviceOccurredAt: 'asc' },
      });
      const label = payload.eventType === 'ENTRY' ? 'entrada' : 'salida';
      if (
        nearby.some(
          (other) =>
            other.eventType === payload.eventType &&
            localTime(other.deviceOccurredAt, timeZone).day === local.day,
        )
      ) {
        reasons.push(`Ya había una ${label} de este empleado ese día.`);
      }
      const before = nearby
        .filter((other) => other.deviceOccurredAt < occurredAt)
        .at(-1);
      const openEntry =
        before?.eventType === 'ENTRY' &&
        occurredAt.getTime() - before.deviceOccurredAt.getTime() <
          OPEN_ENTRY_LIMIT_MS;
      if (payload.eventType === 'ENTRY' && openEntry) {
        reasons.push('Entrada sin salida de la anterior.');
      }
      if (payload.eventType === 'EXIT' && !openEntry) {
        reasons.push('Salida sin entrada abierta.');
      }
    }

    const requiresReview =
      payload.captureMethod !== 'FACIAL' ||
      reasons.length > 0 ||
      scheduleNote !== null;
    await tx.attendanceEvent.create({
      data: {
        id: payload.id,
        companyId: device.companyId,
        branchId: device.branchId,
        tabletId: device.tabletId,
        deviceKeyId: device.deviceKeyId,
        employeeId: employee?.id ?? null,
        eventType: payload.eventType,
        captureMethod: payload.captureMethod,
        deviceOccurredAt: occurredAt,
        serverReceivedAt: now,
        sequence,
        faceSimilarity: payload.faceSimilarity,
        livenessScore: payload.livenessScore ?? null,
        livenessMethod: payload.livenessMethod ?? null,
        faceTemplateId,
        photoSha256: payload.photoSha256,
        requiresReview,
        reviewReasons: reasons,
        scheduleNote,
        previousEventHash: payload.previousEventHash,
        eventHash: hash,
        signedPayload: new Uint8Array(payloadBytes),
        signature: new Uint8Array(signature),
      },
    });
    if (photo && photo.length <= MAX_PHOTO_BYTES) {
      await tx.attendancePhoto.create({
        data: {
          eventId: payload.id,
          companyId: device.companyId,
          sha256: createHash('sha256').update(photo).digest('hex'),
          encryptedJpeg: this.box.sealPhoto(
            device.companyId,
            payload.id,
            photo,
          ),
        },
      });
    }
    return { id: payload.id, status: 'accepted', requiresReview };
  }
}
