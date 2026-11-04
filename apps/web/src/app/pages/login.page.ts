import { Component, computed, inject, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { DomSanitizer } from '@angular/platform-browser';
import type { SafeUrl } from '@angular/platform-browser';
import { Router } from '@angular/router';
import { Api, errorMessage } from '../core/api';
import type { LoginStep } from '../core/api';
import { Session } from '../core/session';

type Step = 'credentials' | 'setup' | 'code';

@Component({
  selector: 'app-login-page',
  imports: [FormsModule],
  styles: `
    main {
      max-width: 520px;
      margin: 0 auto;
      padding: clamp(32px, 8vw, 80px) 16px;
    }
    .secret {
      padding: 12px;
      border: 1px dashed var(--line);
      border-radius: 8px;
      font-family: ui-monospace, monospace;
      font-size: 18px;
      letter-spacing: 0.08em;
      word-break: break-all;
    }
    ol {
      padding-left: 20px;
    }
  `,
  template: `
    <main>
      <p class="eyebrow">Panel administrativo</p>
      <h1>Control de Recursos Humanos</h1>

      <section class="card">
        @switch (step()) {
          @case ('credentials') {
            <h2>Iniciar sesión</h2>
            <form class="stack" (ngSubmit)="signIn()">
              <label>
                Código de empresa
                <input name="company" [(ngModel)]="company" autocomplete="organization" required />
              </label>
              <label>
                Correo
                <input name="email" type="email" [(ngModel)]="email" autocomplete="username" required />
              </label>
              <label>
                Contraseña
                <input
                  name="password"
                  type="password"
                  [(ngModel)]="password"
                  autocomplete="current-password"
                  required
                />
              </label>
              <button type="submit" [disabled]="busy()">{{ busy() ? 'Verificando…' : 'Continuar' }}</button>
            </form>
          }
          @case ('setup') {
            <h2>Configura la verificación en dos pasos</h2>
            <ol>
              <li>Abre una app autenticadora (Google Authenticator, Microsoft Authenticator u otra).</li>
              <li>
                Agrega una cuenta con esta clave
                @if (setupUri()) {
                  o <a [href]="setupUri()">ábrela directamente en este dispositivo</a>
                }
                :
              </li>
            </ol>
            <p class="secret" data-testid="totp-secret">{{ groupedSecret() }}</p>
            <p class="muted">Después escribe el código de 6 dígitos que muestra la app.</p>
          }
          @case ('code') {
            <h2>Verificación en dos pasos</h2>
            <p class="muted">Escribe el código de 6 dígitos de tu app autenticadora.</p>
          }
        }

        @if (step() !== 'credentials') {
          <form class="stack" (ngSubmit)="verify()">
            <label>
              Código
              <input
                name="code"
                [(ngModel)]="code"
                inputmode="numeric"
                autocomplete="one-time-code"
                maxlength="6"
                pattern="[0-9]{6}"
                required
              />
            </label>
            <button type="submit" [disabled]="busy()">{{ busy() ? 'Verificando…' : 'Entrar' }}</button>
            <button type="button" class="secondary" (click)="restart()">Volver</button>
          </form>
        }

        @if (error()) {
          <p class="error" role="alert">{{ error() }}</p>
        }
      </section>
    </main>
  `,
})
export class LoginPage {
  private readonly api = inject(Api);
  private readonly session = inject(Session);
  private readonly router = inject(Router);
  private readonly sanitizer = inject(DomSanitizer);

  protected readonly step = signal<Step>('credentials');
  protected readonly busy = signal(false);
  protected readonly error = signal('');
  protected readonly setupSecret = signal('');
  protected readonly setupUri = signal<SafeUrl | null>(null);
  protected readonly groupedSecret = computed(() => this.setupSecret().replace(/(.{4})/g, '$1 ').trim());

  protected company = '';
  protected email = '';
  protected password = '';
  protected code = '';

  protected async signIn(): Promise<void> {
    await this.attempt(async () => {
      const { nextStep } = await this.api.post<{ nextStep: LoginStep }>('auth/login', {
        company: this.company,
        email: this.email,
        password: this.password,
      });
      this.password = '';
      if (nextStep === 'MFA_SETUP') {
        const setup = await this.api.post<{ secret: string; uri: string }>('auth/mfa/setup');
        this.setupSecret.set(setup.secret);
        // Angular bloquea esquemas desconocidos; solo se permite el URI TOTP que emite la API.
        this.setupUri.set(
          setup.uri.startsWith('otpauth://totp/') ? this.sanitizer.bypassSecurityTrustUrl(setup.uri) : null,
        );
        this.step.set('setup');
      } else {
        this.step.set('code');
      }
    });
  }

  protected async verify(): Promise<void> {
    await this.attempt(async () => {
      await this.api.post('auth/mfa/verify', { code: this.code.trim() });
      this.code = '';
      await this.session.load();
      await this.router.navigateByUrl('/');
    });
  }

  protected restart(): void {
    this.step.set('credentials');
    this.code = '';
    this.setupSecret.set('');
    this.setupUri.set(null);
    this.error.set('');
  }

  private async attempt(work: () => Promise<void>): Promise<void> {
    if (this.busy()) {
      return;
    }
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
