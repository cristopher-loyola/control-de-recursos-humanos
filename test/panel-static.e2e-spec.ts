// El API puede servir el build del panel en el mismo origen (ADMIN_PANEL_DIR).
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { configureApp, servePanel } from '../src/app-setup.js';
import { AppModule } from '../src/app.module.js';

let app: INestApplication;

beforeAll(async () => {
  const dir = mkdtempSync(join(tmpdir(), 'rh-admin-'));
  writeFileSync(join(dir, 'index.html'), '<html>panel</html>');
  writeFileSync(join(dir, 'main-ABC123.js'), 'console.log(1)');
  const module = await Test.createTestingModule({
    imports: [AppModule],
  }).compile();
  app = module.createNestApplication();
  configureApp(app);
  servePanel(app, dir);
  await app.init();
});

afterAll(async () => {
  await app?.close();
});

describe('Panel en el mismo origen', () => {
  it('sirve los archivos del build y regresa index.html en las rutas del panel', async () => {
    const asset = await request(app.getHttpServer())
      .get('/main-ABC123.js')
      .expect(200);
    expect(asset.text).toContain('console.log');
    const home = await request(app.getHttpServer())
      .get('/?empresa=demo')
      .expect(200);
    expect(home.text).toContain('panel');
    expect(home.headers['cache-control']).toBe('no-cache');
    const deep = await request(app.getHttpServer())
      .get('/empleados')
      .expect(200);
    expect(deep.text).toContain('panel');
    const nested = await request(app.getHttpServer())
      .get('/indicadores/empleado/abc?nombre=Ana')
      .expect(200);
    expect(nested.text).toContain('panel');
  });

  it('un archivo que no existe da 404, no la página', async () => {
    await request(app.getHttpServer()).get('/chunk-VIEJO.js').expect(404);
  });

  it('no tapa las rutas del API', async () => {
    await request(app.getHttpServer()).get('/api/auth/me').expect(401);
    await request(app.getHttpServer()).get('/api/no-existe').expect(404);
  });
});
