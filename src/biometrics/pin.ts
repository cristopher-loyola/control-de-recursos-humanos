import { pbkdf2, randomBytes } from 'node:crypto';
import { promisify } from 'node:util';

const derive = promisify(pbkdf2);

// La tablet verifica el PIN sin red con estos mismos parámetros.
export const PIN_ITERATIONS = 20_000;

/** Mensaje si el PIN no sirve, o null si es válido. */
export function pinProblem(pin: string): string | null {
  if (!/^\d{4,6}$/.test(pin)) return 'El PIN debe tener de 4 a 6 números.';
  const digits = pin.split('').map(Number);
  const same = digits.every((d) => d === digits[0]);
  let up = true;
  let down = true;
  for (let i = 1; i < digits.length; i++) {
    up &&= digits[i] === digits[i - 1] + 1;
    down &&= digits[i] === digits[i - 1] - 1;
  }
  return same || up || down
    ? 'Elige un PIN menos obvio (no 1111 ni 1234).'
    : null;
}

export async function hashPin(
  pin: string,
  salt: Buffer = randomBytes(16),
): Promise<{ salt: Buffer; hash: Buffer; iterations: number }> {
  const hash = await derive(pin, salt, PIN_ITERATIONS, 32, 'sha256');
  return { salt, hash, iterations: PIN_ITERATIONS };
}
