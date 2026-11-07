import { X509Certificate } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Inject, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/**
 * Huella SHA-256 del certificado TLS del servidor (sobre su DER), en hexadecimal
 * sin separadores. La tablet la fija al vincularse; el admin la compara en
 * pantalla con la que ve la tablet.
 */
export function certificateFingerprint(
  certFile: string | undefined,
): string | null {
  if (!certFile) return null;
  return new X509Certificate(readFileSync(certFile)).fingerprint256
    .replaceAll(':', '')
    .toLowerCase();
}

/** Forma corta para comparar a simple vista: AB12 CD34 EF56 7890. */
export function shortFingerprint(fingerprint: string | null): string | null {
  return fingerprint
    ? fingerprint.slice(0, 16).toUpperCase().match(/.{4}/g)!.join(' ')
    : null;
}

@Injectable()
export class ServerIdentity {
  readonly fingerprint: string | null;

  constructor(@Inject(ConfigService) config: ConfigService) {
    this.fingerprint = certificateFingerprint(
      config.get<string>('TLS_CERT_FILE'),
    );
  }

  get shortFingerprint(): string | null {
    return shortFingerprint(this.fingerprint);
  }
}
