import type { INestApplication } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import type { Express } from 'express';

/** Configuración común para el servidor y las pruebas e2e. */
export function configureApp(app: INestApplication): void {
  app.setGlobalPrefix('api');
  app.enableShutdownHooks();
  // Las fotos de checadas con PIN y las plantillas viajan dentro del JSON.
  (app as NestExpressApplication).useBodyParser('json', { limit: '8mb' });
  (app.getHttpAdapter().getInstance() as Express).disable('x-powered-by');
}
