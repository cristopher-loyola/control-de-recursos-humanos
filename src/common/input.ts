import { BadRequestException, ConflictException } from '@nestjs/common';
import { Prisma } from '../generated/prisma/client.js';

export type Body = Record<string, unknown>;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function readBody(body: unknown): Body {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw new BadRequestException('La solicitud no tiene el formato esperado.');
  }
  return body as Body;
}

export function text(
  body: Body,
  key: string,
  label: string,
  max: number,
): string {
  const value = body[key];
  if (typeof value !== 'string' || value.trim() === '') {
    throw new BadRequestException(`${label} es obligatorio.`);
  }
  if (value.trim().length > max) {
    throw new BadRequestException(
      `${label} no puede tener más de ${max} caracteres.`,
    );
  }
  return value.trim();
}

export function optionalText(
  body: Body,
  key: string,
  label: string,
  max: number,
): string | null {
  return body[key] === undefined || body[key] === null || body[key] === ''
    ? null
    : text(body, key, label, max);
}

export function secret(body: Body, key: string, label: string): string {
  const value = body[key];
  if (typeof value !== 'string' || value === '' || value.length > 256) {
    throw new BadRequestException(`${label} es obligatoria.`);
  }
  return value;
}

export function email(body: Body, key: string): string {
  const value = text(body, key, 'El correo', 254).toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) {
    throw new BadRequestException('El correo no es válido.');
  }
  return value;
}

export function code(body: Body, key: string, label: string): string {
  const value = text(body, key, label, 40);
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new BadRequestException(
      `${label} solo admite letras, números, guion y guion bajo.`,
    );
  }
  return value;
}

export function uuid(value: unknown, label: string): string {
  if (typeof value !== 'string' || !UUID.test(value)) {
    throw new BadRequestException(`${label} no es válido.`);
  }
  return value.toLowerCase();
}

export function optionalUuid(
  body: Body,
  key: string,
  label: string,
): string | null {
  return body[key] === undefined || body[key] === null || body[key] === ''
    ? null
    : uuid(body[key], label);
}

export function uuidList(body: Body, key: string, label: string): string[] {
  const value = body[key];
  if (!Array.isArray(value) || value.length === 0 || value.length > 20) {
    throw new BadRequestException(`${label}: indica al menos uno.`);
  }
  return [...new Set(value.map((item) => uuid(item, label)))];
}

export function isoDate(body: Body, key: string, label: string): Date {
  const value = body[key];
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new BadRequestException(`${label} debe tener el formato AAAA-MM-DD.`);
  }
  const date = new Date(`${value}T00:00:00Z`);
  if (
    Number.isNaN(date.getTime()) ||
    date.toISOString().slice(0, 10) !== value
  ) {
    throw new BadRequestException(`${label} no es una fecha válida.`);
  }
  return date;
}

export function integer(
  body: Body,
  key: string,
  label: string,
  min: number,
  max: number,
): number {
  const value = body[key];
  if (
    !Number.isSafeInteger(value) ||
    (value as number) < min ||
    (value as number) > max
  ) {
    throw new BadRequestException(
      `${label} debe ser un entero de ${min} a ${max}.`,
    );
  }
  return value as number;
}

export function optionalInteger(
  body: Body,
  key: string,
  label: string,
  min: number,
  max: number,
): number | null {
  return body[key] === undefined || body[key] === null
    ? null
    : integer(body, key, label, min, max);
}

/** Convierte una violación de llave única en un 409 legible. */
export async function unique<T>(work: Promise<T>, message: string): Promise<T> {
  try {
    return await work;
  } catch (error) {
    if (
      error instanceof Prisma.PrismaClientKnownRequestError &&
      error.code === 'P2002'
    ) {
      throw new ConflictException(message);
    }
    throw error;
  }
}
