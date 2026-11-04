import { provideHttpClient } from '@angular/common/http';
import { provideHttpClientTesting } from '@angular/common/http/testing';
import { TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import type { Me, Permission } from '../core/api';
import { Session } from '../core/session';
import { Shell } from './shell';

function menuFor(roleName: string, permissions: Permission[]): string[] {
  const session = TestBed.inject(Session);
  session.me.set({
    id: '1',
    email: 'usuario@empresa.mx',
    company: { name: 'Empresa', slug: 'empresa' },
    employee: null,
    roles: [{ code: 'X', name: roleName }],
    permissions,
  } satisfies Me);
  const fixture = TestBed.createComponent(Shell);
  fixture.detectChanges();
  return [...(fixture.nativeElement as HTMLElement).querySelectorAll('nav a')].map(
    (link) => link.textContent?.trim() ?? '',
  );
}

describe('Menú según el rol', () => {
  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [Shell],
      providers: [provideHttpClient(), provideHttpClientTesting(), provideRouter([])],
    }).compileComponents();
  });

  it('el administrador ve sucursales, cuentas y bitácora, pero no empleados', () => {
    expect(
      menuFor('Administrador', [
        'self.read',
        'company.read',
        'branches.read',
        'branches.manage',
        'accounts.read',
        'accounts.manage',
        'audit.read',
      ]),
    ).toEqual(['Inicio', 'Sucursales', 'Cuentas y roles', 'Bitácora']);
  });

  it('RH ve empleados y sucursales', () => {
    expect(
      menuFor('Recursos Humanos', ['self.read', 'company.read', 'branches.read', 'employees.read', 'employees.manage']),
    ).toEqual(['Inicio', 'Empleados', 'Sucursales']);
  });

  it('el empleado solo ve el inicio', () => {
    expect(menuFor('Empleado', ['self.read'])).toEqual(['Inicio']);
  });
});
