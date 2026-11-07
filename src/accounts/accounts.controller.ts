import {
  BadRequestException,
  Body,
  Controller,
  ForbiddenException,
  Get,
  HttpCode,
  Inject,
  NotFoundException,
  Param,
  Post,
  Put,
} from '@nestjs/common';
import { recordAudit } from '../audit/record-audit.js';
import { CurrentAuth, RequirePermissions } from '../auth/access.js';
import type { AuthContext } from '../auth/access.js';
import { hashPassword, passwordProblem } from '../auth/passwords.js';
import {
  email,
  optionalUuid,
  readBody,
  secret,
  text,
  unique,
  uuid,
  uuidList,
} from '../common/input.js';
import { TenantDatabase } from '../database/tenant-database.js';
import type { TenantTransaction } from '../database/tenant-database.js';

const accountFields = {
  id: true,
  email: true,
  status: true,
  disabledAt: true,
  disabledReason: true,
  totpEnabledAt: true,
  lastLoginAt: true,
  employee: {
    select: {
      id: true,
      employeeNumber: true,
      givenNames: true,
      familyNames: true,
    },
  },
  roles: { select: { role: { select: { id: true, code: true, name: true } } } },
} as const;

@Controller()
export class AccountsController {
  constructor(@Inject(TenantDatabase) private readonly db: TenantDatabase) {}

  @RequirePermissions('accounts.read')
  @Get('roles')
  roles(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, async (tx) => {
      const roles = await tx.role.findMany({
        orderBy: { name: 'asc' },
        include: {
          permissions: { include: { permission: { select: { code: true } } } },
        },
      });
      return roles.map((role) => ({
        id: role.id,
        code: role.code,
        name: role.name,
        description: role.description,
        permissions: role.permissions
          .map(({ permission }) => permission.code)
          .sort(),
      }));
    });
  }

  @RequirePermissions('accounts.read')
  @Get('accounts')
  list(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, (tx) =>
      tx.account.findMany({ select: accountFields, orderBy: { email: 'asc' } }),
    );
  }

  @RequirePermissions('accounts.manage')
  @Post('accounts')
  async create(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const body = readBody(raw);
    const address = email(body, 'email');
    const password = secret(body, 'password', 'La contraseña inicial');
    const problem = passwordProblem(password);
    if (problem) {
      throw new BadRequestException(problem);
    }
    const roleIds = uuidList(body, 'roleIds', 'Rol');
    const employeeId = optionalUuid(body, 'employeeId', 'El empleado');
    const passwordHash = await hashPassword(password);

    return this.db.run(auth.companyId, async (tx) => {
      const roleCodes = await this.roleCodes(tx, roleIds);
      if (
        employeeId &&
        !(await tx.employee.findUnique({ where: { id: employeeId } }))
      ) {
        throw new BadRequestException('El empleado no existe.');
      }
      const { id } = await unique(
        tx.account.create({
          data: {
            companyId: auth.companyId,
            email: address,
            passwordHash,
            employeeId,
          },
        }),
        'Ya existe una cuenta con ese correo o para ese empleado.',
      );
      await tx.accountRole.createMany({
        data: roleIds.map((roleId) => ({
          companyId: auth.companyId,
          accountId: id,
          roleId,
        })),
      });
      const account = await tx.account.findUniqueOrThrow({
        where: { id },
        select: accountFields,
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'account.created',
        entityType: 'account',
        entityId: account.id,
        details: { email: address, roles: roleCodes, employeeId },
      });
      return account;
    });
  }

  @RequirePermissions('accounts.manage')
  @Put('accounts/:id/roles')
  setRoles(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Body() raw: unknown,
  ) {
    const id = this.target(auth, rawId);
    const roleIds = uuidList(readBody(raw), 'roleIds', 'Rol');
    return this.db.run(auth.companyId, async (tx) => {
      const before = await this.existing(tx, id);
      const after = await this.roleCodes(tx, roleIds);
      await tx.accountRole.deleteMany({ where: { accountId: id } });
      await tx.accountRole.createMany({
        data: roleIds.map((roleId) => ({
          companyId: auth.companyId,
          accountId: id,
          roleId,
        })),
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'account.roles_changed',
        entityType: 'account',
        entityId: id,
        details: {
          before: before.roles.map(({ role }) => role.code).sort(),
          after,
        },
      });
      return tx.account.findUniqueOrThrow({
        where: { id },
        select: accountFields,
      });
    });
  }

  @RequirePermissions('accounts.manage')
  @Post('accounts/:id/disable')
  @HttpCode(200)
  disable(
    @CurrentAuth() auth: AuthContext,
    @Param('id') rawId: string,
    @Body() raw: unknown,
  ) {
    const id = this.target(auth, rawId);
    const reason = text(readBody(raw), 'reason', 'El motivo', 500);
    return this.db.run(auth.companyId, async (tx) => {
      await this.existing(tx, id);
      const now = new Date();
      await tx.account.update({
        where: { id },
        data: { status: 'DISABLED', disabledAt: now, disabledReason: reason },
      });
      await tx.session.updateMany({
        where: { accountId: id, revokedAt: null },
        data: { revokedAt: now },
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'account.disabled',
        entityType: 'account',
        entityId: id,
        details: { reason },
      });
      return tx.account.findUniqueOrThrow({
        where: { id },
        select: accountFields,
      });
    });
  }

  @RequirePermissions('accounts.manage')
  @Post('accounts/:id/enable')
  @HttpCode(200)
  enable(@CurrentAuth() auth: AuthContext, @Param('id') rawId: string) {
    const id = this.target(auth, rawId);
    return this.db.run(auth.companyId, async (tx) => {
      await this.existing(tx, id);
      await tx.account.update({
        where: { id },
        data: { status: 'ACTIVE', disabledAt: null, disabledReason: null },
      });
      await recordAudit(tx, {
        companyId: auth.companyId,
        actorAccountId: auth.accountId,
        action: 'account.enabled',
        entityType: 'account',
        entityId: id,
      });
      return tx.account.findUniqueOrThrow({
        where: { id },
        select: accountFields,
      });
    });
  }

  /** Nadie modifica su propia cuenta: evita quedarse sin administrador por error. */
  private target(auth: AuthContext, rawId: string): string {
    const id = uuid(rawId, 'La cuenta');
    if (id === auth.accountId) {
      throw new ForbiddenException(
        'No puedes cambiar tus propios roles ni desactivar tu cuenta.',
      );
    }
    return id;
  }

  private async existing(tx: TenantTransaction, id: string) {
    const account = await tx.account.findUnique({
      where: { id },
      select: accountFields,
    });
    if (!account) {
      throw new NotFoundException('La cuenta no existe.');
    }
    return account;
  }

  private async roleCodes(
    tx: TenantTransaction,
    roleIds: string[],
  ): Promise<string[]> {
    const roles = await tx.role.findMany({
      where: { id: { in: roleIds } },
      select: { code: true },
    });
    if (roles.length !== roleIds.length) {
      throw new BadRequestException('Uno de los roles no existe.');
    }
    return roles.map((role) => role.code).sort();
  }
}
