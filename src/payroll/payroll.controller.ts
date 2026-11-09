import {
  BadRequestException,
  Body,
  Controller,
  Get,
  HttpCode,
  Inject,
  Post,
  Put,
  Query,
} from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { loadAttendance } from '../attendance/attendance-data.js';
import { localTime } from '../attendance/schedule.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import { integer, isoDate, readBody, text } from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import type { TenantTransaction } from '../database/tenant-database.js';
import type { PayPeriodKind } from '../generated/prisma/client.js';
import { computeKpis } from '../kpis/kpi-engine.js';
import {
  DEFAULT_POLICY,
  payPeriodRange,
  payrollLine,
} from './payroll-engine.js';
import type {
  PayPeriod,
  PayrollLine,
  PayrollPolicyRules,
} from './payroll-engine.js';

const KIND_TO_DB: Record<PayPeriod, PayPeriodKind> = {
  weekly: 'WEEKLY',
  semimonthly: 'SEMIMONTHLY',
  monthly: 'MONTHLY',
};
const KIND_FROM_DB: Record<PayPeriodKind, PayPeriod> = {
  WEEKLY: 'weekly',
  SEMIMONTHLY: 'semimonthly',
  MONTHLY: 'monthly',
};

interface ClosedSummary {
  policy: PayrollPolicyRules;
  lines: PayrollLine[];
}

function day(value: Date): string {
  return value.toISOString().slice(0, 10);
}

/** Número decimal en un rango; acepta hasta dos decimales. */
function decimal(
  body: Record<string, unknown>,
  key: string,
  label: string,
  min: number,
  max: number,
  exclusiveMin = false,
): number {
  const value = body[key];
  if (
    typeof value !== 'number' ||
    !Number.isFinite(value) ||
    (exclusiveMin ? value <= min : value < min) ||
    value > max ||
    Math.round(value * 100) !== value * 100
  ) {
    throw new BadRequestException(
      `${label} debe ser un número de ${min} a ${max} con hasta dos decimales.`,
    );
  }
  return value;
}

