import { generateKeyPairSync, sign } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { parsePayload } from './device-events.js';
import {
  readDevicePublicKey,
  verifyDeviceSignature,
} from './device-signature.js';

const tabletId = '11111111-1111-4111-8111-111111111111';

function payload(overrides: Record<string, unknown> = {}) {
  return Buffer.from(
    JSON.stringify({
      v: 1,
      id: '22222222-2222-4222-8222-222222222222',
      tabletId,
      sequence: 1,
      previousEventHash: null,
      employeeId: '33333333-3333-4333-8333-333333333333',
      eventType: 'ENTRY',
      captureMethod: 'FACIAL',
      occurredAt: '2026-11-05T15:00:00.000Z',
      faceSimilarity: 0.71,
      faceTemplateId: '44444444-4444-4444-8444-444444444444',
      photoSha256: null,
      ...overrides,
    }),
  );
}

describe('Firma de la tablet', () => {
  const { publicKey, privateKey } = generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
  });
  const pem = publicKey.export({ type: 'spki', format: 'pem' }).toString();

  it('acepta la firma ECDSA P-256 de la llave registrada', () => {
    const body = payload();
    const signature = sign('sha256', body, privateKey);
    expect(verifyDeviceSignature(pem, body, signature)).toBe(true);
  });

  it('rechaza un payload alterado o firmado por otra llave', () => {
    const body = payload();
    const signature = sign('sha256', body, privateKey);
    expect(
      verifyDeviceSignature(pem, payload({ eventType: 'EXIT' }), signature),
    ).toBe(false);
    const other = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
    expect(
      verifyDeviceSignature(pem, body, sign('sha256', body, other.privateKey)),
    ).toBe(false);
    expect(verifyDeviceSignature(pem, body, Buffer.from('basura'))).toBe(false);
  });

  it('solo registra llaves EC P-256', () => {
    expect(readDevicePublicKey(pem).fingerprint).toMatch(/^[0-9a-f]{64}$/);
    const rsa = generateKeyPairSync('rsa', { modulusLength: 2048 });
    expect(() =>
      readDevicePublicKey(
        rsa.publicKey.export({ type: 'spki', format: 'pem' }).toString(),
      ),
    ).toThrow('EC P-256');
    expect(() => readDevicePublicKey('no es una llave')).toThrow();
  });

  it('el payload debe ser de la misma tablet y con formato válido', () => {
    expect(parsePayload(payload(), tabletId).sequence).toBe(1);
    expect(() =>
      parsePayload(
        payload({ tabletId: '55555555-5555-4555-8555-555555555555' }),
        tabletId,
      ),
    ).toThrow();
    expect(() =>
      parsePayload(payload({ eventType: 'MEAL' }), tabletId),
    ).toThrow();
    expect(() => parsePayload(payload({ sequence: 0 }), tabletId)).toThrow();
    expect(() => parsePayload(Buffer.from('{'), tabletId)).toThrow();
  });
});
