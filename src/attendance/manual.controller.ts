import {
  BadRequestException,
  Body,
  Controller,
  Get,
  Inject,
  Post,
  Query,
} from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import { optionalUuid, readBody, text, uuid } from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import { isPayrollClosed } from '../payroll/payroll-closures.js';
import { readRange } from '../reports/reports.controller.js';
import { localTime } from './schedule.js';

/** Hasta cuántos días atrás se puede capturar una checada. */
export const MANUAL_MAX_AGE_DAYS = 62;
/** Margen por relojes desfasados al capturar la hora actual. */
const FUTURE_MARGIN_MS = 5 * 60_000;

const entryFields = {
  id: true,
  eventType: true,
  occurredAt: true,
  reason: true,
  createdAt: true,
  employee: {
    select: {
      id: true,
      employeeNumber: true,
      givenNames: true,
      familyNames: true,
    },
  },
  branch: { select: { id: true, name: true } },
  author: { select: { email: true } },
} as const;

/**
 * Checadas que captura RH desde el panel cuando un empleado no pudo checar.
 * No pasan por una tablet: quedan con autor y motivo, y no se editan.
 */
@Controller('attendance/manual')
export class ManualAttendanceController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  @RequirePermissions('attendance.review')
  @Get()
  list(
    @CurrentAuth() auth: AuthContext,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('employeeId') rawEmployee?: string,
  ) {
    const employeeId = optionalUuid(
      { employeeId: rawEmployee },
      'employeeId',
      'El empleado',
    );
    return this.db.run(auth.companyId, async (tx) => {
      const company = await tx.company.findUniqueOrThrow({
        where: { id: auth.companyId },
        select: { timeZone: true },
      });
      const period = readRange(
        from,
        to,
        localTime(new Date(), company.timeZone).day,
      );
      // Un día de margen a cada lado por la zona horaria; se filtra en local.
      const rows = await tx.manualAttendanceEntry.findMany({
        where: {
          ...(employeeId ? { employeeId } : {}),
          occurredAt: {
            gte: new Date(Date.parse(`${period.start}T00:00:00Z`) - 86_400_000),
            lt: new Date(Date.parse(`${period.end}T00:00:00Z`) + 86_400_000),
          },
        },
        select: entryFields,
        orderBy: { occurredAt: 'desc' },
      });
      return rows.filter((row) => {
        const day = localTime(row.occurredAt, company.timeZone).day;
        return day >= period.start && day < period.end;
      });
    });
  }

  @RequirePermissions('attendance.review')
  @Post()
  create(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const employeeId = uuid(body.employeeId, 'El empleado');
    const eventType = body.type;
    if (eventType !== 'ENTRY' && eventType !== 'EXIT') {
      throw new BadRequestException('El tipo debe ser ENTRY o EXIT.');
    }
    const rawAt = body.occurredAt;
    const occurredAt =
      typeof rawAt === 'string' &&
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})$/.test(
        rawAt,
      )
        ? new Date(rawAt)
        : null;
    if (!occurredAt || Number.isNaN(occurredAt.getTime())) {
      throw new BadRequestException(
        'La fecha y hora deben ir en formato ISO 8601 con zona horaria.',
      );
    }
    const now = Date.now();
    if (occurredAt.getTime() > now + FUTURE_MARGIN_MS) {
      throw new BadRequestException('No se puede capturar una checada futura.');
    }
    if (occurredAt.getTime() < now - MANUAL_MAX_AGE_DAYS * 86_400_000) {
      throw new BadRequestException(
        `Solo se pueden capturar checadas de los últimos ${MANUAL_MAX_AGE_DAYS} días.`,
      );
    }
    const reason = text(body, 'reason', 'El motivo', 500);
    if (reason.length < 10) {
      throw new BadRequestException(
        'Escribe un motivo de 10 a 500 caracteres.',
      );
    }
    return this.db.run(auth.companyId, async (tx) => {
      const employee = await tx.employee.findUnique({
        where: { id: employeeId },
        select: { id: true, branchId: true, employmentStatus: true },
      });
      if (!employee || employee.employmentStatus !== 'ACTIVE') {
        throw new BadRequestException(
          'El empleado no existe o está dado de baja.',
        );
      }
      const company = await tx.company.findUniqueOrThrow({
        where: { id: auth.companyId },
        select: { timeZone: true },
      });
      const day = localTime(occurredAt, company.timeZone).day;
      if (await isPayrollClosed(tx, day)) {
        throw new BadRequestException(
          'Ese día pertenece a un periodo de pre-nómina cerrado.',
        );
      }
      const entry = await tx.manualAttendanceEntry.create({
        data: {
          companyId: auth.companyId,
          branchId: employee.branchId,
          employeeId,
          eventType,
          occurredAt,
          reason,
          authorAccountId: auth.accountId,
        },
        select: entryFields,
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'attendance.manual_recorded',
        entityType: 'manual_attendance_entry',
        entityId: entry.id,
        details: { employeeId, type: eventType, occurredAt, reason },
      });
      return entry;
    });
  }
}
