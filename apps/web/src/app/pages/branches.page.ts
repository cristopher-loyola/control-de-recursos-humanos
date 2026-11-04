import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, errorMessage } from '../core/api';
import type { Branch } from '../core/api';
import { Session } from '../core/session';

@Component({
  selector: 'app-branches-page',
  imports: [FormsModule],
  template: `
    <h1>Sucursales</h1>

    @if (session.can('branches.manage')) {
      <section class="card">
        <h2>Nueva sucursal</h2>
        <form class="grid" (ngSubmit)="create()">
          <label>Clave <input name="code" [(ngModel)]="code" required maxlength="40" /></label>
          <label>Nombre <input name="name" [(ngModel)]="name" required maxlength="160" /></label>
          <button type="submit" [disabled]="busy()">Guardar</button>
        </form>
        @if (error()) {
          <p class="error" role="alert">{{ error() }}</p>
        }
      </section>
    }

    <section class="card">
      <div class="table-wrap">
        <table>
          <thead>
            <tr><th>Clave</th><th>Nombre</th><th>Estado</th></tr>
          </thead>
          <tbody>
            @for (branch of branches(); track branch.id) {
              <tr>
                <td>{{ branch.code }}</td>
                <td>{{ branch.name }}</td>
                <td>{{ branch.isActive ? 'Activa' : 'Inactiva' }}</td>
              </tr>
            } @empty {
              <tr><td colspan="3" class="muted">Sin sucursales registradas.</td></tr>
            }
          </tbody>
        </table>
      </div>
    </section>
  `,
})
export class BranchesPage implements OnInit {
  private readonly api = inject(Api);
  protected readonly session = inject(Session);
  protected readonly branches = signal<Branch[]>([]);
  protected readonly busy = signal(false);
  protected readonly error = signal('');
  protected code = '';
  protected name = '';

  async ngOnInit(): Promise<void> {
    await this.reload();
  }

  protected async create(): Promise<void> {
    this.busy.set(true);
    this.error.set('');
    try {
      await this.api.post('branches', { code: this.code, name: this.name });
      this.code = '';
      this.name = '';
      await this.reload();
    } catch (error) {
      this.error.set(errorMessage(error));
    } finally {
      this.busy.set(false);
    }
  }

  private async reload(): Promise<void> {
    try {
      this.branches.set(await this.api.get<Branch[]>('branches'));
    } catch (error) {
      this.error.set(errorMessage(error));
    }
  }
}
