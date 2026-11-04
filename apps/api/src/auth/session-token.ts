import { createHash, randomBytes } from 'node:crypto';
import type { Request, Response } from 'express';

export const SESSION_COOKIE = 'accesos_sesion';

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

export function readSessionCookie(request: Request): string | null {
  for (const part of (request.headers.cookie ?? '').split(';')) {
    const [name, ...value] = part.trim().split('=');
    if (name === SESSION_COOKIE) {
      return decodeURIComponent(value.join('='));
    }
  }
  return null;
}

export function writeSessionCookie(
  response: Response,
  token: string,
  secure: boolean,
  maxAgeMs: number,
) {
  response.cookie(SESSION_COOKIE, token, {
    httpOnly: true,
    sameSite: 'strict',
    secure,
    path: '/api',
    maxAge: maxAgeMs,
  });
}

export function clearSessionCookie(response: Response, secure: boolean) {
  response.clearCookie(SESSION_COOKIE, {
    httpOnly: true,
    sameSite: 'strict',
    secure,
    path: '/api',
  });
}
