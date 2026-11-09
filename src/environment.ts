import { existsSync } from 'node:fs';
import { join } from 'node:path';

function requiredString(config: Record<string, unknown>, key: string): string {
  const value = config[key];
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`Falta la variable de entorno ${key}.`);
  }
  return value.trim();
}

function parseUrl(value: string, key: string): URL {
  try {
    return new URL(value);
  } catch {
    // No incluir valores que puedan contener credenciales en el error.
    throw new Error(`${key} debe ser una URL válida.`);
  }
}

export function validateEnvironment(config: Record<string, unknown>) {
  const nodeEnv = requiredString(config, 'NODE_ENV');
  if (!['development', 'test', 'production'].includes(nodeEnv)) {
    throw new Error('NODE_ENV debe ser development, test o production.');
  }

  const rawPort = requiredString(config, 'API_PORT');
  const port = Number(rawPort);
  if (!/^\d+$/.test(rawPort) || port < 1 || port > 65535) {
    throw new Error('API_PORT debe ser un entero entre 1 y 65535.');
  }

  const databaseUrl = requiredString(config, 'DATABASE_URL');
  const database = parseUrl(databaseUrl, 'DATABASE_URL');
  if (
    !['postgres:', 'postgresql:'].includes(database.protocol) ||
    !database.hostname ||
    database.pathname.length < 2
  ) {
    throw new Error(
      'DATABASE_URL debe indicar un servidor y una base de datos PostgreSQL.',
    );
  }

  const totpKey = requiredString(config, 'TOTP_ENCRYPTION_KEY');
  if (
    !/^[A-Za-z0-9+/]+={0,2}$/.test(totpKey) ||
    Buffer.from(totpKey, 'base64').length !== 32
  ) {
    throw new Error('TOTP_ENCRYPTION_KEY debe contener 32 bytes en base64.');
  }

  return {
    ...config,
    NODE_ENV: nodeEnv,
    API_PORT: port,
    DATABASE_URL: databaseUrl,
    TOTP_ENCRYPTION_KEY: totpKey,
    BIOMETRIC_ENCRYPTION_KEY: base64Key(config, 'BIOMETRIC_ENCRYPTION_KEY'),
    AUTH_REQUIRE_MFA: requireMfa(config, nodeEnv),
    ADMIN_ORIGINS: adminOrigins(config, nodeEnv),
    ...adminPanel(config),
    ...tlsFiles(config),
  };
}

/**
 * Doble factor obligatorio salvo `AUTH_REQUIRE_MFA=false` en desarrollo o
 * pruebas; en producción no se puede apagar.
 */
function requireMfa(config: Record<string, unknown>, nodeEnv: string): boolean {
  const value = config.AUTH_REQUIRE_MFA;
  if (value === undefined || value === '' || value === 'true') return true;
  if (value !== 'false') {
    throw new Error('AUTH_REQUIRE_MFA debe ser true o false.');
  }
  if (nodeEnv === 'production') {
    throw new Error('AUTH_REQUIRE_MFA no se puede desactivar en producción.');
  }
  return false;
}

/**
 * Orígenes del panel de administración que pueden llamar al API desde otro
 * origen (CORS). En producción el panel se sirve en el mismo origen y la
 * lista suele ir vacía; si se indica, solo con HTTPS.
 */
function adminOrigins(
  config: Record<string, unknown>,
  nodeEnv: string,
): string[] {
  const value = config.ADMIN_ORIGINS;
  if (value === undefined || value === null || value === '') return [];
  if (typeof value !== 'string') {
    throw new Error('ADMIN_ORIGINS debe ser una lista separada por comas.');
  }
  return [
    ...new Set(
      value
        .split(',')
        .map((item) => item.trim())
        .filter((item) => item !== '')
        .map((item) => {
          let url: URL;
          try {
            url = new URL(item);
          } catch {
            throw new Error(`ADMIN_ORIGINS: ${item} no es una URL válida.`);
          }
          if (
            !['http:', 'https:'].includes(url.protocol) ||
            url.origin !== item.replace(/\/$/, '')
          ) {
            throw new Error(
              `ADMIN_ORIGINS: ${item} debe ser solo un origen, como https://rh.empresa.mx.`,
            );
          }
          if (nodeEnv === 'production' && url.protocol !== 'https:') {
            throw new Error('ADMIN_ORIGINS solo admite HTTPS en producción.');
          }
          return url.origin;
        }),
    ),
  ];
}

/** Carpeta del build del panel para servirlo junto al API (opcional). */
function adminPanel(config: Record<string, unknown>) {
  const value = config.ADMIN_PANEL_DIR;
  if (value === undefined || value === null || value === '') return {};
  if (typeof value !== 'string' || !existsSync(join(value, 'index.html'))) {
    throw new Error(
      'ADMIN_PANEL_DIR debe ser la carpeta del build del panel (con index.html).',
    );
  }
  return { ADMIN_PANEL_DIR: value };
}

function base64Key(config: Record<string, unknown>, key: string): string {
  const value = requiredString(config, key);
  if (
    !/^[A-Za-z0-9+/]+={0,2}$/.test(value) ||
    Buffer.from(value, 'base64').length !== 32
  ) {
    throw new Error(`${key} debe contener 32 bytes en base64.`);
  }
  return value;
}

/** HTTPS directo en la red local: ambos archivos o ninguno. */
function tlsFiles(config: Record<string, unknown>) {
  const cert = config.TLS_CERT_FILE;
  const key = config.TLS_KEY_FILE;
  const present = (value: unknown) =>
    typeof value === 'string' && value.trim() !== '';
  if (present(cert) !== present(key)) {
    throw new Error('TLS_CERT_FILE y TLS_KEY_FILE se indican juntos.');
  }
  return present(cert)
    ? {
        TLS_CERT_FILE: (cert as string).trim(),
        TLS_KEY_FILE: (key as string).trim(),
      }
    : {};
}
