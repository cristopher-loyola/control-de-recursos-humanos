import { DatePipe } from '@angular/common';
import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, errorMessage } from '../core/api';
import type { Account, Role } from '../core/api';
import { Session } from '../core/session';

@Component({
  selector: 'app-accounts-page',
  imports: [FormsModule, DatePipe],
  template: `
    <h1>Cuentas y roles</h1>

    @if (error()) {
      <p class="error" role="alert">{{ error() }}</p>
    }

    @if (session.can('accounts.manage')) {
      <section class="card">
        <h2>Nueva cuenta</h2>
        <form class="stack" (ngSubmit)="create()">
          <label>Correo <input name="email" type="email" [(ngModel)]="email" required /></label>
          <label>
            Contraseña inicial (mínimo 12 caracteres)
            <input name="password" type="password" [(ngModel)]="password" autocomplete="new-password" required />
          </label>
          <fieldset class="checks">
            <legend class="muted">Roles</legend>
            @for (role of roles(); track role.id) {
              <label>
                <input type="checkbox" [checked]="newRoles.has(role.id)" (change)="toggle(newRoles, role.id)" />
                {{ role.name }}
              </label>
            }
          </fieldset>
          <p class="muted">Al entrar por primera vez se pedirá configurar la verificación en dos pasos.</p>
          <button type="submit" [disabled]="busy()">Crear cuenta</button>
        </form>
      </section>
    }

    <section class="card">
      <div class="table-wrap">
        <table>
          <thead>
            <tr><th>Correo</th><th>Roles</th><th>Dos pasos</th><th>Último acceso</th><th>Estado</th><th></th></tr>
          </thead>
          <tbody>
            @for (account of accounts(); track account.id) {
              <tr>
                <td>{{ account.email }}</td>
                <td>
                  @if (editing() === account.id) {
                    <div class="checks">
                      @for (role of roles(); track role.id) {
                        <label>
                          <input
                            type="checkbox"
                            [checked]="editRoles.has(role.id)"
                            (change)="toggle(editRoles, role.id)"
                          />
                          {{ role.name }}
                        </label>
                      }
                    </div>
                  } @else {
                    @for (entry of account.roles; track entry.role.id) {
                      <span class="tag">{{ entry.role.name }}</span>
                    }
                  }
                </td>
                <td>{{ account.totpEnabledAt ? 'Configurada' : 'Pendiente' }}</td>
                <td>{{ account.lastLoginAt ? (account.lastLoginAt | date: 'dd/MM/yyyy HH:mm') : '—' }}</td>
                <td>
                  {{ account.status === 'ACTIVE' ? 'Activa' : 'Desactivada' }}
                  @if (account.disabledReason) {
                    <div class="muted">{{ account.disabledReason }}</div>
                  }
                </td>
                <td>
                  @if (session.can('accounts.manage') && account.id !== session.me()?.id) {
                    <div class="actions">
                      @if (editing() === account.id) {
                        <button type="button" (click)="saveRoles(account)" [disabled]="busy()">Guardar</button>
                        <button type="button" class="secondary" (click)="editing.set(null)">Cancelar</button>
                      } @else {
                        <button type="button" class="secondary" (click)="edit(account)">Roles</button>
                        @if (account.status === 'ACTIVE') {
                          <button type="button" class="danger" (click)="disable(account)" [disabled]="busy()">
                            Desactivar
                          </button>
                        } @else {
                          <button type="button" class="secondary" (click)="enable(account)" [disabled]="busy()">
                            Activar
                          </button>
                        }
                      }
                    </div>
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
export class AccountsPage implements OnInit {
  private readonly api = inject(Api);
  protected readonly session = inject(Session);
  protected readonly accounts = signal<Account[]>([]);
  protected readonly roles = signal<Role[]>([]);
  protected readonly busy = signal(false);
  protected readonly error = signal('');
  protected readonly editing = signal<string | null>(null);

  protected email = '';
  protected password = '';
  protected newRoles = new Set<string>();
  protected editRoles = new Set<string>();

  async ngOnInit(): Promise<void> {
    await this.run(async () => {
      this.roles.set(await this.api.get<Role[]>('roles'));
      await this.reload();
    });
  }

  protected toggle(set: Set<string>, id: string): void {
    if (!set.delete(id)) {
      set.add(id);
    }
  }

  protected async create(): Promise<void> {
    await this.run(async () => {
      await this.api.post('accounts', {
        email: this.email,
        password: this.password,
        roleIds: [...this.newRoles],
      });
      this.email = '';
      this.password = '';
      this.newRoles = new Set();
      await this.reload();
    });
  }

  protected edit(account: Account): void {
    this.editRoles = new Set(account.roles.map((entry) => entry.role.id));
    this.editing.set(account.id);
  }

  protected async saveRoles(account: Account): Promise<void> {
    await this.run(async () => {
      await this.api.put(`accounts/${account.id}/roles`, { roleIds: [...this.editRoles] });
      this.editing.set(null);
      await this.reload();
    });
  }

  protected async disable(account: Account): Promise<void> {
    const reason = window.prompt(`Motivo para desactivar ${account.email}:`)?.trim();
    if (!reason) {
      return;
    }
    await this.run(async () => {
      await this.api.post(`accounts/${account.id}/disable`, { reason });
      await this.reload();
    });
  }

  protected async enable(account: Account): Promise<void> {
    await this.run(async () => {
      await this.api.post(`accounts/${account.id}/enable`);
      await this.reload();
    });
  }

  private async reload(): Promise<void> {
    this.accounts.set(await this.api.get<Account[]>('accounts'));
  }

  private async run(work: () => Promise<void>): Promise<void> {
    this.busy.set(true);
    this.error.set('');
    try {
      await work();
    } catch (error) {
      this.error.set(errorMessage(error));
    } finally {
      this.busy.set(false);
    }
  }
}
