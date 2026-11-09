import { describe, expect, it } from 'vitest';
import { validateEnvironment } from './environment.js';

const validEnvironment = {
  NODE_ENV: 'development',
  API_PORT: '3000',
  DATABASE_URL: 'postgresql://localhost:5432/test_db',
  TOTP_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString('base64'),
  BIOMETRIC_ENCRYPTION_KEY: Buffer.alloc(32, 9).toString('base64'),
};

describe('Validación del entorno', () => {
  it('convierte el puerto', () => {
    expect(validateEnvironment(validEnvironment)).toEqual({
      ...validEnvironment,
      API_PORT: 3000,
      AUTH_REQUIRE_MFA: true,
      ADMIN_ORIGINS: [],
    });
  });

  it('lee los orígenes del panel sin repetir ni barra final', () => {
    expect(
      validateEnvironment({
        ...validEnvironment,
        ADMIN_ORIGINS:
          'http://localhost:5000, https://rh.empresa.mx/,http://localhost:5000',
      }).ADMIN_ORIGINS,
    ).toEqual(['http://localhost:5000', 'https://rh.empresa.mx']);
  });

  it.each(['localhost:5000', 'https://rh.empresa.mx/panel', 'ftp://rh.mx'])(
    'rechaza el origen inválido %s',
    (origin) => {
      expect(() =>
        validateEnvironment({ ...validEnvironment, ADMIN_ORIGINS: origin }),
      ).toThrow('ADMIN_ORIGINS');
    },
  );

  it('exige HTTPS en los orígenes del panel en producción', () => {
    expect(() =>
      validateEnvironment({
        ...validEnvironment,
        NODE_ENV: 'production',
        ADMIN_ORIGINS: 'http://rh.empresa.mx',
      }),
    ).toThrow('HTTPS');
  });

  it.each([
    'NODE_ENV',
    'API_PORT',
    'DATABASE_URL',
    'TOTP_ENCRYPTION_KEY',
    'BIOMETRIC_ENCRYPTION_KEY',
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

  it('acepta certificado y llave TLS juntos', () => {
    expect(
      validateEnvironment({
        ...validEnvironment,
        TLS_CERT_FILE: ' /certs/server.crt ',
        TLS_KEY_FILE: '/certs/server.key',
      }),
    ).toMatchObject({
      TLS_CERT_FILE: '/certs/server.crt',
      TLS_KEY_FILE: '/certs/server.key',
    });
  });

  it('el doble factor solo se apaga fuera de producción', () => {
    expect(validateEnvironment(validEnvironment)).toMatchObject({
      AUTH_REQUIRE_MFA: true,
    });
    expect(
      validateEnvironment({ ...validEnvironment, AUTH_REQUIRE_MFA: 'false' }),
    ).toMatchObject({ AUTH_REQUIRE_MFA: false });
    expect(() =>
      validateEnvironment({
        ...validEnvironment,
        NODE_ENV: 'production',
        AUTH_REQUIRE_MFA: 'false',
      }),
    ).toThrow('producción');
    expect(() =>
      validateEnvironment({ ...validEnvironment, AUTH_REQUIRE_MFA: 'no' }),
    ).toThrow('AUTH_REQUIRE_MFA');
  });

  it('rechaza el certificado TLS sin su llave', () => {
    expect(() =>
      validateEnvironment({ ...validEnvironment, TLS_CERT_FILE: '/x.crt' }),
    ).toThrow('TLS_KEY_FILE');
  });
});
