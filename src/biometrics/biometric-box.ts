import { Inject, Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { SecretBox } from '../auth/secret-box.js';
import type { FaceSamples } from './face.js';

/**
 * Cifra plantillas faciales y fotos de checadas con BIOMETRIC_ENCRYPTION_KEY,
 * distinta de la llave del doble factor. El contexto liga cada dato a su
 * empresa y registro: no se puede mover el cifrado a otra fila.
 */
@Injectable()
export class BiometricBox {
  private readonly box: SecretBox;

  constructor(@Inject(ConfigService) config: ConfigService) {
    this.box = new SecretBox(
      config.getOrThrow<string>('BIOMETRIC_ENCRYPTION_KEY'),
    );
  }

  private static faceContext(
    companyId: string,
    employeeId: string,
    id: string,
  ) {
    return `accesos.face.v1:${companyId}:${employeeId}:${id}`;
  }

  sealFace(
    companyId: string,
    employeeId: string,
    id: string,
    samples: FaceSamples,
  ): Uint8Array<ArrayBuffer> {
    return this.box.seal(
      Buffer.from(JSON.stringify(samples), 'utf8'),
      BiometricBox.faceContext(companyId, employeeId, id),
    );
  }

  openFace(
    companyId: string,
    employeeId: string,
    id: string,
    sealed: Uint8Array,
  ): FaceSamples {
    return JSON.parse(
      this.box
        .open(sealed, BiometricBox.faceContext(companyId, employeeId, id))
        .toString('utf8'),
    ) as FaceSamples;
  }

  sealPhoto(companyId: string, eventId: string, jpeg: Buffer) {
    return this.box.seal(jpeg, `accesos.photo.v1:${companyId}:${eventId}`);
  }

  openPhoto(companyId: string, eventId: string, sealed: Uint8Array): Buffer {
    return this.box.open(sealed, `accesos.photo.v1:${companyId}:${eventId}`);
  }
}
