import { Body, Controller, Get, HttpCode, Inject, Post } from '@nestjs/common';
import { TenantDatabase } from '../database/tenant-database.js';
import { email, readBody, secret, text } from '../common/input.js';
import { CurrentAuth, MfaStep, Public, RequirePermissions } from './access.js';
import type { AuthContext } from './access.js';
import { AuthService } from './auth.service.js';

/**
 * La tablet recibe el token en la respuesta y lo envía como
 * `Authorization: Bearer`. Tras el doble factor el token cambia.
 */
@Controller('auth')
export class AuthController {
  constructor(
    @Inject(AuthService) private readonly auth: AuthService,
    @Inject(TenantDatabase) private readonly db: TenantDatabase,
  ) {}

  @Public()
  @Post('login')
  @HttpCode(200)
  async login(@Body() raw: unknown) {
    const body = readBody(raw);
    const result = await this.auth.login(
      text(body, 'company', 'El código de empresa', 80).toLowerCase(),
      email(body, 'email'),
      secret(body, 'password', 'La contraseña'),
    );
    return { nextStep: result.nextStep, token: result.token };
  }

  @MfaStep()
  @Post('mfa/setup')
  @HttpCode(200)
  setupMfa(@CurrentAuth() auth: AuthContext) {
    return this.auth.startMfaSetup(auth);
  }

  @MfaStep()
  @Post('mfa/verify')
  @HttpCode(200)
  async verifyMfa(@CurrentAuth() auth: AuthContext, @Body() raw: unknown) {
    const token = await this.auth.verifyMfa(
      auth,
      text(readBody(raw), 'code', 'El código', 6),
    );
    return { nextStep: 'DONE', token };
  }

  @Post('logout')
  @HttpCode(204)
  async logout(@CurrentAuth() auth: AuthContext) {
    await this.auth.logout(auth);
  }

  @RequirePermissions('self.read')
  @Get('me')
  me(@CurrentAuth() auth: AuthContext) {
    return this.db.run(auth.companyId, async (tx) => {
      const account = await tx.account.findUniqueOrThrow({
        where: {
          companyId_id: { companyId: auth.companyId, id: auth.accountId },
        },
        include: {
          company: { select: { name: true, slug: true, logoUpdatedAt: true } },
          employee: {
            select: {
              employeeNumber: true,
              givenNames: true,
              familyNames: true,
            },
          },
          roles: { include: { role: { select: { code: true, name: true } } } },
        },
      });
      return {
        id: account.id,
        email: account.email,
        company: account.company,
        employee: account.employee,
        roles: account.roles.map(({ role }) => role),
        permissions: [...auth.permissions].sort(),
      };
    });
  }
}
