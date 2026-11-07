import {
  ForbiddenException,
  Inject,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import type { CanActivate, ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import {
  DEVICE_ROUTE,
  MFA_STEP_ROUTE,
  PUBLIC_ROUTE,
  REQUIRED_PERMISSIONS,
} from './access.js';
import type { AuthenticatedRequest, PermissionCode } from './access.js';
import { AuthService } from './auth.service.js';
import { DeviceAuth } from './device-auth.js';
import { readBearer } from './session-token.js';

/**
 * Global: toda ruta exige un token Bearer salvo que se marque lo contrario.
 * Las rutas de tablet aceptan el token del dispositivo; las demás, la sesión
 * de RH o del administrador con doble factor.
 */
@Injectable()
export class AuthGuard implements CanActivate {
  constructor(
    @Inject(Reflector) private readonly reflector: Reflector,
    @Inject(AuthService) private readonly auth: AuthService,
    @Inject(DeviceAuth) private readonly devices: DeviceAuth,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    const targets = [context.getHandler(), context.getClass()];

    if (this.reflector.getAllAndOverride<boolean>(PUBLIC_ROUTE, targets)) {
      return true;
    }

    if (this.reflector.getAllAndOverride<boolean>(DEVICE_ROUTE, targets)) {
      const device = await this.devices.resolve(readBearer(request));
      if (!device) {
        throw new UnauthorizedException(
          'La tablet no está vinculada o fue revocada.',
        );
      }
      request.device = device;
      return true;
    }

    const auth = await this.auth.resolve(readBearer(request));
    if (!auth) {
      throw new UnauthorizedException('Inicia sesión para continuar.');
    }

    const mfaStep =
      this.reflector.getAllAndOverride<boolean>(MFA_STEP_ROUTE, targets) ??
      false;
    if (mfaStep !== (auth.stage === 'MFA_PENDING')) {
      throw new UnauthorizedException(
        mfaStep
          ? 'La sesión ya está verificada.'
          : 'Completa la verificación en dos pasos.',
      );
    }

    const required =
      this.reflector.getAllAndOverride<PermissionCode[]>(
        REQUIRED_PERMISSIONS,
        targets,
      ) ?? [];
    if (!required.every((permission) => auth.permissions.has(permission))) {
      throw new ForbiddenException('No tienes permiso para esta acción.');
    }

    request.auth = auth;
    return true;
  }
}
