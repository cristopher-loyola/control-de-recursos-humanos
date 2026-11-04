import { Inject, Injectable } from '@nestjs/common';
import type { Prisma } from '../generated/prisma/client.js';
import { PrismaService } from './prisma.service.js';

export type TenantTransaction = Prisma.TransactionClient;

/**
 * Ejecuta consultas dentro de una transacción con app.company_id fijado.
 * Las políticas de RLS limitan cada tabla a esa empresa.
 */
@Injectable()
export class TenantDatabase {
  constructor(@Inject(PrismaService) private readonly prisma: PrismaService) {}

  run<T>(
    companyId: string,
    work: (tx: TenantTransaction) => Promise<T>,
  ): Promise<T> {
    return this.prisma.$transaction(async (tx) => {
      await tx.$executeRaw`SELECT set_config('app.company_id', ${companyId}, true)`;
      return work(tx);
    });
  }

  async companyIdBySlug(slug: string): Promise<string | null> {
    const rows = await this.prisma.$queryRaw<{ id: string | null }[]>`
      SELECT app_company_id_by_slug(${slug}) AS id`;
    return rows[0]?.id ?? null;
  }
}
