import { HttpErrorResponse } from '@angular/common/http';
import { Component, DestroyRef, inject, OnInit, signal } from '@angular/core';
import { takeUntilDestroyed } from '@angular/core/rxjs-interop';
import { HealthService } from '../core/health.service';

type ConnectionState = 'idle' | 'checking' | 'available' | 'database-unavailable' | 'unavailable';

@Component({
  selector: 'app-system-status',
  styles: `
    .connection-status {
      min-height: 96px;
    }
    .status-label {
      margin-bottom: 4px;
      font-weight: 700;
    }
  `,
  template: `
    <section class="card" aria-labelledby="connection-heading">
      <h2 id="connection-heading">Estado de conexión</h2>
      <div class="connection-status" role="status" aria-live="polite" aria-atomic="true">
        @switch (connectionState()) {
          @case ('available') {
            <p class="status-label success">Sistema disponible</p>
            <p>La conexión con el servidor y la base de datos funciona correctamente.</p>
          }
          @case ('database-unavailable') {
            <p class="status-label error">Base de datos no disponible</p>
            <p>El servidor responde, pero no pudo consultar la base de datos. Intenta nuevamente.</p>
          }
          @case ('unavailable') {
            <p class="status-label error">No se pudo verificar la conexión</p>
            <p>El servicio no respondió correctamente. Comprueba que esté iniciado y vuelve a intentar.</p>
          }
          @default {
            <p class="status-label">Comprobando conexión…</p>
            <p>Espera mientras consultamos el estado del sistema.</p>
          }
        }
      </div>
      <button type="button" (click)="checkConnection()" [disabled]="connectionState() === 'checking'">
        {{ connectionState() === 'checking' ? 'Comprobando…' : 'Volver a comprobar' }}
      </button>
    </section>
  `,
})
export class SystemStatus implements OnInit {
  private readonly health = inject(HealthService);
  private readonly destroyRef = inject(DestroyRef);
  protected readonly connectionState = signal<ConnectionState>('idle');

  ngOnInit(): void {
    this.checkConnection();
  }

  protected checkConnection(): void {
    if (this.connectionState() === 'checking') {
      return;
    }

    this.connectionState.set('checking');
    this.health
      .check()
      .pipe(takeUntilDestroyed(this.destroyRef))
      .subscribe({
        next: () => this.connectionState.set('available'),
        error: (error: unknown) => {
          const databaseUnavailable =
            error instanceof HttpErrorResponse &&
            error.status === 503 &&
            error.error?.database === 'unavailable';
          this.connectionState.set(databaseUnavailable ? 'database-unavailable' : 'unavailable');
        },
      });
  }
}
