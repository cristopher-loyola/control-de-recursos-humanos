-- Panel de administración: checadas manuales, pre-nómina y permisos nuevos.

-- CreateEnum
CREATE TYPE "PayPeriodKind" AS ENUM ('WEEKLY', 'SEMIMONTHLY', 'MONTHLY');

-- CreateEnum
CREATE TYPE "PayrollClosureAction" AS ENUM ('CLOSED', 'REOPENED');

-- CreateTable
CREATE TABLE "manual_attendance_entries" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "employee_id" UUID NOT NULL,
    "event_type" "AttendanceEventType" NOT NULL,
    "occurred_at" TIMESTAMPTZ(6) NOT NULL,
    "reason" TEXT NOT NULL,
    "author_account_id" UUID NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "manual_attendance_entries_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "payroll_policies" (
    "company_id" UUID NOT NULL,
    "period_kind" "PayPeriodKind" NOT NULL DEFAULT 'WEEKLY',
    "week_start" INTEGER NOT NULL DEFAULT 1,
    "paid_days" DOUBLE PRECISION NOT NULL DEFAULT 7,
    "absence_days" DOUBLE PRECISION NOT NULL DEFAULT 1,
    "lates_per_absence" INTEGER NOT NULL DEFAULT 0,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "payroll_policies_pkey" PRIMARY KEY ("company_id")
);

-- CreateTable
CREATE TABLE "payroll_closures" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "period_start" DATE NOT NULL,
    "period_end" DATE NOT NULL,
    "action" "PayrollClosureAction" NOT NULL,
    "actor_account_id" UUID NOT NULL,
    "reason" TEXT,
    "summary" JSONB,
    "occurred_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "payroll_closures_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "manual_attendance_entries_company_id_employee_id_occurred_a_idx" ON "manual_attendance_entries"("company_id", "employee_id", "occurred_at");

-- CreateIndex
CREATE INDEX "manual_attendance_entries_company_id_branch_id_occurred_at_idx" ON "manual_attendance_entries"("company_id", "branch_id", "occurred_at");

-- CreateIndex
CREATE INDEX "manual_attendance_entries_company_id_author_account_id_idx" ON "manual_attendance_entries"("company_id", "author_account_id");

-- CreateIndex
CREATE UNIQUE INDEX "manual_attendance_entries_company_id_id_key" ON "manual_attendance_entries"("company_id", "id");

-- CreateIndex
CREATE INDEX "payroll_closures_company_id_period_start_period_end_occurre_idx" ON "payroll_closures"("company_id", "period_start", "period_end", "occurred_at");

-- CreateIndex
CREATE INDEX "payroll_closures_company_id_actor_account_id_idx" ON "payroll_closures"("company_id", "actor_account_id");

-- CreateIndex
CREATE UNIQUE INDEX "payroll_closures_company_id_id_key" ON "payroll_closures"("company_id", "id");

-- AddForeignKey
ALTER TABLE "manual_attendance_entries" ADD CONSTRAINT "manual_attendance_entries_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "manual_attendance_entries" ADD CONSTRAINT "manual_attendance_entries_company_id_branch_id_fkey" FOREIGN KEY ("company_id", "branch_id") REFERENCES "branches"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "manual_attendance_entries" ADD CONSTRAINT "manual_attendance_entries_company_id_employee_id_fkey" FOREIGN KEY ("company_id", "employee_id") REFERENCES "employees"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "manual_attendance_entries" ADD CONSTRAINT "manual_attendance_entries_company_id_author_account_id_fkey" FOREIGN KEY ("company_id", "author_account_id") REFERENCES "accounts"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "payroll_policies" ADD CONSTRAINT "payroll_policies_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "payroll_closures" ADD CONSTRAINT "payroll_closures_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "payroll_closures" ADD CONSTRAINT "payroll_closures_company_id_actor_account_id_fkey" FOREIGN KEY ("company_id", "actor_account_id") REFERENCES "accounts"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;


ALTER TABLE "manual_attendance_entries"
  ADD CONSTRAINT "manual_attendance_entries_reason_check" CHECK (length(trim("reason")) BETWEEN 10 AND 500);
ALTER TABLE "payroll_policies"
  ADD CONSTRAINT "payroll_policies_week_start_check" CHECK ("week_start" BETWEEN 1 AND 7),
  ADD CONSTRAINT "payroll_policies_paid_days_check" CHECK ("paid_days" > 0 AND "paid_days" <= 31),
  ADD CONSTRAINT "payroll_policies_absence_days_check" CHECK ("absence_days" BETWEEN 0 AND 7),
  ADD CONSTRAINT "payroll_policies_lates_check" CHECK ("lates_per_absence" BETWEEN 0 AND 31);
ALTER TABLE "payroll_closures"
  ADD CONSTRAINT "payroll_closures_period_check" CHECK ("period_end" > "period_start"),
  ADD CONSTRAINT "payroll_closures_reason_check" CHECK ("action" = 'CLOSED' OR length(trim("reason")) BETWEEN 10 AND 500),
  ADD CONSTRAINT "payroll_closures_summary_check" CHECK ("action" = 'REOPENED' OR "summary" IS NOT NULL);

-- Permisos de la API (mismo esquema que 20261104040000_aislamiento_por_empresa).
-- Evidencia: una checada manual y un cierre no se editan ni se borran.
GRANT SELECT, INSERT ON manual_attendance_entries TO accesos_app;
GRANT SELECT, INSERT, UPDATE ON payroll_policies TO accesos_app;
GRANT SELECT, INSERT ON payroll_closures TO accesos_app;

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY['manual_attendance_entries', 'payroll_policies', 'payroll_closures']
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
  (gen_random_uuid(), 'reports.read', 'Consultar el reporte de asistencia'),
  (gen_random_uuid(), 'payroll.read', 'Consultar la pre-nómina'),
  (gen_random_uuid(), 'payroll.manage', 'Cambiar reglas y cerrar periodos de pre-nómina'),
  (gen_random_uuid(), 'payroll.reopen', 'Reabrir un periodo de pre-nómina cerrado');

-- Roles de sistema de empresas existentes (ver nota en 20261105120000).
-- ADMIN gana employees.read (solo lectura) para ver empleados en el panel.
INSERT INTO role_permissions (company_id, role_id, permission_id)
SELECT r.company_id, r.id, p.id
FROM roles r
JOIN permissions p ON p.code = ANY (
  CASE r.code
    WHEN 'ADMIN' THEN ARRAY['employees.read', 'reports.read', 'payroll.read', 'payroll.reopen']
    WHEN 'RH' THEN ARRAY['reports.read', 'payroll.read', 'payroll.manage']
    ELSE ARRAY[]::text[]
  END
)
WHERE r.is_system
ON CONFLICT DO NOTHING;
