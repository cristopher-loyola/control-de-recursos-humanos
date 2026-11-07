import { pbkdf2Sync } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import { readSamples, score } from './face.js';
import { hashPin, PIN_ITERATIONS, pinProblem } from './pin.js';

function vector(seed: number): number[] {
  return Array.from({ length: 128 }, (_, i) => Math.sin(seed * 31 + i * 7));
}

describe('PIN de respaldo (mismas reglas que la tablet)', () => {
  it.each(['1111', '1234', '98765', '12', '1234567', 'abcd'])(
    'rechaza %s',
    (pin) => expect(pinProblem(pin)).not.toBeNull(),
  );

  it.each(['4821', '0950', '271828'])('acepta %s', (pin) =>
    expect(pinProblem(pin)).toBeNull(),
  );

  it('deriva PBKDF2-HMAC-SHA256 de 32 bytes, verificable sin red', async () => {
    const { salt, hash, iterations } = await hashPin('4821');
    expect(iterations).toBe(PIN_ITERATIONS);
    expect(salt).toHaveLength(16);
    expect(
      hash.equals(pbkdf2Sync('4821', salt, iterations, 32, 'sha256')),
    ).toBe(true);
  });
});

describe('Plantilla facial', () => {
  it('exige de 3 a 15 tomas consistentes de 128 valores', () => {
    const base = vector(1);
    const near = (k: number) => base.map((v, i) => v + 0.01 * Math.cos(i * k));
    expect(readSamples([near(1), near(2), near(3)])).toHaveLength(3);
    expect(() => readSamples([near(1), near(2)])).toThrow();
    expect(() => readSamples([near(1), near(2), vector(9)])).toThrow('cambió');
    expect(() => readSamples([near(1), near(2), [1, 2, 3]])).toThrow();
  });

  it('el mismo rostro supera el umbral y uno distinto no', () => {
    const base = vector(1);
    const near = (k: number) => base.map((v, i) => v + 0.01 * Math.cos(i * k));
    const enrolled = readSamples([near(1), near(2), near(3)]);
    const again = readSamples([near(4), near(5), near(6)]);
    const other = readSamples([vector(7), vector(7), vector(7)]);
    expect(score(again, enrolled)).toBeGreaterThan(0.9);
    expect(score(other, enrolled)).toBeLessThan(0.45);
  });
});
