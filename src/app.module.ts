import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { resolve } from 'node:path';
import { AccountsController } from './accounts/accounts.controller.js';
import { AuditController } from './audit/audit.controller.js';
import { AuthModule } from './auth/auth.module.js';
import { BiometricBox } from './biometrics/biometric-box.js';
import { BiometricsController } from './biometrics/biometrics.controller.js';
import { DatabaseModule } from './database/database.module.js';
import { DepartmentsController } from './departments/departments.controller.js';
import { DeviceController } from './device/device.controller.js';
import { DeviceEvents } from './device/device-events.js';
import { DeviceSync } from './device/device-sync.js';
import { EmployeesController } from './employees/employees.controller.js';
import { validateEnvironment } from './environment.js';
import { HealthModule } from './health/health.module.js';
import { OrganizationController } from './organization/organization.controller.js';
import { ServerIdentity } from './server-identity.js';
import { TabletsController } from './tablets/tablets.controller.js';

@Module({
  imports: [
    ConfigModule.forRoot({
      isGlobal: true,
      // Los comandos se ejecutan desde la raíz del repositorio.
      envFilePath: resolve(process.cwd(), '.env'),
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
    BiometricsController,
    DepartmentsController,
    TabletsController,
    DeviceController,
    AuditController,
  ],
  providers: [BiometricBox, ServerIdentity, DeviceSync, DeviceEvents],
})
export class AppModule {}
