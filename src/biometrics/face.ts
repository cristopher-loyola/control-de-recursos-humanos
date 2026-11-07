import { BadRequestException } from '@nestjs/common';

// Mismos valores que usa la app de la tablet para identificar sin red.
export const FACE_DIMENSIONS = 128;
export const FACE_THRESHOLD = 0.45;
export const FACE_MIN_SAMPLES = 3;
export const FACE_MAX_SAMPLES = 15;
export const FACE_CONSISTENCY = 0.6;
export const FACE_MODEL_ID = 'sface-2021dec-0ba9fbfa-v1';

export type FaceSamples = number[][];

export function normalize(vector: number[]): number[] {
  const norm = Math.sqrt(vector.reduce((sum, v) => sum + v * v, 0));
  if (!Number.isFinite(norm) || norm < 0.000001) {
    throw new BadRequestException('No se pudo leer el rostro. Repite la toma.');
  }
  return vector.map((v) => v / norm);
}

export function cosine(a: number[], b: number[]): number {
  let sum = 0;
  for (let i = 0; i < FACE_DIMENSIONS; i++) sum += a[i] * b[i];
  return Math.min(1, Math.max(-1, sum));
}

/** Promedio de la mejor coincidencia de cada toma, como en el kiosco. */
export function score(query: FaceSamples, enrolled: FaceSamples): number {
  const best = query.map((sample) =>
    Math.max(...enrolled.map((other) => cosine(sample, other))),
  );
  return best.reduce((a, b) => a + b, 0) / best.length;
}

/** Valida y normaliza las tomas del registro (3 a 15 vectores de 128). */
export function readSamples(value: unknown): FaceSamples {
  if (
    !Array.isArray(value) ||
    value.length < FACE_MIN_SAMPLES ||
    value.length > FACE_MAX_SAMPLES
  ) {
    throw new BadRequestException(
      `Se necesitan de ${FACE_MIN_SAMPLES} a ${FACE_MAX_SAMPLES} muestras del rostro.`,
    );
  }
  const samples = value.map((sample: unknown) => {
    if (
      !Array.isArray(sample) ||
      sample.length !== FACE_DIMENSIONS ||
      !sample.every((v) => typeof v === 'number' && Number.isFinite(v))
    ) {
      throw new BadRequestException('La muestra facial no es válida.');
    }
    return normalize(sample as number[]);
  });
  // Las tomas del registro deben ser del mismo rostro.
  for (let i = 0; i < FACE_MIN_SAMPLES; i++) {
    for (let j = i + 1; j < FACE_MIN_SAMPLES; j++) {
      if (cosine(samples[i], samples[j]) < FACE_CONSISTENCY) {
        throw new BadRequestException(
          'El rostro cambió durante la toma. Repite el intento.',
        );
      }
    }
  }
  return samples;
}
