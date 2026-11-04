import { HttpErrorResponse } from '@angular/common/http';
import type { HttpInterceptorFn } from '@angular/common/http';
import { inject, Injectable, signal } from '@angular/core';
import { Router } from '@angular/router';
import type { CanActivateFn } from '@angular/router';
import { catchError, throwError } from 'rxjs';
import { Api } from './api';
import type { Me, Permission } from './api';

@Injectable({ providedIn: 'root' })
export class Session {
  private readonly api = inject(Api);
  readonly me = signal<Me | null>(null);

  can(permission: Permission): boolean {
    return this.me()?.permissions.includes(permission) ?? false;
  }

  async load(): Promise<Me | null> {
    try {
      this.me.set(await this.api.get<Me>('auth/me'));
    } catch {
      this.me.set(null);
    }
    return this.me();
  }

  async logout(): Promise<void> {
    try {
      await this.api.post('auth/logout');
    } finally {
      this.me.set(null);
    }
  }
}

export const signedIn: CanActivateFn = async () => {
  const session = inject(Session);
  const router = inject(Router);
  return (session.me() ?? (await session.load())) ? true : router.parseUrl('/entrar');
};

export function allowed(permission: Permission): CanActivateFn {
  return () => inject(Session).can(permission) || inject(Router).parseUrl('/');
}

/** Si la sesión vence o se revoca, vuelve a la pantalla de entrada. */
export const sessionExpiry: HttpInterceptorFn = (request, next) => {
  const session = inject(Session);
  const router = inject(Router);
  return next(request).pipe(
    catchError((error: unknown) => {
      if (
        error instanceof HttpErrorResponse &&
        error.status === 401 &&
        !request.url.startsWith('/api/auth/') &&
        session.me()
      ) {
        session.me.set(null);
        void router.navigateByUrl('/entrar');
      }
      return throwError(() => error);
    }),
  );
};
