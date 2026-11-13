import { X509Certificate, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { connect } from 'node:tls';
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

/**
 * Huella del certificado que presenta un servidor HTTPS. Se usa cuando el
 * panel corre en otro proceso que el API de las tablets: se pregunta al API
 * de las tablets qué certificado muestra, igual que hace la tablet.
 */
export function probeFingerprint(
  origin: string,
  timeoutMs = 3000,
): Promise<string> {
  const url = new URL(origin);
  return new Promise((resolve, reject) => {
    const socket = connect({
      host: url.hostname,
      port: Number(url.port || 443),
      servername: /^[\d.]+$/.test(url.hostname) ? undefined : url.hostname,
      // Certificado propio de la red local: solo se lee, no se confía en él.
      rejectUnauthorized: false,
    });
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error('El API de las tablets no respondió.'));
    }, timeoutMs);
    socket.once('secureConnect', () => {
      clearTimeout(timer);
      const raw = socket.getPeerCertificate().raw;
      socket.end();
      if (!raw)
        reject(new Error('El API de las tablets no presentó certificado.'));
      else resolve(createHash('sha256').update(raw).digest('hex'));
    });
    socket.once('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

/** Lo que la tablet necesita para vincularse sola desde el QR. */
export interface DeviceEndpoint {
  serverUrl: string;
  fingerprint: string;
}

/** Contenido del QR de vinculación; la tablet lo lee con su cámara. */
export function linkQr(
  endpoint: DeviceEndpoint,
  company: string,
  code: string,
): string {
  const params = new URLSearchParams({
    s: endpoint.serverUrl,
    f: endpoint.fingerprint,
    e: company,
    c: code,
  });
  return `rh-tablet://vincular?${params.toString()}`;
}

@Injectable()
export class ServerIdentity {
  readonly fingerprint: string | null;
  private readonly deviceUrl: string | null;
  private probed: { fingerprint: string; at: number } | null = null;

  constructor(@Inject(ConfigService) config: ConfigService) {
    this.fingerprint = certificateFingerprint(
      config.get<string>('TLS_CERT_FILE'),
    );
    this.deviceUrl = config.get<string>('DEVICE_SERVER_URL') ?? null;
  }

  get shortFingerprint(): string | null {
    return shortFingerprint(this.fingerprint);
  }

  /**
   * Dirección y huella para el QR, o null si no se pueden saber (API sin
   * HTTPS y sin DEVICE_SERVER_URL): entonces solo queda el código escrito.
   */
  async deviceEndpoint(
    requestHost: string | undefined,
  ): Promise<DeviceEndpoint | null> {
    if (this.deviceUrl) {
      const fingerprint =
        this.fingerprint ?? (await this.probe(this.deviceUrl));
      return fingerprint ? { serverUrl: this.deviceUrl, fingerprint } : null;
    }
    if (this.fingerprint && requestHost) {
      return {
        serverUrl: `https://${requestHost}`,
        fingerprint: this.fingerprint,
      };
    }
    return null;
  }

  private async probe(origin: string): Promise<string | null> {
    if (this.probed && Date.now() - this.probed.at < 60_000)
      return this.probed.fingerprint;
    try {
      const fingerprint = await probeFingerprint(origin);
      this.probed = { fingerprint, at: Date.now() };
      return fingerprint;
    } catch {
      return null;
    }
  }
}
