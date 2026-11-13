-- Prueba de vida de cada checada facial: cómo se confirmó (modelo pasivo,
-- reto de girar la cabeza) o si no se pudo confirmar. El puntaje ya tenía
-- columna (liveness_score).
ALTER TABLE "attendance_events" ADD COLUMN "liveness_method" VARCHAR(20);

ALTER TABLE "attendance_events"
  ADD CONSTRAINT "attendance_events_liveness_method"
    CHECK ("liveness_method" IS NULL OR "liveness_method" IN ('passive', 'passive+challenge', 'failed')),
  ADD CONSTRAINT "attendance_events_liveness_score"
    CHECK ("liveness_score" IS NULL OR ("liveness_score" >= 0 AND "liveness_score" <= 1));
