export type ReviewStatus = 'approved' | 'rejected' | 'pending';

/**
 * Estado de una checada para RH: las faciales a tiempo las aprueba el sistema
 * al recibirlas (`requiresReview` falso); las demás esperan una revisión.
 */
export function reviewStatus(
  requiresReview: boolean,
  decision: 'APPROVED' | 'REJECTED' | null | undefined,
): ReviewStatus {
  if (decision === 'REJECTED') return 'rejected';
  if (decision === 'APPROVED' || !requiresReview) return 'approved';
  return 'pending';
}
