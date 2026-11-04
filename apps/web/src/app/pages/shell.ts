import { Component, computed, inject } from '@angular/core';
import { Router, RouterLink, RouterLinkActive, RouterOutlet } from '@angular/router';
import type { Permission } from '../core/api';
import { Session } from '../core/session';

const SECTIONS: { path: string; label: string; permission: Permission }[] = [
  { path: '/empleados', label: 'Empleados', permission: 'employees.read' },
  { path: '/sucursales', label: 'Sucursales', permission: 'branches.read' },
  { path: '/cuentas', label: 'Cuentas y roles', permission: 'accounts.read' },
  { path: '/bitacora', label: 'Bitácora', permission: 'audit.read' },
];

@Component({
  selector: 'app-shell',
  imports: [RouterLink, RouterLinkActive, RouterOutlet],
  styles: `
    :host {
      display: grid;
      grid-template-columns: 240px 1fr;
      min-height: 100svh;
    }
    nav {
      display: flex;
      flex-direction: column;
      gap: 4px;
      padding: 24px 16px;
      border-right: 1px solid var(--line);
      background: var(--surface);
    }
    nav .company {
      margin: 0 8px 20px;
      font-weight: 650;
    }
    nav a {
      padding: 10px 12px;
      border-radius: 8px;
      color: var(--ink);
      text-decoration: none;
    }
    nav a.active {
      background: var(--accent-soft);
      color: var(--accent-strong);
      font-weight: 600;
    }
    nav .account {
      margin-top: auto;
      padding: 12px 8px 0;
      border-top: 1px solid var(--line);
      font-size: 14px;
      overflow-wrap: anywhere;
    }
    nav .account button {
      width: 100%;
      margin-top: 12px;
    }
    main {
      width: 100%;
      max-width: 1080px;
      padding: clamp(20px, 4vw, 48px) 16px;
    }
    @media (max-width: 760px) {
      :host {
        grid-template-columns: 1fr;
      }
      nav {
        border-right: 0;
        border-bottom: 1px solid var(--line);
      }
    }
  `,
  template: `
    <nav aria-label="Menú principal">
      <p class="company">{{ session.me()?.company?.name }}</p>
      <a routerLink="/" routerLinkActive="active" [routerLinkActiveOptions]="{ exact: true }">Inicio</a>
      @for (section of sections(); track section.path) {
        <a [routerLink]="section.path" routerLinkActive="active">{{ section.label }}</a>
      }
      <div class="account">
        <div>{{ session.me()?.email }}</div>
        <div class="muted">{{ roleNames() }}</div>
        <button type="button" class="secondary" (click)="logout()">Cerrar sesión</button>
      </div>
    </nav>
    <main>
      <router-outlet />
    </main>
  `,
})
export class Shell {
  protected readonly session = inject(Session);
  private readonly router = inject(Router);

  protected readonly sections = computed(() =>
    SECTIONS.filter((section) => this.session.me()?.permissions.includes(section.permission)),
  );
  protected readonly roleNames = computed(
    () =>
      this.session
        .me()
        ?.roles.map((role) => role.name)
        .join(', ') ?? '',
  );

  protected async logout(): Promise<void> {
    await this.session.logout();
    await this.router.navigateByUrl('/entrar');
  }
}
