-- Logo de la empresa: lo sube el administrador en el panel y se muestra en el
-- menú del panel, en el inicio de sesión y en el checador de las tablets.
ALTER TABLE "companies"
  ADD COLUMN "logo_mime" VARCHAR(20),
  ADD COLUMN "logo_data" BYTEA,
  ADD COLUMN "logo_updated_at" TIMESTAMPTZ(6);

ALTER TABLE "companies"
  ADD CONSTRAINT "companies_logo_completo"
    CHECK (("logo_data" IS NULL) = ("logo_mime" IS NULL)),
  ADD CONSTRAINT "companies_logo_tipo"
    CHECK ("logo_mime" IS NULL OR "logo_mime" IN ('image/png', 'image/jpeg', 'image/webp')),
  ADD CONSTRAINT "companies_logo_tamano"
    CHECK ("logo_data" IS NULL OR octet_length("logo_data") <= 307200);