@Controller('payroll')
export class PayrollController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  private async policy(tx: TenantTransaction): Promise<PayrollPolicyRules> {
    const row = await tx.payrollPolicy.findFirst();
    return row
      ? {
          kind: KIND_FROM_DB[row.periodKind],
          weekStart: row.weekStart,
          paidDays: row.paidDays,
          absenceDays: row.absenceDays,
          latesPerAbsence: row.latesPerAbsence,
        }
      : DEFAULT_POLICY;
  }

  private async today(tx: TenantTransaction, companyId: string) {
    const company = await tx.company.findUniqueOrThrow({
      where: { id: companyId },
      select: { timeZone: true },
    });
    return localTime(new Date(), company.timeZone).day;
  }

  /** Último movimiento del periodo exacto [start, end). */
  private latest(tx: TenantTransaction, start: string, end: string) {
    return tx.payrollClosure.findFirst({
      where: {
        periodStart: new Date(`${start}T00:00:00Z`),
        periodEnd: new Date(`${end}T00:00:00Z`),
      },
      orderBy: { occurredAt: 'desc' },
      select: {
        action: true,
        summary: true,
        occurredAt: true,
        reason: true,
        actor: { select: { email: true } },
      },
    });
  }

  /** Calcula el periodo que contiene `anchor` (o lo devuelve congelado). */
  private async compute(
    tx: TenantTransaction,
    companyId: string,
    anchor: string | undefined,
  ) {
    const today = await this.today(tx, companyId);
    const start = anchor
      ? day(isoDate({ anchor }, 'anchor', 'La fecha'))
      : today;
    const rules = await this.policy(tx);
    const period = payPeriodRange(rules, start);
    const ended = period.end <= today;
    const latest = await this.latest(tx, period.start, period.end);
    if (latest?.action === 'CLOSED') {
      const summary = latest.summary as unknown as ClosedSummary;
      return {
        period,
        policy: summary.policy,
        lines: summary.lines,
        pendingReviews: 0,
        ended,
        closure: { closedAt: latest.occurredAt, actor: latest.actor.email },
      };
    }
    const loaded = await loadAttendance(
      tx,
      companyId,
      period.start,
      period.end,
    );
    let pendingReviews = 0;
    const lines = loaded.employees.map((employee) => {
      const { values } = computeKpis(
        employee.input,
        { kind: 'range', ...period },
        loaded.context,
      );
      pendingReviews += values.pendingReview;
      return payrollLine(
        {
          employeeNumber: employee.employeeNumber,
          name: employee.name,
          departmentName: employee.department?.name ?? null,
          hiredOn: employee.hiredOn,
          hasSchedule: employee.input.schedule !== null,
          absences: values.absences,
          lates: values.lates,
          incomplete: values.incompleteShifts,
          employeeWage: employee.dailyWageCents,
          departmentWage: employee.department?.dailyWageCents ?? null,
        },
        rules,
        period,
      );
    });
    return {
      period,
      policy: rules,
      lines,
      pendingReviews,
      ended,
      closure: null,
      reopened:
        latest?.action === 'REOPENED'
          ? {
              at: latest.occurredAt,
              actor: latest.actor.email,
              reason: latest.reason,
            }
          : null,
    };
  }

  @RequirePermissions('payroll.read')
  @Get('policy')
  readPolicy(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, (tx) => this.policy(tx));
  }

  @RequirePermissions('payroll.manage')
  @Put('policy')
  savePolicy(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const kind = body.kind;
    if (kind !== 'weekly' && kind !== 'semimonthly' && kind !== 'monthly') {
      throw new BadRequestException(
        'El periodo debe ser weekly, semimonthly o monthly.',
      );
    }
    const rules: PayrollPolicyRules = {
      kind,
      weekStart: integer(body, 'weekStart', 'El día de inicio', 1, 7),
      paidDays: decimal(body, 'paidDays', 'Los días pagados', 0, 31, true),
      absenceDays: decimal(body, 'absenceDays', 'El descuento por falta', 0, 7),
      latesPerAbsence: integer(
        body,
        'latesPerAbsence',
        'Los retardos por falta',
        0,
        31,
      ),
    };
    const data = {
      periodKind: KIND_TO_DB[rules.kind],
      weekStart: rules.weekStart,
      paidDays: rules.paidDays,
      absenceDays: rules.absenceDays,
      latesPerAbsence: rules.latesPerAbsence,
    };
    return this.db.run(auth.companyId, async (tx) => {
      await tx.payrollPolicy.upsert({
        where: { companyId: auth.companyId },
        create: { companyId: auth.companyId, ...data },
        update: data,
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'payroll.policy_changed',
        entityType: 'payroll_policy',
        entityId: auth.companyId,
        details: { ...rules },
      });
      return rules;
    });
  }

  /** Pre-nómina del periodo que contiene `anchor` (hoy si no se indica). */
  @RequirePermissions('payroll.read')
  @Get()
  read(@CurrentAuth() auth: AuthContext, @Query('anchor') anchor?: string) {
    return this.db.run(auth.companyId, (tx) =>
      this.compute(tx, auth.companyId, anchor),
    );
  }

  /**
   * Congela los montos del periodo. Exige que haya terminado y que no queden
   * checadas por revisar.
   */
  @RequirePermissions('payroll.manage')
  @Post('close')
  @HttpCode(200)
  close(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const anchor = day(isoDate(body, 'anchor', 'La fecha'));
    return this.db.run(auth.companyId, async (tx) => {
      const data = await this.compute(tx, auth.companyId, anchor);
      if (data.closure) {
        throw new BadRequestException('El periodo ya está cerrado.');
      }
      if (!data.ended) {
        throw new BadRequestException(
          'El periodo todavía no termina. Ciérralo después del último día.',
        );
      }
      if (data.pendingReviews > 0) {
        throw new BadRequestException(
          data.pendingReviews === 1
            ? 'Queda 1 checada por revisar en el periodo.'
            : `Quedan ${data.pendingReviews} checadas por revisar en el periodo.`,
        );
      }
      const summary: ClosedSummary = { policy: data.policy, lines: data.lines };
      const closure = await tx.payrollClosure.create({
        data: {
          companyId: auth.companyId,
          periodStart: new Date(`${data.period.start}T00:00:00Z`),
          periodEnd: new Date(`${data.period.end}T00:00:00Z`),
          action: 'CLOSED',
          actorAccountId: auth.accountId,
          summary: summary as never,
        },
        select: { id: true, occurredAt: true },
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'payroll.closed',
        entityType: 'payroll_closure',
        entityId: closure.id,
        details: {
          start: data.period.start,
          end: data.period.end,
          employees: data.lines.length,
          total: data.lines.reduce((t, line) => t + (line.total ?? 0), 0),
        },
      });
      return this.compute(tx, auth.companyId, anchor);
    });
  }

  /** Reabre un periodo cerrado; queda el motivo en la bitácora. */
  @RequirePermissions('payroll.reopen')
  @Post('reopen')
  @HttpCode(200)
  reopen(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const anchor = day(isoDate(body, 'anchor', 'La fecha'));
    const reason = text(body, 'reason', 'El motivo', 500);
    if (reason.length < 10) {
      throw new BadRequestException(
        'Escribe un motivo de 10 a 500 caracteres.',
      );
    }
    return this.db.run(auth.companyId, async (tx) => {
      const period = payPeriodRange(await this.policy(tx), anchor);
      const latest = await this.latest(tx, period.start, period.end);
      if (latest?.action !== 'CLOSED') {
        throw new BadRequestException('El periodo no está cerrado.');
      }
      const closure = await tx.payrollClosure.create({
        data: {
          companyId: auth.companyId,
          periodStart: new Date(`${period.start}T00:00:00Z`),
          periodEnd: new Date(`${period.end}T00:00:00Z`),
          action: 'REOPENED',
          actorAccountId: auth.accountId,
          reason,
        },
        select: { id: true },
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'payroll.reopened',
        entityType: 'payroll_closure',
        entityId: closure.id,
        details: { start: period.start, end: period.end, reason },
      });
      return this.compute(tx, auth.companyId, anchor);
    });
  }
}
