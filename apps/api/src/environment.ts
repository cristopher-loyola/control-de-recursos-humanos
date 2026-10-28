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

  const webOrigin = parseUrl(requiredString(config, 'WEB_ORIGIN'), 'WEB_ORIGIN');
  if (
    !['http:', 'https:'].includes(webOrigin.protocol) ||
    webOrigin.username ||
    webOrigin.password ||
    webOrigin.pathname !== '/' ||
    webOrigin.search ||
    webOrigin.hash
  ) {
    throw new Error('WEB_ORIGIN debe ser un origen HTTP o HTTPS sin ruta ni credenciales.');
  }

  const databaseUrl = requiredString(config, 'DATABASE_URL');
  const database = parseUrl(databaseUrl, 'DATABASE_URL');
  if (
    !['postgres:', 'postgresql:'].includes(database.protocol) ||
    !database.hostname ||
    database.pathname.length < 2
  ) {
    throw new Error('DATABASE_URL debe indicar un servidor y una base de datos PostgreSQL.');
  }

  return {
    ...config,
    NODE_ENV: nodeEnv,
    API_PORT: port,
    WEB_ORIGIN: webOrigin.origin,
    DATABASE_URL: databaseUrl,
  };
}
