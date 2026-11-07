import { createHash, createPublicKey, verify } from 'node:crypto';
import { BadRequestException } from '@nestjs/common';

export const DEVICE_KEY_ALGORITHM = 'ECDSA_P256_SHA256';

/**
 * Valida la llave pública que genera la tablet en Android Keystore
 * (EC P-256, SubjectPublicKeyInfo en PEM) y devuelve su forma canónica.
 */
export function readDevicePublicKey(pem: unknown): {
  pem: string;
  fingerprint: string;
} {
  if (typeof pem !== 'string' || pem.length > 1000) {
    throw new BadRequestException('La llave de la tablet no es válida.');
  }
  let key;
  try {
    key = createPublicKey(pem);
  } catch {
    throw new BadRequestException('La llave de la tablet no es válida.');
  }
  if (
    key.asymmetricKeyType !== 'ec' ||
    key.asymmetricKeyDetails?.namedCurve !== 'prime256v1'
  ) {
    throw new BadRequestException('La tablet debe usar una llave EC P-256.');
  }
  const der = key.export({ type: 'spki', format: 'der' });
  return {
    pem: key.export({ type: 'spki', format: 'pem' }).toString(),
    fingerprint: createHash('sha256').update(der).digest('hex'),
  };
}

/** Firma ECDSA (DER) sobre los bytes exactos del payload, sin recodificar. */
export function verifyDeviceSignature(
  publicKeyPem: string,
  payload: Buffer,
  signature: Buffer,
): boolean {
  try {
    return verify('sha256', payload, publicKeyPem, signature);
  } catch {
    return false;
  }
}

export function eventHash(payload: Buffer): string {
  return createHash('sha256').update(payload).digest('hex');
}
