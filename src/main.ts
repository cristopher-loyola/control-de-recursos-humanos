import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { NestFactory } from '@nestjs/core';
import { ConfigService } from '@nestjs/config';
import { config } from 'dotenv';
import { configureApp } from './app-setup.js';
import { AppModule } from './app.module.js';

/**
 * En la oficina el API sirve HTTPS directo con un certificado propio
 * (deploy/generar-certificado.ps1); las tablets lo fijan por huella.
 */
function httpsOptions() {
  config({ path: resolve(process.cwd(), '.env'), quiet: true });
  const cert = process.env.TLS_CERT_FILE?.trim();
  const key = process.env.TLS_KEY_FILE?.trim();
  return cert && key
    ? { cert: readFileSync(cert), key: readFileSync(key) }
    : undefined;
}

async function bootstrap() {
  // CORS solo para los orígenes del panel en ADMIN_ORIGINS (configureApp).
  const app = await NestFactory.create(AppModule, {
    httpsOptions: httpsOptions(),
  });
  configureApp(app);
  await app.listen(app.get(ConfigService).getOrThrow<number>('API_PORT'));
}
await bootstrap();
