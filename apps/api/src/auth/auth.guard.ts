import {
  ForbiddenException,
  Inject,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import type { CanActivate, ExecutionContext } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Reflector } from '@nestjs/core';
import {
  MFA_STEP_ROUTE,
  PUBLIC_ROUTE,
  REQUIRED_PERMISSIONS,
} from './access.js';
import type { AuthenticatedRequest, PermissionCode } from './access.js';
import { AuthService } from './auth.service.js';
import { readSessionCookie } from './session-token.js';

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

/** Global: toda ruta exige sesión con doble factor salvo que se marque lo contrario. */
@Injectable()
export class AuthGuard implements CanActivate {
  private readonly webOrigin: string;

  constructor(
    @Inject(Reflector) private readonly reflector: Reflector,
    @Inject(AuthService) private readonly auth: AuthService,
    @Inject(ConfigService) config: ConfigService,
  ) {
    this.webOrigin = config.getOrThrow<string>('WEB_ORIGIN');
  }

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    const targets = [context.getHandler(), context.getClass()];

    // La cookie es SameSite=Strict; además se rechazan escrituras desde otro origen.
    const origin = request.headers.origin;
    if (
      !SAFE_METHODS.has(request.method) &&
      origin !== undefined &&
      origin !== this.webOrigin
    ) {
      throw new ForbiddenException('Origen no permitido.');
    }

    if (this.reflector.getAllAndOverride<boolean>(PUBLIC_ROUTE, targets)) {
      return true;
    }

    const auth = await this.auth.resolve(readSessionCookie(request));
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
