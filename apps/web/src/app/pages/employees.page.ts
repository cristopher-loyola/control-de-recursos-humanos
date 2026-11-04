import { DatePipe } from '@angular/common';
import { Component, inject, OnInit, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Api, errorMessage } from '../core/api';
import type { Branch, Employee } from '../core/api';
import { Session } from '../core/session';

@Component({
  selector: 'app-employees-page',
  imports: [FormsModule, DatePipe],
  template: `
    <h1>Empleados</h1>

    @if (session.can('employees.manage')) {
      <section class="card">
        <h2>Nuevo empleado</h2>
        <form class="grid" (ngSubmit)="create()">
          <label>Número <input name="number" [(ngModel)]="form.employeeNumber" required maxlength="40" /></label>
          <label>Nombre(s) <input name="given" [(ngModel)]="form.givenNames" required maxlength="160" /></label>
          <label>Apellidos <input name="family" [(ngModel)]="form.familyNames" required maxlength="160" /></label>
          <label>
            Sucursal
            <select name="branch" [(ngModel)]="form.branchId" required>
              <option value="" disabled>Selecciona…</option>
              @for (branch of branches(); track branch.id) {
                <option [value]="branch.id">{{ branch.name }}</option>
              }
            </select>
          </label>
          <label>Fecha de ingreso <input name="hired" type="date" [(ngModel)]="form.hiredOn" required /></label>
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
            <tr><th>Número</th><th>Nombre</th><th>Sucursal</th><th>Ingreso</th><th>Estado</th></tr>
          </thead>
          <tbody>
            @for (employee of employees(); track employee.id) {
              <tr>
                <td>{{ employee.employeeNumber }}</td>
                <td>{{ employee.familyNames }}, {{ employee.givenNames }}</td>
                <td>{{ employee.branch.name }}</td>
                <td>{{ employee.hiredOn | date: 'dd/MM/yyyy' : 'UTC' }}</td>
                <td>{{ employee.employmentStatus === 'ACTIVE' ? 'Activo' : 'Baja' }}</td>
              </tr>
            } @empty {
              <tr><td colspan="5" class="muted">Sin empleados registrados.</td></tr>
            }
          </tbody>
        </table>
      </div>
    </section>
  `,
})
export class EmployeesPage implements OnInit {
  private readonly api = inject(Api);
  protected readonly session = inject(Session);
  protected readonly employees = signal<Employee[]>([]);
  protected readonly branches = signal<Branch[]>([]);
  protected readonly busy = signal(false);
  protected readonly error = signal('');
  protected form = this.emptyForm();

  async ngOnInit(): Promise<void> {
    try {
      const [employees, branches] = await Promise.all([
        this.api.get<Employee[]>('employees'),
        this.api.get<Branch[]>('branches'),
      ]);
      this.employees.set(employees);
      this.branches.set(branches);
    } catch (error) {
      this.error.set(errorMessage(error));
    }
  }

  protected async create(): Promise<void> {
    this.busy.set(true);
    this.error.set('');
    try {
      await this.api.post('employees', this.form);
      this.form = this.emptyForm();
      this.employees.set(await this.api.get<Employee[]>('employees'));
    } catch (error) {
      this.error.set(errorMessage(error));
    } finally {
      this.busy.set(false);
    }
  }

  private emptyForm() {
    return { employeeNumber: '', givenNames: '', familyNames: '', branchId: '', hiredOn: '' };
  }
}
