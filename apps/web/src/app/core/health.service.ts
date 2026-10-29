import { HttpClient } from '@angular/common/http';
import { inject, Injectable } from '@angular/core';
import { map, Observable, timeout } from 'rxjs';

interface HealthResponse {
  status: 'ok';
  database: 'up';
}

@Injectable({ providedIn: 'root' })
export class HealthService {
  private readonly http = inject(HttpClient);

  check(): Observable<HealthResponse> {
    return this.http.get<unknown>('/health').pipe(
      timeout({ first: 12000 }),
      map((response): HealthResponse => {
        if (
          typeof response !== 'object' ||
          response === null ||
          !('status' in response) ||
          response.status !== 'ok' ||
          !('database' in response) ||
          response.database !== 'up'
        ) {
          throw new Error('La respuesta de disponibilidad no es válida.');
        }
        return { status: 'ok', database: 'up' };
      }),
    );
  }
}
