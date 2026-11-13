import { describe, expect, it } from 'vitest';
import { linkQr, shortFingerprint } from './server-identity.js';

describe('QR de vinculación', () => {
  it('lleva servidor, huella completa, empresa y código', () => {
    const fingerprint = 'd42e41e5c667b46d'.padEnd(64, '0');
    const qr = linkQr(
      { serverUrl: 'https://192.168.1.10:3443', fingerprint },
      'demo',
      'ABCD-EFGH',
    );
    expect(qr.startsWith('rh-tablet://vincular?')).toBe(true);
    const params = new URL(qr).searchParams;
    expect(params.get('s')).toBe('https://192.168.1.10:3443');
    expect(params.get('f')).toBe(fingerprint);
    expect(params.get('e')).toBe('demo');
    expect(params.get('c')).toBe('ABCD-EFGH');
    expect(shortFingerprint(fingerprint)).toBe('D42E 41E5 C667 B46D');
  });
});
