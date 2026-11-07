import { ServiceUnavailableException } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import { HealthController } from './health.controller.js';

describe('Estado de la base de datos', () => {
  it('consulta la base de datos antes de informar que está disponible', async () => {
    const query = vi.fn().mockResolvedValue([{ '?column?': 1 }]);
    const controller = new HealthController({ $queryRaw: query });

    await expect(controller.check()).resolves.toEqual({
      status: 'ok',
      database: 'up',
    });
    expect(query).toHaveBeenCalledOnce();
  });

  it('devuelve 503 sin revelar detalles del error de conexión', async () => {
    const query = vi
      .fn()
      .mockRejectedValue(new Error('Credencial de prueba privada'));
    const controller = new HealthController({ $queryRaw: query });
    const error = await controller.check().catch((cause: unknown) => cause);

    expect(error).toBeInstanceOf(ServiceUnavailableException);
    if (!(error instanceof ServiceUnavailableException)) {
      throw new Error('Se esperaba un error de servicio no disponible.');
    }
    expect(error.getStatus()).toBe(503);
    expect(error.getResponse()).toEqual({
      status: 'error',
      database: 'unavailable',
    });
    expect(JSON.stringify(error.getResponse())).not.toContain('Credencial');
  });
});
