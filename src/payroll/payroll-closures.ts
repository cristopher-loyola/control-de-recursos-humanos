import type { TenantTransaction } from '../database/tenant-database.js';

/**
 * Último movimiento (cierre o reapertura) de cada periodo que contiene `day`
 * (AAAA-MM-DD). Un día está cerrado si el último movimiento de algún periodo
 * que lo contiene es un cierre.
 */
export async function isPayrollClosed(
  tx: TenantTransaction,
  day: string,
): Promise<boolean> {
  const date = new Date(`${day}T00:00:00Z`);
  const moves = await tx.payrollClosure.findMany({
    where: { periodStart: { lte: date }, periodEnd: { gt: date } },
    orderBy: { occurredAt: 'desc' },
    select: { periodStart: true, periodEnd: true, action: true },
  });
  const seen = new Set<string>();
  for (const move of moves) {
    const key = `${move.periodStart.toISOString()}|${move.periodEnd.toISOString()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    if (move.action === 'CLOSED') return true;
  }
  return false;
}
