import { Routes } from '@angular/router';
import { allowed, signedIn } from './core/session';
import { AccountsPage } from './pages/accounts.page';
import { AuditPage } from './pages/audit.page';
import { BranchesPage } from './pages/branches.page';
import { EmployeesPage } from './pages/employees.page';
import { HomePage } from './pages/home.page';
import { LoginPage } from './pages/login.page';
import { Shell } from './pages/shell';

// Las rutas solo ocultan pantallas; la API vuelve a validar cada permiso.
export const routes: Routes = [
  { path: 'entrar', component: LoginPage, title: 'Entrar · Control de RH' },
  {
    path: '',
    component: Shell,
    canActivate: [signedIn],
    children: [
      { path: '', component: HomePage, title: 'Inicio · Control de RH' },
      {
        path: 'empleados',
        component: EmployeesPage,
        canActivate: [allowed('employees.read')],
        title: 'Empleados · Control de RH',
      },
      {
        path: 'sucursales',
        component: BranchesPage,
        canActivate: [allowed('branches.read')],
        title: 'Sucursales · Control de RH',
      },
      {
        path: 'cuentas',
        component: AccountsPage,
        canActivate: [allowed('accounts.read')],
        title: 'Cuentas · Control de RH',
      },
      {
        path: 'bitacora',
        component: AuditPage,
        canActivate: [allowed('audit.read')],
        title: 'Bitácora · Control de RH',
      },
    ],
  },
  { path: '**', redirectTo: '' },
];
