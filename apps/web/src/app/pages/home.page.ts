import { Component, inject } from '@angular/core';
import { Session } from '../core/session';
import { SystemStatus } from './system-status';

@Component({
  selector: 'app-home-page',
  imports: [SystemStatus],
  template: `
    <header>
      <p class="eyebrow">{{ session.me()?.company?.name }}</p>
      <h1>Bienvenido</h1>
      <p class="muted">
        Tu acceso:
        @for (role of session.me()?.roles; track role.code) {
          <span class="tag">{{ role.name }}</span>
        }
      </p>
      @if (session.me()?.employee; as employee) {
        <p class="muted">
          Empleado {{ employee.employeeNumber }}: {{ employee.givenNames }} {{ employee.familyNames }}
        </p>
      }
    </header>
    <app-system-status />
  `,
})
export class HomePage {
  protected readonly session = inject(Session);
}
