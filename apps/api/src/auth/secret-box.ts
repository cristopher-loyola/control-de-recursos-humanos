import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

/** AES-256-GCM. Formato: iv (12) + etiqueta (16) + texto cifrado. */
export class SecretBox {
  private readonly key: Buffer;

  constructor(keyBase64: string) {
    this.key = Buffer.from(keyBase64, 'base64');
    if (this.key.length !== 32) {
      throw new Error('La llave de cifrado debe tener 32 bytes.');
    }
  }

  seal(plain: Buffer, context: string): Uint8Array<ArrayBuffer> {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    cipher.setAAD(Buffer.from(context, 'utf8'));
    const body = Buffer.concat([cipher.update(plain), cipher.final()]);
    return new Uint8Array(Buffer.concat([iv, cipher.getAuthTag(), body]));
  }

  open(sealed: Uint8Array, context: string): Buffer {
    const data = Buffer.from(sealed);
    if (data.length <= 28) {
      throw new Error('Secreto cifrado inválido.');
    }
    const decipher = createDecipheriv(
      'aes-256-gcm',
      this.key,
      data.subarray(0, 12),
    );
    decipher.setAAD(Buffer.from(context, 'utf8'));
    decipher.setAuthTag(data.subarray(12, 28));
    return Buffer.concat([
      decipher.update(data.subarray(28)),
      decipher.final(),
    ]);
  }
}
