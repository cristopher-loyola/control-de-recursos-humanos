-- CreateEnum
CREATE TYPE "EmploymentStatus" AS ENUM ('ACTIVE', 'TERMINATED');

-- CreateEnum
CREATE TYPE "AccountStatus" AS ENUM ('ACTIVE', 'DISABLED');

-- CreateEnum
CREATE TYPE "TabletStatus" AS ENUM ('PENDING', 'ACTIVE', 'REVOKED');

-- CreateEnum
CREATE TYPE "AttendanceEventType" AS ENUM ('ENTRY', 'EXIT', 'MEAL_START', 'MEAL_END');

-- CreateEnum
CREATE TYPE "AttendanceCaptureMethod" AS ENUM ('FACIAL', 'MANUAL_BACKUP');

-- CreateEnum
CREATE TYPE "AttendanceCorrectionAction" AS ENUM ('REPLACE', 'VOID');

-- CreateEnum
CREATE TYPE "AuditActorType" AS ENUM ('ACCOUNT', 'TABLET', 'SYSTEM');

-- CreateTable
CREATE TABLE "companies" (
    "id" UUID NOT NULL,
    "name" VARCHAR(160) NOT NULL,
    "slug" VARCHAR(80) NOT NULL,
    "time_zone" VARCHAR(80) NOT NULL DEFAULT 'America/Mexico_City',
    "is_active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "companies_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "branches" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "code" VARCHAR(40) NOT NULL,
    "name" VARCHAR(160) NOT NULL,
    "time_zone" VARCHAR(80),
    "is_active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "branches_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "departments" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "code" VARCHAR(40) NOT NULL,
    "name" VARCHAR(160) NOT NULL,
    "is_active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "departments_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "positions" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "code" VARCHAR(40) NOT NULL,
    "name" VARCHAR(160) NOT NULL,
    "is_active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "positions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "employees" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "department_id" UUID,
    "position_id" UUID,
    "employee_number" VARCHAR(40) NOT NULL,
    "given_names" VARCHAR(160) NOT NULL,
    "family_names" VARCHAR(160) NOT NULL,
    "hired_on" DATE NOT NULL,
    "employment_status" "EmploymentStatus" NOT NULL DEFAULT 'ACTIVE',
    "termination_effective_on" DATE,
    "termination_reason" TEXT,
    "termination_by_account_id" UUID,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "employees_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "accounts" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "employee_id" UUID,
    "email" VARCHAR(254) NOT NULL,
    "password_hash" TEXT NOT NULL,
    "status" "AccountStatus" NOT NULL DEFAULT 'ACTIVE',
    "disabled_at" TIMESTAMPTZ(6),
    "disabled_reason" TEXT,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "accounts_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "roles" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "code" VARCHAR(60) NOT NULL,
    "name" VARCHAR(120) NOT NULL,
    "description" TEXT,
    "is_system" BOOLEAN NOT NULL DEFAULT false,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "roles_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "permissions" (
    "id" UUID NOT NULL,
    "code" VARCHAR(120) NOT NULL,
    "description" VARCHAR(250) NOT NULL,

    CONSTRAINT "permissions_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "account_roles" (
    "company_id" UUID NOT NULL,
    "account_id" UUID NOT NULL,
    "role_id" UUID NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "account_roles_pkey" PRIMARY KEY ("company_id","account_id","role_id")
);

-- CreateTable
CREATE TABLE "role_permissions" (
    "company_id" UUID NOT NULL,
    "role_id" UUID NOT NULL,
    "permission_id" UUID NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "role_permissions_pkey" PRIMARY KEY ("company_id","role_id","permission_id")
);

