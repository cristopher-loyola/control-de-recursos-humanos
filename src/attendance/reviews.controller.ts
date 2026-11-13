import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  Get,
  HttpCode,
  Inject,
  NotFoundException,
  Param,
  Post,
  Query,
} from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import { BiometricBox } from '../biometrics/biometric-box.js';
import { isoDate, readBody, text, uuid } from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import { reviewStatus } from './review-status.js';
import { localTime } from './schedule.js';

@Controller('attendance')
export class ReviewsController {
  constructor(
    @Inject(TenantDatabase) private readonly db: TenantDatabase,
    @Inject(BiometricBox) private readonly box: BiometricBox,
  ) {}

  /** Checadas de un día (en la zona de la empresa) con su estado de revisión. */
  @RequirePermissions('attendance.review')
  @Get()
  async day(@CurrentAuth() auth: AuthContext, @Query('day') rawDay: string) {
    const day = isoDate({ day: rawDay }, 'day', 'El día');
    const key = day.toISOString().slice(0, 10);
    return this.db.run(auth.companyId, async (tx) => {
      const company = await tx.company.findUniqueOrThrow({
        where: { id: auth.companyId },
        select: { timeZone: true },
      });
      const events = await tx.attendanceEvent.findMany({
        where: {
          eventType: { in: ['ENTRY', 'EXIT'] },
          // Margen de un día por la zona horaria; se filtra por día local abajo.
          deviceOccurredAt: {
            gte: new Date(day.getTime() - 86_400_000),
            lt: new Date(day.getTime() + 2 * 86_400_000),
          },
        },
        select: {
          id: true,
          eventType: true,
          captureMethod: true,
          livenessScore: true,
          livenessMethod: true,
          deviceOccurredAt: true,
          requiresReview: true,
          reviewReasons: true,
          scheduleNote: true,
          photoSha256: true,
          tablet: { select: { name: true } },
          employee: {
            select: {
              id: true,
              employeeNumber: true,
              givenNames: true,
              familyNames: true,
            },
          },
          review: {
            select: {
              decision: true,
              reason: true,
              reviewedAt: true,
              reviewer: { select: { email: true } },
            },
          },
        },
        orderBy: { deviceOccurredAt: 'asc' },
      });
      return events
        .filter(
          (event) =>
            localTime(event.deviceOccurredAt, company.timeZone).day === key,
        )
        .map(({ review, photoSha256, ...event }) => ({
          ...event,
          status: reviewStatus(event.requiresReview, review?.decision),
          hasPhoto: photoSha256 !== null,
          review: review && {
            decision: review.decision,
            reason: review.reason,
            reviewedAt: review.reviewedAt,
            reviewer: review.reviewer.email,
          },
        }));
    });
  }

  /** Aprueba o rechaza una checada pendiente. No se puede revisar dos veces. */
  @RequirePermissions('attendance.review')
  @Post(':id/review')
  @HttpCode(200)
  review(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Body() raw: unknown,
  ) {
    const id = uuid(rawId, 'La checada');
    const body = readBody(raw);
    if (body.decision !== 'approved' && body.decision !== 'rejected') {
      throw new BadRequestException('Indica si se aprueba o se rechaza.');
    }
    const decision = body.decision === 'approved' ? 'APPROVED' : 'REJECTED';
    const reason = text(body, 'reason', 'El motivo', 500);
    if (reason.length < 10) {
      throw new BadRequestException(
        'Explica el motivo con al menos 10 caracteres.',
      );
    }
    return this.db.run(auth.companyId, async (tx) => {
      const event = await tx.attendanceEvent.findUnique({
        where: { id },
        select: { id: true, requiresReview: true, review: true },
      });
      if (!event) throw new NotFoundException('La checada no existe.');
      if (event.review || !event.requiresReview) {
        throw new ConflictException('Esta checada ya fue revisada.');
      }
      const review = await tx.attendanceReview.create({
        data: {
          companyId: auth.companyId,
          eventId: id,
          decision,
          reviewerAccountId: auth.accountId,
          reason,
        },
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action:
          decision === 'APPROVED'
            ? 'attendance.approved'
            : 'attendance.rejected',
        entityType: 'attendance_event',
        entityId: id,
        details: { reason },
      });
      return {
        status: reviewStatus(true, decision),
        reviewedAt: review.reviewedAt,
      };
    });
  }

  /** Foto de la checada con PIN, para que RH confirme quién checó. */
  @RequirePermissions('attendance.review')
  @Get(':id/photo')
  photo(@CurrentAuth() auth: AuthContext, @Param('id') rawId: string) {
    const id = uuid(rawId, 'La checada');
    return this.db.run(auth.companyId, async (tx) => {
      const photo = await tx.attendancePhoto.findUnique({
        where: { eventId: id },
      });
      if (!photo) throw new NotFoundException('La checada no tiene foto.');
      return {
        jpeg: this.box
          .openPhoto(auth.companyId, id, photo.encryptedJpeg)
          .toString('base64'),
      };
    });
  }
}
