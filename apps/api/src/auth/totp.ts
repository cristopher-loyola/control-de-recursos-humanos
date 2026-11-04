import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

// RFC 6238 con SHA-1, 6 dígitos y pasos de 30 segundos: compatible con
// Google Authenticator, Microsoft Authenticator, Authy y similares.
const STEP_SECONDS = 30;
const DIGITS = 6;
const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function newTotpSecret(): Buffer {
  return randomBytes(20);
}

export function base32(bytes: Buffer): string {
  let bits = 0;
  let value = 0;
  let output = '';
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) {
    output += BASE32[(value << (5 - bits)) & 31];
  }
  return output;
}

export function totpStep(now: Date): number {
  return Math.floor(now.getTime() / 1000 / STEP_SECONDS);
}

export function totpCode(
  secret: Buffer,
  step: number,
  digits = DIGITS,
): string {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const digest = createHmac('sha1', secret).update(counter).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const binary = digest.readUInt32BE(offset) & 0x7fffffff;
  return String(binary % 10 ** digits).padStart(digits, '0');
}

/**
 * Acepta el paso actual y uno de tolerancia a cada lado. Devuelve el paso
 * usado, que debe guardarse para impedir reutilizar el mismo código.
 */
export function matchTotp(
  secret: Buffer,
  code: string,
  now: Date,
  lastUsedStep: bigint | null,
): number | null {
  if (!/^\d{6}$/.test(code)) {
    return null;
  }
  const current = totpStep(now);
  for (const step of [current - 1, current, current + 1]) {
    if (lastUsedStep !== null && BigInt(step) <= lastUsedStep) {
      continue;
    }
    if (
      timingSafeEqual(Buffer.from(totpCode(secret, step)), Buffer.from(code))
    ) {
      return step;
    }
  }
  return null;
}

export function otpauthUri(
  secret: Buffer,
  accountLabel: string,
  issuer: string,
): string {
  const label = encodeURIComponent(`${issuer}:${accountLabel}`);
  const query = new URLSearchParams({
    secret: base32(secret),
    issuer,
    algorithm: 'SHA1',
    digits: String(DIGITS),
    period: String(STEP_SECONDS),
  });
  return `otpauth://totp/${label}?${query.toString()}`;
}