-- CreateTable
CREATE TABLE "tablets" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "code" VARCHAR(60) NOT NULL,
    "name" VARCHAR(160) NOT NULL,
    "status" "TabletStatus" NOT NULL DEFAULT 'PENDING',
    "last_synchronized_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "tablets_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "device_keys" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "tablet_id" UUID NOT NULL,
    "algorithm" VARCHAR(40) NOT NULL,
    "public_key_pem" TEXT NOT NULL,
    "fingerprint" CHAR(64) NOT NULL,
    "activated_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "revoked_at" TIMESTAMPTZ(6),

    CONSTRAINT "device_keys_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "biometric_consents" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "employee_id" UUID NOT NULL,
    "recorded_by_account_id" UUID NOT NULL,
    "policy_version" VARCHAR(60) NOT NULL,
    "signed_document_object_key" TEXT NOT NULL,
    "granted_at" TIMESTAMPTZ(6) NOT NULL,
    "revoked_at" TIMESTAMPTZ(6),
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "biometric_consents_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "attendance_events" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "branch_id" UUID NOT NULL,
    "tablet_id" UUID NOT NULL,
    "device_key_id" UUID NOT NULL,
    "employee_id" UUID,
    "event_type" "AttendanceEventType" NOT NULL,
    "capture_method" "AttendanceCaptureMethod" NOT NULL,
    "device_occurred_at" TIMESTAMPTZ(6) NOT NULL,
    "server_received_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "sequence" BIGINT NOT NULL,
    "monotonic_time_ms" BIGINT,
    "boot_id" UUID,
    "latitude" DECIMAL(10,7),
    "longitude" DECIMAL(10,7),
    "photo_object_key" TEXT,
    "photo_sha256" CHAR(64),
    "face_similarity" DOUBLE PRECISION,
    "liveness_score" DOUBLE PRECISION,
    "requires_review" BOOLEAN NOT NULL DEFAULT true,
    "previous_event_hash" CHAR(64),
    "event_hash" CHAR(64) NOT NULL,
    "signed_payload" BYTEA NOT NULL,
    "signature" BYTEA NOT NULL,

    CONSTRAINT "attendance_events_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "attendance_corrections" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "original_event_id" UUID NOT NULL,
    "author_account_id" UUID NOT NULL,
    "action" "AttendanceCorrectionAction" NOT NULL,
    "corrected_employee_id" UUID,
    "corrected_event_type" "AttendanceEventType",
    "corrected_occurred_at" TIMESTAMPTZ(6),
    "reason" TEXT NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "attendance_corrections_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "audit_entries" (
    "id" UUID NOT NULL,
    "company_id" UUID NOT NULL,
    "actor_type" "AuditActorType" NOT NULL,
    "actor_account_id" UUID,
    "actor_tablet_id" UUID,
    "action" VARCHAR(120) NOT NULL,
    "entity_type" VARCHAR(80) NOT NULL,
    "entity_id" VARCHAR(200) NOT NULL,
    "details" JSONB,
    "occurred_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "audit_entries_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "companies_slug_key" ON "companies"("slug");

