-- Tablets vinculadas al servidor: activación, sincronización, plantillas faciales,
-- PIN de respaldo y fotos de checadas.

-- AlterEnum
ALTER TYPE "AttendanceCaptureMethod" ADD VALUE 'PIN';

-- AlterTable
ALTER TABLE "departments" ADD COLUMN     "daily_wage_cents" INTEGER,
ADD COLUMN     "entry_minutes" INTEGER NOT NULL DEFAULT 540,
ADD COLUMN     "exit_minutes" INTEGER NOT NULL DEFAULT 1080,
ADD COLUMN     "tolerance_minutes" INTEGER NOT NULL DEFAULT 10,
ADD COLUMN     "work_days" INTEGER NOT NULL DEFAULT 31;

-- AlterTable
ALTER TABLE "employees" ADD COLUMN     "daily_wage_cents" INTEGER;

-- AlterTable
ALTER TABLE "tablets" ADD COLUMN     "last_seen_at" TIMESTAMPTZ(6),
ADD COLUMN     "token_hash" CHAR(64);

-- AlterTable
ALTER TABLE "attendance_events" ADD COLUMN     "face_template_id" UUID,
ADD COLUMN     "review_reasons" TEXT[] DEFAULT ARRAY[]::TEXT[],
ADD COLUMN     "schedule_note" TEXT;

-- CreateTable
CREATE TABLE "tablet_activations" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "tablet_id" UUID NOT NULL,
    "code_hash" CHAR(64) NOT NULL,
    "created_by_account_id" UUID,
    "expires_at" TIMESTAMPTZ(6) NOT NULL,
    "used_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "tablet_activations_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "face_templates" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "employee_id" UUID NOT NULL,
    "consent_id" UUID NOT NULL,
    "model_id" VARCHAR(80) NOT NULL,
    "sample_count" INTEGER NOT NULL,
    "encrypted_samples" BYTEA NOT NULL,
    "created_by_account_id" UUID NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "revoked_at" TIMESTAMPTZ(6),

    CONSTRAINT "face_templates_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "employee_pins" (
    "company_id" UUID NOT NULL,
    "employee_id" UUID NOT NULL,
    "salt" BYTEA NOT NULL,
    "pin_hash" BYTEA NOT NULL,
    "iterations" INTEGER NOT NULL,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "employee_pins_pkey" PRIMARY KEY ("company_id","employee_id")
);

-- CreateTable
CREATE TABLE "attendance_photos" (
    "event_id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "sha256" CHAR(64) NOT NULL,
    "encrypted_jpeg" BYTEA NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "attendance_photos_pkey" PRIMARY KEY ("event_id")
);

-- CreateIndex
CREATE INDEX "tablet_activations_company_id_tablet_id_idx" ON "tablet_activations"("company_id", "tablet_id");

-- CreateIndex
CREATE INDEX "tablet_activations_company_id_created_by_account_id_idx" ON "tablet_activations"("company_id", "created_by_account_id");

-- CreateIndex
CREATE UNIQUE INDEX "tablet_activations_company_id_code_hash_key" ON "tablet_activations"("company_id", "code_hash");

-- CreateIndex
CREATE INDEX "face_templates_company_id_employee_id_idx" ON "face_templates"("company_id", "employee_id");

-- CreateIndex
CREATE INDEX "face_templates_company_id_consent_id_idx" ON "face_templates"("company_id", "consent_id");

-- CreateIndex
CREATE INDEX "face_templates_company_id_created_by_account_id_idx" ON "face_templates"("company_id", "created_by_account_id");

