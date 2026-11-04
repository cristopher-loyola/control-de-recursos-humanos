import type { INestApplication } from '@nestjs/common';
import type { Express } from 'express';

/** Configuración común para el servidor y las pruebas e2e. */
export function configureApp(app: INestApplication): void {
  app.setGlobalPrefix('api');
  app.enableShutdownHooks();
  (app.getHttpAdapter().getInstance() as Express).disable('x-powered-by');
}
