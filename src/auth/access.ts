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
  'tablets.read',
  'tablets.manage',
  'departments.read',
  'departments.manage',
  'biometrics.manage',
  'attendance.review',
  'holidays.manage',
  'kpis.read',
  'kpis.manage',
] as const;

export type PermissionCode = (typeof PERMISSIONS)[number];

export interface AuthContext {
  sessionId: string;
  companyId: string;
  accountId: string;
  stage: 'MFA_PENDING' | 'ACTIVE';
  permissions: ReadonlySet<string>;
}

/** Tablet vinculada, autenticada con su token de dispositivo. */
export interface DeviceContext {
  companyId: string;
  tabletId: string;
  branchId: string;
  deviceKeyId: string;
  publicKeyPem: string;
}

export type AuthenticatedRequest = Request & {
  auth?: AuthContext;
  device?: DeviceContext;
};

export const PUBLIC_ROUTE = 'accesos:public';
export const MFA_STEP_ROUTE = 'accesos:mfa-step';
export const DEVICE_ROUTE = 'accesos:device';
export const REQUIRED_PERMISSIONS = 'accesos:permissions';

/** Solo para tablets: exige el token del dispositivo en lugar de una sesión. */
export const DeviceRoute = () => SetMetadata(DEVICE_ROUTE, true);

export const CurrentDevice = createParamDecorator(
  (_: unknown, context: ExecutionContext) => {
    const device = context
      .switchToHttp()
      .getRequest<AuthenticatedRequest>().device;
    if (!device) {
      throw new Error('La ruta requiere una tablet verificada por AuthGuard.');
    }
    return device;
  },
);

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
