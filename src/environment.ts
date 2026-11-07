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
    ...tlsFiles(config),
  };
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
