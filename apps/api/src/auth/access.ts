import { createParamDecorator, SetMetadata } from '@nestjs/common';
import type { ExecutionContext } from '@nestjs/common';
import type { Request } from 'express';

export const PERMISSIONS = [
  'self.read',
  'company.read',
  'branches.read',
  'branches.manage',
  'accounts.read',
  'accounts.manage',
  'employees.read',
  'employees.manage',
  'audit.read',
] as const;

export type PermissionCode = (typeof PERMISSIONS)[number];

export interface AuthContext {
  sessionId: string;
  companyId: string;
  accountId: string;
  stage: 'MFA_PENDING' | 'ACTIVE';
  permissions: ReadonlySet<string>;
}

export type AuthenticatedRequest = Request & { auth?: AuthContext };

export const PUBLIC_ROUTE = 'accesos:public';
export const MFA_STEP_ROUTE = 'accesos:mfa-step';
export const REQUIRED_PERMISSIONS = 'accesos:permissions';

/** Sin sesión: inicio de sesión y estado del servicio. */
export const Public = () => SetMetadata(PUBLIC_ROUTE, true);

/** Solo con contraseña verificada y doble factor pendiente. */
export const MfaStep = () => SetMetadata(MFA_STEP_ROUTE, true);

export const RequirePermissions = (...permissions: PermissionCode[]) =>
  SetMetadata(REQUIRED_PERMISSIONS, permissions);

export const CurrentAuth = createParamDecorator(
  (_: unknown, context: ExecutionContext) => {
    const auth = context.switchToHttp().getRequest<AuthenticatedRequest>().auth;
    if (!auth) {
      throw new Error('La ruta requiere una sesión verificada por AuthGuard.');
    }
    return auth;
  },
);
