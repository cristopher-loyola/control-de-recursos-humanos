import { HttpClient, HttpErrorResponse } from '@angular/common/http';
import { inject, Injectable } from '@angular/core';
import { firstValueFrom } from 'rxjs';

export type Permission =
  | 'self.read'
  | 'company.read'
  | 'branches.read'
  | 'branches.manage'
  | 'accounts.read'
  | 'accounts.manage'
  | 'employees.read'
  | 'employees.manage'
  | 'audit.read';

export interface Me {
  id: string;
  email: string;
  company: { name: string; slug: string };
  employee: { employeeNumber: string; givenNames: string; familyNames: string } | null;
  roles: { code: string; name: string }[];
  permissions: Permission[];
}

export interface Branch {
  id: string;
  code: string;
  name: string;
  timeZone: string | null;
  isActive: boolean;
}

export interface Role {
  id: string;
  code: string;
  name: string;
  description: string | null;
  permissions: Permission[];
}

export interface Account {
  id: string;
  email: string;
  status: 'ACTIVE' | 'DISABLED';
  disabledReason: string | null;
  totpEnabledAt: string | null;
  lastLoginAt: string | null;
  roles: { role: { id: string; code: string; name: string } }[];
}

export interface Employee {
  id: string;
  employeeNumber: string;
  givenNames: string;
  familyNames: string;
  hiredOn: string;
  employmentStatus: 'ACTIVE' | 'TERMINATED';
  branch: { id: string; code: string; name: string };
}

export interface AuditEntry {
  id: string;
  action: string;
  entityType: string;
  entityId: string;
  details: unknown;
  occurredAt: string;
  actorType: 'ACCOUNT' | 'TABLET' | 'SYSTEM';
  actorAccount: { email: string } | null;
}

export type LoginStep = 'MFA_SETUP' | 'MFA_CODE';

/** Cliente de la API. La sesión viaja en una cookie HttpOnly del mismo origen. */
@Injectable({ providedIn: 'root' })
export class Api {
  private readonly http = inject(HttpClient);

  get<T>(path: string): Promise<T> {
    return firstValueFrom(this.http.get<T>(`/api/${path}`));
  }

  post<T>(path: string, body: unknown = {}): Promise<T> {
    return firstValueFrom(this.http.post<T>(`/api/${path}`, body));
  }

  put<T>(path: string, body: unknown): Promise<T> {
    return firstValueFrom(this.http.put<T>(`/api/${path}`, body));
  }
}

export function errorMessage(error: unknown): string {
  if (error instanceof HttpErrorResponse) {
    const message = error.error?.message;
    if (typeof message === 'string') {
      return message;
    }
    if (Array.isArray(message) && typeof message[0] === 'string') {
      return message[0];
    }
    if (error.status === 0) {
      return 'No se pudo conectar con el servidor.';
    }
  }
  return 'Ocurrió un error inesperado. Intenta nuevamente.';
}
