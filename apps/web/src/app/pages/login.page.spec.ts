import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter, Router } from '@angular/router';
import { LoginPage } from './login.page';

describe('Entrada al panel', () => {
  let fixture: ComponentFixture<LoginPage>;
  let http: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [LoginPage],
      providers: [provideHttpClient(), provideHttpClientTesting(), provideRouter([])],
    }).compileComponents();
    http = TestBed.inject(HttpTestingController);
    fixture = TestBed.createComponent(LoginPage);
    fixture.detectChanges();
  });

  afterEach(() => http.verify());

  function page(): HTMLElement {
    return fixture.nativeElement as HTMLElement;
  }

  async function settle(): Promise<void> {
    await fixture.whenStable();
    await new Promise((resolve) => setTimeout(resolve));
    fixture.detectChanges();
  }

  async function submitCredentials(): Promise<void> {
    const component = fixture.componentInstance as unknown as Record<string, string>;
    component['company'] = 'empresa';
    component['email'] = 'admin@empresa.mx';
    component['password'] = 'contraseña segura';
    page().querySelector('form')!.dispatchEvent(new Event('submit'));
    await settle();
  }

  it('la primera vez muestra la clave para configurar el segundo factor', async () => {
    await submitCredentials();
    const login = http.expectOne('/api/auth/login');
    expect(login.request.body).toEqual({
      company: 'empresa',
      email: 'admin@empresa.mx',
      password: 'contraseña segura',
    });
    login.flush({ nextStep: 'MFA_SETUP' });
    await settle();

    http
      .expectOne('/api/auth/mfa/setup')
      .flush({ secret: 'ABCDEFGHIJKLMNOP', uri: 'otpauth://totp/x?secret=ABCDEFGHIJKLMNOP' });
    await settle();

    expect(page().querySelector('[data-testid="totp-secret"]')?.textContent).toContain('ABCD EFGH IJKL MNOP');
    expect(page().querySelector('a')?.getAttribute('href')).toBe('otpauth://totp/x?secret=ABCDEFGHIJKLMNOP');
  });

  it('pide el código, carga la sesión y entra al panel', async () => {
    const navigate = vi.spyOn(TestBed.inject(Router), 'navigateByUrl').mockResolvedValue(true);
    await submitCredentials();
    http.expectOne('/api/auth/login').flush({ nextStep: 'MFA_CODE' });
    await settle();
    expect(page().textContent).toContain('Verificación en dos pasos');

    (fixture.componentInstance as unknown as Record<string, string>)['code'] = '123456';
    page().querySelectorAll('form')[0].dispatchEvent(new Event('submit'));
    await settle();
    const verify = http.expectOne('/api/auth/mfa/verify');
    expect(verify.request.body).toEqual({ code: '123456' });
    verify.flush({ nextStep: 'DONE' });
    await settle();

    http.expectOne('/api/auth/me').flush({ id: '1', permissions: ['self.read'], roles: [] });
    await settle();
    expect(navigate).toHaveBeenCalledWith('/');
  });

  it('muestra el mensaje del servidor si las credenciales fallan', async () => {
    await submitCredentials();
    http
      .expectOne('/api/auth/login')
      .flush({ message: 'Empresa, correo o contraseña incorrectos.' }, { status: 401, statusText: 'Unauthorized' });
    await settle();
    expect(page().querySelector('[role="alert"]')?.textContent).toContain('Empresa, correo o contraseña incorrectos.');
  });
});
