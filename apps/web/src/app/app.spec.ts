import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideRouter } from '@angular/router';
import { App } from './app';

describe('Estado de conexión del panel', () => {
  let fixture: ComponentFixture<App>;
  let http: HttpTestingController;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [App],
      providers: [provideHttpClient(), provideHttpClientTesting(), provideRouter([])],
    }).compileComponents();

    http = TestBed.inject(HttpTestingController);
    fixture = TestBed.createComponent(App);
    fixture.detectChanges();
  });

  afterEach(() => {
    http.verify();
  });

  function page(): HTMLElement {
    return fixture.nativeElement as HTMLElement;
  }

  it('muestra la espera y confirma disponibilidad tras una respuesta válida', () => {
    expect(page().textContent).toContain('Comprobando conexión');
    expect(page().querySelector('button')?.disabled).toBe(true);

    const request = http.expectOne('/health');
    expect(request.request.method).toBe('GET');
    request.flush({ status: 'ok', database: 'up' });
    fixture.detectChanges();

    expect(page().querySelector('h1')?.textContent).toContain('Control de Recursos Humanos');
    expect(page().textContent).toContain('Sistema disponible');
    expect(page().querySelector('button')?.disabled).toBe(false);
  });

  it('informa cuando el servidor responde que la base de datos está caída', () => {
    http.expectOne('/health').flush(
      { status: 'error', database: 'unavailable' },
      { status: 503, statusText: 'Service Unavailable' },
    );
    fixture.detectChanges();

    expect(page().textContent).toContain('Base de datos no disponible');
    expect(page().querySelector('button')?.disabled).toBe(false);
  });

  it('gestiona un fallo de red y permite reintentar', () => {
    http.expectOne('/health').error(new ProgressEvent('error'));
    fixture.detectChanges();

    expect(page().textContent).toContain('No se pudo verificar la conexión');
    expect(page().querySelector('button')?.disabled).toBe(false);
  });

  it('no informa disponibilidad cuando el servidor devuelve contenido inesperado', () => {
    http.expectOne('/health').flush({ status: 'ok' });
    fixture.detectChanges();

    expect(page().textContent).toContain('No se pudo verificar la conexión');
    expect(page().textContent).not.toContain('Sistema disponible');
  });

  it('recupera el estado disponible al reintentar después de un error', () => {
    http.expectOne('/health').flush('Error', { status: 500, statusText: 'Server Error' });
    fixture.detectChanges();

    page().querySelector('button')!.click();
    fixture.detectChanges();
    expect(page().querySelector('button')?.disabled).toBe(true);

    http.expectOne('/health').flush({ status: 'ok', database: 'up' });
    fixture.detectChanges();
    expect(page().textContent).toContain('Sistema disponible');
  });
});
