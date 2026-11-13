import { BadRequestException } from '@nestjs/common';

/** Hasta 300 KB: el panel lo reduce a 256 px antes de subirlo. */
export const LOGO_MAX_BYTES = 300 * 1024;

const SIGNATURES: { mime: string; matches: (b: Buffer) => boolean }[] = [
  {
    mime: 'image/png',
    matches: (b) =>
      b
        .subarray(0, 8)
        .equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])),
  },
  {
    mime: 'image/jpeg',
    matches: (b) => b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff,
  },
  {
    mime: 'image/webp',
    matches: (b) =>
      b.subarray(0, 4).toString('latin1') === 'RIFF' &&
      b.subarray(8, 12).toString('latin1') === 'WEBP',
  },
];

/**
 * Lee el logo que manda el panel: `{ mime, data }` con la imagen en base64.
 * Solo PNG, JPEG o WebP, revisando los primeros bytes (no se acepta SVG: puede
 * llevar código y el API se sirve en el mismo origen que el panel).
 */
export function readLogo(body: Record<string, unknown>): {
  mime: string;
  data: Buffer;
} {
  const mime = body.mime;
  const raw = body.data;
  if (typeof mime !== 'string' || typeof raw !== 'string' || raw === '') {
    throw new BadRequestException('Elige una imagen para el logo.');
  }
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(raw)) {
    throw new BadRequestException('La imagen del logo no es válida.');
  }
  const data = Buffer.from(raw, 'base64');
  if (data.length > LOGO_MAX_BYTES) {
    throw new BadRequestException('El logo pesa más de 300 KB.');
  }
  const kind = SIGNATURES.find((s) => s.matches(data));
  if (!kind || kind.mime !== mime) {
    throw new BadRequestException(
      'El logo debe ser una imagen PNG, JPG o WebP.',
    );
  }
  return { mime: kind.mime, data };
}
