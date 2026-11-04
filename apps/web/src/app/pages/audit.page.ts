import { DatePipe, JsonPipe } from '@angular/common';
import { Component, inject, OnInit, signal } from '@angular/core';
import { Api, errorMessage } from '../core/api';
import type { AuditEntry } from '../core/api';

const ACTIONS: Record<string, string> = {
  'company.provisioned': 'Empresa dada de alta',
  'branch.created': 'Sucursal creada',
  'account.created': 'Cuenta creada',
  'account.roles_changed': 'Roles modificados',
  'account.disabled': 'Cuenta desactivada',
  'account.enabled': 'Cuenta activada',
  'employee.created': 'Empleado creado',
  'auth.login': 'Inicio de sesión',
  'auth.login_failed': 'Contraseña incorrecta',
  'auth.locked': 'Cuenta bloqueada por intentos',
  'auth.mfa_enabled': 'Verificación en dos pasos configurada',
  'auth.mfa_failed': 'Código de verificación incorrecto',
};

@Component({
  selector: 'app-audit-page',
  imports: [DatePipe, JsonPipe],
  template: `
    <h1>Bitácora</h1>
    <p class="muted">Últimos 200 movimientos. Solo lectura: nadie puede editar ni borrar registros.</p>
    @if (error()) {
      <p class="error" role="alert">{{ error() }}</p>
    }
    <section class="card">
      <div class="table-wrap">
        <table>
          <thead>
            <tr><th>Fecha</th><th>Acción</th><th>Responsable</th><th>Detalle</th></tr>
          </thead>
          <tbody>
            @for (entry of entries(); track entry.id) {
              <tr>
                <td>{{ entry.occurredAt | date: 'dd/MM/yyyy HH:mm:ss' }}</td>
                <td>{{ label(entry.action) }}</td>
                <td>{{ entry.actorAccount?.email ?? (entry.actorType === 'SYSTEM' ? 'Sistema' : 'Tablet') }}</td>
                <td>
                  @if (entry.details) {
                    <code>{{ entry.details | json }}</code>
                  }
                </td>
              </tr>
            }
          </tbody>
        </table>
      </div>
    </section>
  `,
})
export class AuditPage implements OnInit {
  private readonly api = inject(Api);
  protected readonly entries = signal<AuditEntry[]>([]);
  protected readonly error = signal('');

  async ngOnInit(): Promise<void> {
    try {
      this.entries.set(await this.api.get<AuditEntry[]>('audit'));
    } catch (error) {
      this.error.set(errorMessage(error));
    }
  }

  protected label(action: string): string {
    return ACTIONS[action] ?? action;
  }
}
