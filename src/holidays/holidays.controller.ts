import {
  BadRequestException,
  Body,
  Controller,
  Delete,
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
import {
  integer,
  isoDate,
  optionalUuid,
  readBody,
  text,
  unique,
  uuid,
} from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import { officialHolidays } from './official.js';

const holidayFields = {
  id: true,
  day: true,
  name: true,
  department: { select: { id: true, name: true } },
} as const;

const DUPLICATE = 'Ya hay un día festivo ese día para el mismo alcance.';

@Controller('holidays')
export class HolidaysController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  @RequirePermissions('departments.read')
  @Get()
  list(
    @CurrentAuth() auth: AuthContext,
    @Query('from') from?: string,
    @Query('to') to?: string,
  ) {
    const range = {
      ...(from ? { gte: isoDate({ from }, 'from', 'La fecha inicial') } : {}),
      ...(to ? { lte: isoDate({ to }, 'to', 'La fecha final') } : {}),
    };
    return this.db.run(auth.companyId, (tx) =>
      tx.holiday.findMany({
        where: from || to ? { day: range } : {},
        select: holidayFields,
        orderBy: { day: 'asc' },
      }),
    );
  }

  @RequirePermissions('holidays.manage')
  @Post()
  create(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const name = text(body, 'name', 'El nombre', 80);
    if (name.length < 2) {
      throw new BadRequestException(
        'El nombre debe tener al menos 2 caracteres.',
      );
    }
    const day = isoDate(body, 'day', 'El día');
    const departmentId = optionalUuid(body, 'departmentId', 'El departamento');
    return this.db.run(auth.companyId, async (tx) => {
      if (
        departmentId &&
        !(await tx.department.findUnique({ where: { id: departmentId } }))
      ) {
        throw new BadRequestException('El departamento no existe.');
      }
      const holiday = await unique(
        tx.holiday.create({
          data: { companyId: auth.companyId, day, name, departmentId },
          select: holidayFields,
        }),
        DUPLICATE,
      );
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'holiday.created',
        entityType: 'holiday',
        entityId: holiday.id,
        details: { day: day.toISOString().slice(0, 10), name, departmentId },
      });
      return holiday;
    });
  }

  /** Agrega los descansos de la LFT que falten en el año; devuelve cuántos. */
  @RequirePermissions('holidays.manage')
  @Post('official')
  @HttpCode(200)
  official(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const year = integer(readBody(raw), 'year', 'El año', 2000, 2100);
    return this.db.run(auth.companyId, async (tx) => {
      const existing = new Set(
        (
          await tx.holiday.findMany({
            where: {
              departmentId: null,
              day: {
                gte: new Date(`${year}-01-01T00:00:00Z`),
                lte: new Date(`${year}-12-31T00:00:00Z`),
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
            companyId: auth.companyId,
            day: new Date(`${holiday.day}T00:00:00Z`),
            name: holiday.name,
          })),
        });
        await recordAudit(tx, {
          companyId: auth.companyId,
          actorAccountId: auth.accountId,
          action: 'holiday.official_added',
          entityType: 'holiday',
          entityId: String(year),
          details: { added: missing.length },
        });
      }
      return { added: missing.length };
    });
  }

  @RequirePermissions('holidays.manage')
  @Delete(':id')
  @HttpCode(204)
  async remove(@CurrentAuth() auth: AuthContext, @Param('id') rawId: string) {
    const id = uuid(rawId, 'El día festivo');
    await this.db.run(auth.companyId, async (tx) => {
      const holiday = await tx.holiday.findUnique({ where: { id } });
      if (!holiday) throw new NotFoundException('El día festivo no existe.');
      await tx.holiday.delete({ where: { id } });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'holiday.removed',
        entityType: 'holiday',
        entityId: id,
        details: {
          day: holiday.day.toISOString().slice(0, 10),
          name: holiday.name,
        },
      });
    });
  }
}
