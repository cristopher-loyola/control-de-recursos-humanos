-- Revisiones de RH, festivos y metas de KPIs en el servidor.

-- CreateEnum
CREATE TYPE "ReviewDecision" AS ENUM ('APPROVED', 'REJECTED');

-- CreateTable
CREATE TABLE "attendance_reviews" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "event_id" UUID NOT NULL,
    "decision" "ReviewDecision" NOT NULL,
    "reviewer_account_id" UUID NOT NULL,
    "reason" TEXT NOT NULL,
    "reviewed_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "attendance_reviews_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "holidays" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "day" DATE NOT NULL,
    "name" VARCHAR(80) NOT NULL,
    "department_id" UUID,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "holidays_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "kpi_targets" (
    "company_id" UUID NOT NULL,
    "attendance_min" INTEGER NOT NULL DEFAULT 95,
    "punctuality_min" INTEGER NOT NULL DEFAULT 90,
    "bradford_warning" INTEGER NOT NULL DEFAULT 51,
    "bradford_alert" INTEGER NOT NULL DEFAULT 201,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "kpi_targets_pkey" PRIMARY KEY ("company_id")
);

-- CreateIndex
CREATE INDEX "attendance_reviews_company_id_reviewer_account_id_idx" ON "attendance_reviews"("company_id", "reviewer_account_id");

-- CreateIndex
CREATE UNIQUE INDEX "attendance_reviews_company_id_event_id_key" ON "attendance_reviews"("company_id", "event_id");

-- CreateIndex
CREATE INDEX "holidays_company_id_day_idx" ON "holidays"("company_id", "day");

-- CreateIndex
CREATE INDEX "holidays_company_id_department_id_idx" ON "holidays"("company_id", "department_id");

-- CreateIndex
CREATE UNIQUE INDEX "holidays_company_id_id_key" ON "holidays"("company_id", "id");

-- AddForeignKey
ALTER TABLE "attendance_reviews" ADD CONSTRAINT "attendance_reviews_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_reviews" ADD CONSTRAINT "attendance_reviews_company_id_event_id_fkey" FOREIGN KEY ("company_id", "event_id") REFERENCES "attendance_events"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_reviews" ADD CONSTRAINT "attendance_reviews_company_id_reviewer_account_id_fkey" FOREIGN KEY ("company_id", "reviewer_account_id") REFERENCES "accounts"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "holidays" ADD CONSTRAINT "holidays_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "holidays" ADD CONSTRAINT "holidays_company_id_department_id_fkey" FOREIGN KEY ("company_id", "department_id") REFERENCES "departments"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "kpi_targets" ADD CONSTRAINT "kpi_targets_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;


ALTER TABLE "attendance_reviews"
  ADD CONSTRAINT "attendance_reviews_reason_check" CHECK (length(trim("reason")) BETWEEN 10 AND 500);
ALTER TABLE "holidays"
  ADD CONSTRAINT "holidays_name_check" CHECK (length(trim("name")) BETWEEN 2 AND 80);
-- Un festivo por día y alcance (toda la empresa o un departamento).
CREATE UNIQUE INDEX "holidays_one_per_day_scope"
  ON "holidays"("company_id", "day", COALESCE("department_id", '00000000-0000-0000-0000-000000000000'::uuid));
ALTER TABLE "kpi_targets"
  ADD CONSTRAINT "kpi_targets_attendance_min_check" CHECK ("attendance_min" BETWEEN 0 AND 100),
  ADD CONSTRAINT "kpi_targets_punctuality_min_check" CHECK ("punctuality_min" BETWEEN 0 AND 100),
  ADD CONSTRAINT "kpi_targets_bradford_check" CHECK ("bradford_warning" BETWEEN 1 AND 10000 AND "bradford_alert" > "bradford_warning");

-- Permisos de la API (mismo esquema que 20261104040000_aislamiento_por_empresa).
-- Evidencia: una revisión no se edita ni se borra.
GRANT SELECT, INSERT ON attendance_reviews TO accesos_app;
GRANT SELECT, INSERT, DELETE ON holidays TO accesos_app;
GRANT SELECT, INSERT, UPDATE ON kpi_targets TO accesos_app;

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['attendance_reviews', 'holidays', 'kpi_targets']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', table_name);
    EXECUTE format(
      'CREATE POLICY tenant_isolation ON %I USING (company_id = app_current_company()) WITH CHECK (company_id = app_current_company())',
      table_name
    );
  END LOOP;
END
$$;

INSERT INTO permissions (id, code, description) VALUES
  (gen_random_uuid(), 'attendance.review', 'Revisar checadas y ver sus fotos'),
  (gen_random_uuid(), 'holidays.manage', 'Dar de alta y quitar días festivos'),
  (gen_random_uuid(), 'kpis.read', 'Consultar los KPIs de empleado'),
  (gen_random_uuid(), 'kpis.manage', 'Cambiar las metas de los KPIs');

-- Roles de sistema de empresas existentes (ver nota en 20261105120000).
INSERT INTO role_permissions (company_id, role_id, permission_id)
SELECT r.company_id, r.id, p.id
FROM roles r
JOIN permissions p ON p.code = ANY (
  CASE r.code
    WHEN 'ADMIN' THEN ARRAY['attendance.review', 'holidays.manage', 'kpis.read', 'kpis.manage']
    WHEN 'RH' THEN ARRAY['attendance.review', 'holidays.manage', 'kpis.read', 'kpis.manage']
    ELSE ARRAY[]::text[]
  END
)
WHERE r.is_system
ON CONFLICT DO NOTHING;
