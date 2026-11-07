import { randomUUID } from 'node:crypto';
import type { PermissionCode } from '../auth/access.js';
import { hashPassword, passwordProblem } from '../auth/passwords.js';
import type { PrismaClient } from '../generated/prisma/client.js';

/** Roles iniciales. El modelo admite agregar Supervisor en fase 4 sin migrar datos. */
export const SYSTEM_ROLES: Record<
  'ADMIN' | 'RH' | 'EMPLOYEE',
  { name: string; description: string; permissions: PermissionCode[] }
> = {
  ADMIN: {
    name: 'Administrador',
    description: 'Configura la empresa, sucursales, cuentas y roles.',
    permissions: [
      'self.read',
      'company.read',
      'branches.read',
      'branches.manage',
      'accounts.read',
      'accounts.manage',
      'audit.read',
      'tablets.read',
      'tablets.manage',
      'departments.read',
      'attendance.review',
      'holidays.manage',
      'kpis.read',
      'kpis.manage',
    ],
  },
  RH: {
    name: 'Recursos Humanos',
    description: 'Administra empleados e incidencias.',
    permissions: [
      'self.read',
      'company.read',
      'branches.read',
      'employees.read',
      'employees.manage',
      'tablets.read',
      'departments.read',
      'departments.manage',
      'biometrics.manage',
      'attendance.review',
      'holidays.manage',
      'kpis.read',
      'kpis.manage',
    ],
  },
  EMPLOYEE: {
    name: 'Empleado',
    description: 'Consulta su propia información.',
    permissions: ['self.read'],
  },
};

export interface CompanyInput {
  name: string;
  slug: string;
  adminEmail: string;
  adminPassword: string;
}

/**
 * Lo ejecuta el proveedor con el usuario dueño de la base. Fija app.company_id
 * para que funcione aunque ese usuario no sea superusuario y RLS esté forzado.
 */
export async function provisionCompany(
  owner: PrismaClient,
  input: CompanyInput,
) {
  if (!/^[a-z0-9][a-z0-9-]{1,78}[a-z0-9]$/.test(input.slug)) {
    throw new Error(
      'El código de empresa solo admite minúsculas, números y guiones (3 a 80).',
    );
  }
  const problem = passwordProblem(input.adminPassword);
  if (problem) {
    throw new Error(problem);
  }
  const passwordHash = await hashPassword(input.adminPassword);
  const companyId = randomUUID();
  const adminEmail = input.adminEmail.trim().toLowerCase();

  return owner.$transaction(async (tx) => {
    await tx.$executeRaw`SELECT set_config('app.company_id', ${companyId}, true)`;
    await tx.company.create({
      data: { id: companyId, name: input.name.trim(), slug: input.slug },
    });

    const catalog = await tx.permission.findMany();
    const permissionId = new Map(
      catalog.map((permission) => [permission.code, permission.id]),
    );
    const roleIds: Record<string, string> = {};
    for (const [code, role] of Object.entries(SYSTEM_ROLES)) {
      const created = await tx.role.create({
        data: {
          companyId,
          code,
          name: role.name,
          description: role.description,
          isSystem: true,
        },
      });
      await tx.rolePermission.createMany({
        data: role.permissions.map((permission) => {
          const id = permissionId.get(permission);
          if (!id) {
            throw new Error(`Falta el permiso ${permission} en el catálogo.`);
          }
          return { companyId, roleId: created.id, permissionId: id };
        }),
      });
      roleIds[code] = created.id;
    }

    const admin = await tx.account.create({
      data: {
        companyId,
        email: adminEmail,
        passwordHash,
      },
    });
    await tx.accountRole.create({
      data: { companyId, accountId: admin.id, roleId: roleIds.ADMIN },
    });
    await tx.auditEntry.create({
      data: {
        companyId,
        actorType: 'SYSTEM',
        action: 'company.provisioned',
        entityType: 'company',
        entityId: companyId,
        details: { slug: input.slug, adminAccountId: admin.id },
      },
    });
    return { companyId, adminAccountId: admin.id, roleIds };
  });
}
