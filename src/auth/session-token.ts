import { createHash, randomBytes } from 'node:crypto';
import type { Request } from 'express';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** El token lleva la empresa para fijar RLS antes de buscar la sesión. */
export function newSessionToken(companyId: string): string {
  return `${companyId}.${randomBytes(32).toString('base64url')}`;
}

export function hashSessionToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

export function companyOfToken(token: string): string | null {
  const [companyId, secret] = token.split('.');
  return companyId && UUID.test(companyId) && secret?.length === 43
    ? companyId
    : null;
}

/** La tablet envía su token (de sesión o de dispositivo) como `Authorization: Bearer`. */
export function readBearer(request: Request): string | null {
  const header = request.headers.authorization;
  if (typeof header !== 'string') return null;
  const match = /^Bearer ([A-Za-z0-9._-]{1,200})$/.exec(header);
  return match ? match[1] : null;
}
