import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { resolve } from 'node:path';
import { AccountsController } from './accounts/accounts.controller.js';
import { AuditController } from './audit/audit.controller.js';
import { AuthModule } from './auth/auth.module.js';
import { DatabaseModule } from './database/database.module.js';
import { EmployeesController } from './employees/employees.controller.js';
import { validateEnvironment } from './environment.js';
import { HealthModule } from './health/health.module.js';
import { OrganizationController } from './organization/organization.controller.js';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      // Los scripts se ejecutan desde apps/api mediante pnpm --dir apps/api.
      envFilePath: resolve(process.cwd(), '../../.env'),
      validate: validateEnvironment,
    }),
    DatabaseModule,
    AuthModule,
    HealthModule,
  ],
  controllers: [
    OrganizationController,
    AccountsController,
    EmployeesController,
    AuditController,
  ],
})
export class AppModule {}