-- CreateIndex
CREATE UNIQUE INDEX "branches_company_id_id_key" ON "branches"("company_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "branches_company_id_code_key" ON "branches"("company_id", "code");

-- CreateIndex
CREATE UNIQUE INDEX "departments_company_id_id_key" ON "departments"("company_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "departments_company_id_code_key" ON "departments"("company_id", "code");

-- CreateIndex
CREATE UNIQUE INDEX "positions_company_id_id_key" ON "positions"("company_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "positions_company_id_code_key" ON "positions"("company_id", "code");

-- CreateIndex
CREATE INDEX "employees_company_id_branch_id_employment_status_idx" ON "employees"("company_id", "branch_id", "employment_status");

-- CreateIndex
CREATE INDEX "employees_company_id_department_id_idx" ON "employees"("company_id", "department_id");

-- CreateIndex
CREATE INDEX "employees_company_id_position_id_idx" ON "employees"("company_id", "position_id");

-- CreateIndex
CREATE INDEX "employees_company_id_termination_by_account_id_idx" ON "employees"("company_id", "termination_by_account_id");

-- CreateIndex
CREATE UNIQUE INDEX "employees_company_id_id_key" ON "employees"("company_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "employees_company_id_employee_number_key" ON "employees"("company_id", "employee_number");

-- CreateIndex
CREATE UNIQUE INDEX "accounts_company_id_id_key" ON "accounts"("company_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "accounts_company_id_email_key" ON "accounts"("company_id", "email");

-- CreateIndex
CREATE UNIQUE INDEX "accounts_company_id_employee_id_key" ON "accounts"("company_id", "employee_id");

-- CreateIndex
CREATE UNIQUE INDEX "roles_company_id_id_key" ON "roles"("company_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "roles_company_id_code_key" ON "roles"("company_id", "code");

-- CreateIndex
CREATE UNIQUE INDEX "permissions_code_key" ON "permissions"("code");

-- CreateIndex
CREATE INDEX "account_roles_company_id_role_id_idx" ON "account_roles"("company_id", "role_id");

-- CreateIndex
CREATE INDEX "role_permissions_permission_id_idx" ON "role_permissions"("permission_id");

-- CreateIndex
CREATE INDEX "tablets_company_id_branch_id_idx" ON "tablets"("company_id", "branch_id");

-- CreateIndex
CREATE UNIQUE INDEX "tablets_company_id_id_key" ON "tablets"("company_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "tablets_company_id_code_key" ON "tablets"("company_id", "code");

-- CreateIndex
CREATE UNIQUE INDEX "device_keys_company_id_tablet_id_id_key" ON "device_keys"("company_id", "tablet_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "device_keys_company_id_fingerprint_key" ON "device_keys"("company_id", "fingerprint");

-- CreateIndex
CREATE INDEX "biometric_consents_company_id_employee_id_granted_at_idx" ON "biometric_consents"("company_id", "employee_id", "granted_at");

-- CreateIndex
CREATE INDEX "biometric_consents_company_id_recorded_by_account_id_idx" ON "biometric_consents"("company_id", "recorded_by_account_id");

-- CreateIndex
CREATE UNIQUE INDEX "biometric_consents_company_id_id_key" ON "biometric_consents"("company_id", "id");

-- CreateIndex
CREATE INDEX "attendance_events_company_id_employee_id_device_occurred_at_idx" ON "attendance_events"("company_id", "employee_id", "device_occurred_at");

-- CreateIndex
CREATE INDEX "attendance_events_company_id_branch_id_device_occurred_at_idx" ON "attendance_events"("company_id", "branch_id", "device_occurred_at");

-- CreateIndex
CREATE INDEX "attendance_events_company_id_requires_review_server_receive_idx" ON "attendance_events"("company_id", "requires_review", "server_received_at");

-- CreateIndex
CREATE INDEX "attendance_events_company_id_tablet_id_device_key_id_idx" ON "attendance_events"("company_id", "tablet_id", "device_key_id");

-- CreateIndex
CREATE UNIQUE INDEX "attendance_events_company_id_id_key" ON "attendance_events"("company_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "attendance_events_company_id_tablet_id_sequence_key" ON "attendance_events"("company_id", "tablet_id", "sequence");

-- CreateIndex
CREATE INDEX "attendance_corrections_company_id_original_event_id_created_idx" ON "attendance_corrections"("company_id", "original_event_id", "created_at");

-- CreateIndex
CREATE INDEX "attendance_corrections_company_id_author_account_id_idx" ON "attendance_corrections"("company_id", "author_account_id");

-- CreateIndex
CREATE INDEX "attendance_corrections_company_id_corrected_employee_id_idx" ON "attendance_corrections"("company_id", "corrected_employee_id");

-- CreateIndex
CREATE UNIQUE INDEX "attendance_corrections_company_id_id_key" ON "attendance_corrections"("company_id", "id");

-- CreateIndex
CREATE INDEX "audit_entries_company_id_occurred_at_idx" ON "audit_entries"("company_id", "occurred_at");

-- CreateIndex
CREATE INDEX "audit_entries_company_id_entity_type_entity_id_idx" ON "audit_entries"("company_id", "entity_type", "entity_id");

-- CreateIndex
CREATE INDEX "audit_entries_company_id_actor_account_id_idx" ON "audit_entries"("company_id", "actor_account_id");

-- CreateIndex
CREATE INDEX "audit_entries_company_id_actor_tablet_id_idx" ON "audit_entries"("company_id", "actor_tablet_id");

-- AddForeignKey
ALTER TABLE "branches" ADD CONSTRAINT "branches_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "departments" ADD CONSTRAINT "departments_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "positions" ADD CONSTRAINT "positions_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "employees" ADD CONSTRAINT "employees_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "employees" ADD CONSTRAINT "employees_company_id_branch_id_fkey" FOREIGN KEY ("company_id", "branch_id") REFERENCES "branches"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "employees" ADD CONSTRAINT "employees_company_id_department_id_fkey" FOREIGN KEY ("company_id", "department_id") REFERENCES "departments"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "employees" ADD CONSTRAINT "employees_company_id_position_id_fkey" FOREIGN KEY ("company_id", "position_id") REFERENCES "positions"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "employees" ADD CONSTRAINT "employees_company_id_termination_by_account_id_fkey" FOREIGN KEY ("company_id", "termination_by_account_id") REFERENCES "accounts"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "accounts" ADD CONSTRAINT "accounts_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "accounts" ADD CONSTRAINT "accounts_company_id_employee_id_fkey" FOREIGN KEY ("company_id", "employee_id") REFERENCES "employees"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "roles" ADD CONSTRAINT "roles_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "account_roles" ADD CONSTRAINT "account_roles_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "account_roles" ADD CONSTRAINT "account_roles_company_id_account_id_fkey" FOREIGN KEY ("company_id", "account_id") REFERENCES "accounts"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "account_roles" ADD CONSTRAINT "account_roles_company_id_role_id_fkey" FOREIGN KEY ("company_id", "role_id") REFERENCES "roles"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "role_permissions" ADD CONSTRAINT "role_permissions_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "role_permissions" ADD CONSTRAINT "role_permissions_company_id_role_id_fkey" FOREIGN KEY ("company_id", "role_id") REFERENCES "roles"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "role_permissions" ADD CONSTRAINT "role_permissions_permission_id_fkey" FOREIGN KEY ("permission_id") REFERENCES "permissions"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "tablets" ADD CONSTRAINT "tablets_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "tablets" ADD CONSTRAINT "tablets_company_id_branch_id_fkey" FOREIGN KEY ("company_id", "branch_id") REFERENCES "branches"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "device_keys" ADD CONSTRAINT "device_keys_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "device_keys" ADD CONSTRAINT "device_keys_company_id_tablet_id_fkey" FOREIGN KEY ("company_id", "tablet_id") REFERENCES "tablets"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "biometric_consents" ADD CONSTRAINT "biometric_consents_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "biometric_consents" ADD CONSTRAINT "biometric_consents_company_id_employee_id_fkey" FOREIGN KEY ("company_id", "employee_id") REFERENCES "employees"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "biometric_consents" ADD CONSTRAINT "biometric_consents_company_id_recorded_by_account_id_fkey" FOREIGN KEY ("company_id", "recorded_by_account_id") REFERENCES "accounts"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_events" ADD CONSTRAINT "attendance_events_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_events" ADD CONSTRAINT "attendance_events_company_id_branch_id_fkey" FOREIGN KEY ("company_id", "branch_id") REFERENCES "branches"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_events" ADD CONSTRAINT "attendance_events_company_id_tablet_id_fkey" FOREIGN KEY ("company_id", "tablet_id") REFERENCES "tablets"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_events" ADD CONSTRAINT "attendance_events_company_id_tablet_id_device_key_id_fkey" FOREIGN KEY ("company_id", "tablet_id", "device_key_id") REFERENCES "device_keys"("company_id", "tablet_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_events" ADD CONSTRAINT "attendance_events_company_id_employee_id_fkey" FOREIGN KEY ("company_id", "employee_id") REFERENCES "employees"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_corrections" ADD CONSTRAINT "attendance_corrections_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_corrections" ADD CONSTRAINT "attendance_corrections_company_id_original_event_id_fkey" FOREIGN KEY ("company_id", "original_event_id") REFERENCES "attendance_events"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_corrections" ADD CONSTRAINT "attendance_corrections_company_id_author_account_id_fkey" FOREIGN KEY ("company_id", "author_account_id") REFERENCES "accounts"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "attendance_corrections" ADD CONSTRAINT "attendance_corrections_company_id_corrected_employee_id_fkey" FOREIGN KEY ("company_id", "corrected_employee_id") REFERENCES "employees"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "audit_entries" ADD CONSTRAINT "audit_entries_company_id_fkey" FOREIGN KEY ("company_id") REFERENCES "companies"("id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "audit_entries" ADD CONSTRAINT "audit_entries_company_id_actor_account_id_fkey" FOREIGN KEY ("company_id", "actor_account_id") REFERENCES "accounts"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;

-- AddForeignKey
ALTER TABLE "audit_entries" ADD CONSTRAINT "audit_entries_company_id_actor_tablet_id_fkey" FOREIGN KEY ("company_id", "actor_tablet_id") REFERENCES "tablets"("company_id", "id") ON DELETE RESTRICT ON UPDATE RESTRICT;
