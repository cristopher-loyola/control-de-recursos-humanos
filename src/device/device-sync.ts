import { createHash } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import type { DeviceContext } from '../auth/access.js';
import { reviewStatus } from '../attendance/review-status.js';
import { BiometricBox } from '../biometrics/biometric-box.js';
import { TenantDatabase } from '../database/tenant-database.js';

/** Checadas recientes que la tablet necesita para las reglas del día. */
const RECENT_EVENTS_MS = 36 * 60 * 60_000;

/**
 * Todo lo que la tablet necesita para checar sin red: empleados activos de su
 * sucursal con el horario de su departamento, plantilla facial vigente, hash del
 * PIN y las checadas recientes hechas en cualquier tablet.
 */
@Injectable()
export class DeviceSync {
  constructor(
    @Inject(TenantDatabase) private readonly db: TenantDatabase,
    @Inject(BiometricBox) private readonly box: BiometricBox,
  ) {}

  async snapshot(device: DeviceContext) {
    const since = new Date(Date.now() - RECENT_EVENTS_MS);
    return this.db.run(device.companyId, async (tx) => {
      const tablet = await tx.tablet.findUniqueOrThrow({
        where: { id: device.tabletId },
        select: {
          id: true,
          code: true,
          name: true,
          company: {
            select: {
              name: true,
              slug: true,
              timeZone: true,
              logoUpdatedAt: true,
            },
          },
          branch: { select: { id: true, code: true, name: true } },
        },
      });
      const departments = await tx.department.findMany({
        where: { isActive: true },
        select: {
          id: true,
          name: true,
          entryMinutes: true,
          exitMinutes: true,
          toleranceMinutes: true,
          workDays: true,
          dailyWageCents: true,
        },
        orderBy: { name: 'asc' },
      });
      const employees = await tx.employee.findMany({
        where: { branchId: device.branchId, employmentStatus: 'ACTIVE' },
        select: {
          id: true,
          employeeNumber: true,
          givenNames: true,
          familyNames: true,
          departmentId: true,
          dailyWageCents: true,
          biometricConsents: {
            where: { revokedAt: null },
            orderBy: { grantedAt: 'desc' },
            take: 1,
            select: {
              id: true,
              signedDocumentObjectKey: true,
              grantedAt: true,
            },
          },
          faceTemplates: {
            where: { revokedAt: null },
            take: 1,
            select: {
              id: true,
              modelId: true,
              consentId: true,
              encryptedSamples: true,
            },
          },
          pin: { select: { salt: true, pinHash: true, iterations: true } },
        },
        orderBy: { employeeNumber: 'asc' },
      });
      const recentEvents = await tx.attendanceEvent.findMany({
        where: {
          employeeId: { in: employees.map((employee) => employee.id) },
          eventType: { in: ['ENTRY', 'EXIT'] },
          deviceOccurredAt: { gte: since },
        },
        select: {
          id: true,
          employeeId: true,
          eventType: true,
          captureMethod: true,
          deviceOccurredAt: true,
          requiresReview: true,
          review: { select: { decision: true, reason: true } },
        },
        orderBy: { deviceOccurredAt: 'asc' },
      });
      // Festivos del año en curso y el siguiente: la tablet los usa en su tablero.
      const year = new Date().getUTCFullYear();
      const holidays = await tx.holiday.findMany({
        where: {
          day: {
            gte: new Date(`${year}-01-01T00:00:00Z`),
            lte: new Date(`${year + 1}-12-31T00:00:00Z`),
          },
        },
        select: { id: true, day: true, name: true, departmentId: true },
        orderBy: { day: 'asc' },
      });
      const last = await tx.attendanceEvent.findFirst({
        where: { tabletId: device.tabletId },
        orderBy: { sequence: 'desc' },
        select: { sequence: true, eventHash: true },
      });

      return {
        company: tablet.company,
        tablet: { id: tablet.id, code: tablet.code, name: tablet.name },
        branch: tablet.branch,
        departments,
        employees: employees.map((employee) => {
          const consent = employee.biometricConsents[0] ?? null;
          const face = employee.faceTemplates[0];
          return {
            id: employee.id,
            employeeNumber: employee.employeeNumber,
            givenNames: employee.givenNames,
            familyNames: employee.familyNames,
            departmentId: employee.departmentId,
            dailyWageCents: employee.dailyWageCents,
            consent: consent && {
              id: consent.id,
              documentReference: consent.signedDocumentObjectKey,
              grantedAt: consent.grantedAt,
            },
            // Solo con consentimiento vigente: revocarlo retira el rostro de la tablet.
            face:
              face && consent && face.consentId === consent.id
                ? {
                    id: face.id,
                    modelId: face.modelId,
                    samples: this.box.openFace(
                      device.companyId,
                      employee.id,
                      face.id,
                      face.encryptedSamples,
                    ),
                  }
                : null,
            pin: employee.pin && {
              salt: Buffer.from(employee.pin.salt).toString('base64'),
              hash: Buffer.from(employee.pin.pinHash).toString('base64'),
              iterations: employee.pin.iterations,
            },
          };
        }),
        recentEvents: recentEvents.map((event) => ({
          id: event.id,
          employeeId: event.employeeId,
          eventType: event.eventType,
          captureMethod: event.captureMethod,
          occurredAt: event.deviceOccurredAt,
          status: reviewStatus(event.requiresReview, event.review?.decision),
          reviewReason: event.review?.reason ?? null,
        })),
        holidays: holidays.map((holiday) => ({
          id: holiday.id,
          day: holiday.day.toISOString().slice(0, 10),
          name: holiday.name,
          departmentId: holiday.departmentId,
        })),
        lastSequence: last ? Number(last.sequence) : 0,
        lastEventHash: last?.eventHash ?? null,
      };
    });
  }

  /** ETag débil sobre el contenido: la tablet recibe 304 si nada cambió. */
  static etag(body: unknown): string {
    return `W/"${createHash('sha256').update(JSON.stringify(body)).digest('base64url')}"`;
  }
}