-- CreateIndex
CREATE UNIQUE INDEX "face_templates_company_id_id_key" ON "face_templates"("company_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "attendance_photos_company_id_event_id_key" ON "attendance_photos"("company_id", "event_id");

-- CreateIndex
CREATE UNIQUE INDEX "tablets_token_hash_key" ON "tablets"("token_hash");

-- CreateIndex
CREATE INDEX "attendance_events_company_id_face_template_id_idx" ON "attendance_events"("company_id", "face_template_id");

-- AddForeignKey
ALTER TABLE "tablet_activations" ADD CONSTRAINT "tablet_activations_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "tablet_activations" ADD CONSTRAINT "tablet_activations_company_id_tablet_id_fkey" FOREIGN KEY ("company_id", "tablet_id") REFERENCES "tablets"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "tablet_activations" ADD CONSTRAINT "tablet_activations_company_id_created_by_account_id_fkey" FOREIGN KEY ("company_id", "created_by_account_id") REFERENCES "accounts"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_events" ADD CONSTRAINT "attendance_events_company_id_face_template_id_fkey" FOREIGN KEY ("company_id", "face_template_id") REFERENCES "face_templates"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "face_templates" ADD CONSTRAINT "face_templates_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "face_templates" ADD CONSTRAINT "face_templates_company_id_employee_id_fkey" FOREIGN KEY ("company_id", "employee_id") REFERENCES "employees"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "face_templates" ADD CONSTRAINT "face_templates_company_id_consent_id_fkey" FOREIGN KEY ("company_id", "consent_id") REFERENCES "biometric_consents"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "face_templates" ADD CONSTRAINT "face_templates_company_id_created_by_account_id_fkey" FOREIGN KEY ("company_id", "created_by_account_id") REFERENCES "accounts"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "employee_pins" ADD CONSTRAINT "employee_pins_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "employee_pins" ADD CONSTRAINT "employee_pins_company_id_employee_id_fkey" FOREIGN KEY ("company_id", "employee_id") REFERENCES "employees"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_photos" ADD CONSTRAINT "attendance_photos_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_photos" ADD CONSTRAINT "attendance_photos_company_id_event_id_fkey" FOREIGN KEY ("company_id", "event_id") REFERENCES "attendance_events"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;


-- Reglas de horario, iguales a las del kiosco.
ALTER TABLE "departments"
  ADD CONSTRAINT "departments_entry_minutes_check" CHECK ("entry_minutes" BETWEEN 0 AND 1439),
  ADD CONSTRAINT "departments_exit_minutes_check" CHECK ("exit_minutes" BETWEEN 0 AND 1439),
  ADD CONSTRAINT "departments_shift_check" CHECK ("entry_minutes" <> "exit_minutes"),
  ADD CONSTRAINT "departments_tolerance_minutes_check" CHECK ("tolerance_minutes" BETWEEN 0 AND 240),
  ADD CONSTRAINT "departments_work_days_check" CHECK ("work_days" BETWEEN 1 AND 127),
  ADD CONSTRAINT "departments_daily_wage_cents_check" CHECK ("daily_wage_cents" IS NULL OR "daily_wage_cents" BETWEEN 0 AND 100000000);
ALTER TABLE "employees"
  ADD CONSTRAINT "employees_daily_wage_cents_check" CHECK ("daily_wage_cents" IS NULL OR "daily_wage_cents" BETWEEN 0 AND 100000000);

ALTER TABLE "attendance_events" ALTER COLUMN "review_reasons" SET NOT NULL;

-- Una sola plantilla vigente por empleado.
CREATE UNIQUE INDEX "face_templates_one_active_per_employee"
  ON "face_templates"("company_id", "employee_id") WHERE "revoked_at" IS NULL;
ALTER TABLE "face_templates"
  ADD CONSTRAINT "face_templates_sample_count_check" CHECK ("sample_count" BETWEEN 3 AND 15);
ALTER TABLE "employee_pins"
  ADD CONSTRAINT "employee_pins_iterations_check" CHECK ("iterations" >= 10000);

-- Permisos de la API (mismo esquema que 20261104040000_aislamiento_por_empresa).
GRANT SELECT, INSERT, UPDATE ON tablet_activations, face_templates TO accesos_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON employee_pins TO accesos_app;
-- Evidencia: nunca se edita ni se borra.
GRANT SELECT, INSERT ON attendance_photos TO accesos_app;

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'tablet_activations', 'face_templates', 'employee_pins', 'attendance_photos'
  ]
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
  (gen_random_uuid(), 'tablets.read', 'Consultar tablets vinculadas'),
  (gen_random_uuid(), 'tablets.manage', 'Dar de alta, vincular y revocar tablets'),
  (gen_random_uuid(), 'departments.read', 'Consultar departamentos y horarios'),
  (gen_random_uuid(), 'departments.manage', 'Crear y modificar departamentos y horarios'),
  (gen_random_uuid(), 'biometrics.manage', 'Registrar consentimientos, rostros y PIN de respaldo');

-- Roles de sistema de empresas existentes. Requiere que el dueño pueda saltar RLS
-- (superusuario, como en Docker y CI); si no, la fila no se ve y no hace nada.
INSERT INTO role_permissions (company_id, role_id, permission_id)
SELECT r.company_id, r.id, p.id
FROM roles r
JOIN permissions p ON p.code = ANY (
  CASE r.code
    WHEN 'ADMIN' THEN ARRAY['tablets.read', 'tablets.manage', 'departments.read']
    WHEN 'RH' THEN ARRAY['tablets.read', 'departments.read', 'departments.manage', 'biometrics.manage']
    ELSE ARRAY[]::text[]
  END
)
WHERE r.is_system
ON CONFLICT DO NOTHING;
