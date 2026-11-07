import { describe, expect, it } from 'vitest';
import { hashPassword, passwordProblem, verifyPassword } from './passwords.js';
import { SecretBox } from './secret-box.js';
import { base32, matchTotp, totpCode, totpStep } from './totp.js';

describe('Contraseñas', () => {
  it('verifica la contraseña correcta y rechaza otra', async () => {
    const stored = await hashPassword('una contraseña larga');
    expect(stored.startsWith('scrypt$')).toBe(true);
    expect(stored).not.toContain('una contraseña larga');
    await expect(verifyPassword('una contraseña larga', stored)).resolves.toBe(
      true,
    );
    await expect(verifyPassword('otra contraseña larga', stored)).resolves.toBe(
      false,
    );
  });

  it('usa una sal distinta en cada hash', async () => {
    expect(await hashPassword('misma contraseña')).not.toBe(
      await hashPassword('misma contraseña'),
    );
  });

  it('rechaza formatos desconocidos sin lanzar error', async () => {
    await expect(verifyPassword('x', 'pbkdf2$abc')).resolves.toBe(false);
  });

  it('exige longitud mínima', () => {
    expect(passwordProblem('corta')).toContain('12');
    expect(passwordProblem('suficientemente larga')).toBeNull();
  });
});

describe('Códigos TOTP', () => {
  const rfcSecret = Buffer.from('12345678901234567890', 'ascii');

  it('coincide con los vectores del RFC 6238 (SHA-1)', () => {
    expect(totpCode(rfcSecret, totpStep(new Date(59_000)), 8)).toBe('94287082');
    expect(totpCode(rfcSecret, totpStep(new Date(1_111_111_109_000)), 8)).toBe(
      '07081804',
    );
    expect(totpCode(rfcSecret, totpStep(new Date(2_000_000_000_000)), 8)).toBe(
      '69279037',
    );
  });

  it('codifica el secreto en base32 sin relleno', () => {
    expect(base32(Buffer.from('foobar'))).toBe('MZXW6YTBOI');
  });

  it('acepta un paso de tolerancia y rechaza códigos ya usados', () => {
    const now = new Date(1_700_000_000_000);
    const step = totpStep(now);
    const previous = totpCode(rfcSecret, step - 1);
    expect(matchTotp(rfcSecret, previous, now, null)).toBe(step - 1);
    expect(matchTotp(rfcSecret, previous, now, BigInt(step - 1))).toBeNull();
    expect(
      matchTotp(rfcSecret, totpCode(rfcSecret, step - 2), now, null),
    ).toBeNull();
    expect(matchTotp(rfcSecret, 'abcdef', now, null)).toBeNull();
  });
});

describe('Cifrado de secretos', () => {
  const box = new SecretBox(Buffer.alloc(32, 9).toString('base64'));

  it('descifra con el mismo contexto', () => {
    const sealed = box.seal(Buffer.from('secreto'), 'cuenta-1');
    expect(box.open(sealed, 'cuenta-1').toString()).toBe('secreto');
  });

  it('no permite mover el secreto a otra cuenta', () => {
    const sealed = box.seal(Buffer.from('secreto'), 'cuenta-1');
    expect(() => box.open(sealed, 'cuenta-2')).toThrow();
  });
});
