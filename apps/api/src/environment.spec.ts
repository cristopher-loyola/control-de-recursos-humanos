import { describe, expect, it } from 'vitest';
import { validateEnvironment } from './environment.js';

const validEnvironment = {
  NODE_ENV: 'development',
  API_PORT: '3000',
  WEB_ORIGIN: 'http://localhost:4200/',
  DATABASE_URL: 'postgresql://localhost:5432/test_db',
  TOTP_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString('base64'),
};

describe('Validación del entorno', () => {
  it('convierte el puerto y normaliza el origen del frontend', () => {
    expect(validateEnvironment(validEnvironment)).toEqual({
      ...validEnvironment,
      API_PORT: 3000,
      WEB_ORIGIN: 'http://localhost:4200',
    });
  });

  it.each([
    'NODE_ENV',
    'API_PORT',
    'WEB_ORIGIN',
    'DATABASE_URL',
    'TOTP_ENCRYPTION_KEY',
  ])('rechaza la ausencia de %s', (key) => {
    expect(() =>
      validateEnvironment({ ...validEnvironment, [key]: undefined }),
    ).toThrow(key);
  });

  it.each(['0', '65536', '3000.5', 'abc'])(
    'rechaza el puerto inválido %s',
    (port) => {
      expect(() =>
        validateEnvironment({ ...validEnvironment, API_PORT: port }),
      ).toThrow('API_PORT');
    },
  );

  it('rechaza un entorno desconocido', () => {
    expect(() =>
      validateEnvironment({ ...validEnvironment, NODE_ENV: 'invalid' }),
    ).toThrow('NODE_ENV');
  });

  it.each(['*', 'ftp://localhost', 'http://localhost:4200/path'])(
    'rechaza un origen inválido: %s',
    (origin) => {
      expect(() =>
        validateEnvironment({ ...validEnvironment, WEB_ORIGIN: origin }),
      ).toThrow('WEB_ORIGIN');
    },
  );

  it.each(['invalid-secret', 'mysql://localhost/db', 'postgresql://localhost'])(
    'rechaza una URL de base de datos inválida sin revelar su valor',
    (databaseUrl) => {
      const validate = () =>
        validateEnvironment({ ...validEnvironment, DATABASE_URL: databaseUrl });
      expect(validate).toThrow('DATABASE_URL');
      try {
        validate();
      } catch (error) {
        expect((error as Error).message).not.toContain(databaseUrl);
      }
    },
  );

  it.each([Buffer.alloc(16).toString('base64'), 'no es base64!'])(
    'rechaza una llave de doble factor inválida',
    (key) => {
      expect(() =>
        validateEnvironment({ ...validEnvironment, TOTP_ENCRYPTION_KEY: key }),
      ).toThrow('TOTP_ENCRYPTION_KEY');
    },
  );
});
