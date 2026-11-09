import type { KpiTargets } from './kpi-engine.js';

/** Metas por defecto mientras la empresa no guarde las suyas. */
export const DEFAULT_TARGETS: KpiTargets = {
  attendanceMin: 95,
  punctualityMin: 90,
  bradfordWarning: 51,
  bradfordAlert: 201,
};
