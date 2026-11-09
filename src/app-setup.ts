import type { INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import type { NestExpressApplication } from '@nestjs/platform-express';
import type { Express } from 'express';

/** Configuración común para el servidor y las pruebas e2e. */
export function configureApp(app: INestApplication): void {
  app.setGlobalPrefix('api');
  app.enableShutdownHooks();
  // Las fotos de checadas con PIN y las plantillas viajan dentro del JSON.
  (app as NestExpressApplication).useBodyParser('json', { limit: '8mb' });
  (app.getHttpAdapter().getInstance() as Express).disable('x-powered-by');
  // El panel de administración en desarrollo corre en otro origen; en
  // producción se sirve junto al API y no necesita CORS.
  const origins = app.get(ConfigService).get<string[]>('ADMIN_ORIGINS') ?? [];
  if (origins.length > 0) {
    app.enableCors({
      origin: origins,
      methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
      allowedHeaders: ['Authorization', 'Content-Type'],
      maxAge: 600,
    });
  }
}
