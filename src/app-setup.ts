import { join, resolve } from 'node:path';
import type { INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import type { NestExpressApplication } from '@nestjs/platform-express';
import type { Express, NextFunction, Request, Response } from 'express';

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
  const panel = app.get(ConfigService).get<string>('ADMIN_PANEL_DIR');
  if (panel) servePanel(app, panel);
}

/**
 * Sirve el build del panel (rh-admin) en el mismo origen que el API: así el
 * navegador lo abre sin CORS y con el mismo certificado. Las rutas del panel
 * (sin extensión, p. ej. /empleados) regresan index.html; un archivo que no
 * existe da 404 en lugar de devolver la página.
 */
export function servePanel(app: INestApplication, dir: string): void {
  // index.html y los modelos no llevan huella en el nombre: se revalidan
  // siempre (ETag) para no servir una versión vieja.
  (app as NestExpressApplication).useStaticAssets(dir, {
    index: false,
    maxAge: 0,
  });
  const index = resolve(join(dir, 'index.html'));
  app.use((req: Request, res: Response, next: NextFunction) => {
    if (
      req.method !== 'GET' ||
      req.path === '/api' ||
      req.path.startsWith('/api/') ||
      /\.[a-z0-9]+$/i.test(req.path)
    ) {
      next();
      return;
    }
    // Sin `cacheControl: false`, sendFile cambia el encabezado por el suyo.
    res.setHeader('Cache-Control', 'no-cache');
    res.sendFile(index, { cacheControl: false });
  });
}
