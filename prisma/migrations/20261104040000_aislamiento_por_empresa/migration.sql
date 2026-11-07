-- Aislamiento por empresa con Row Level Security.
-- La API se conecta con un usuario miembro de "accesos_app": sin superusuario,
-- sin BYPASSRLS y sin ser dueño de las tablas. Cada transacción fija
-- app.company_id; sin ese valor ninguna política devuelve filas.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'accesos_app') THEN
    CREATE ROLE accesos_app NOLOGIN NOSUPERUSER NOBYPASSRLS;
  END IF;
END
$$;

CREATE FUNCTION app_current_company() RETURNS uuid
  LANGUAGE sql STABLE
  AS $$ SELECT NULLIF(current_setting('app.company_id', true), '')::uuid $$;

-- Único acceso entre empresas: resolver el código de una empresa activa al iniciar sesión.
CREATE FUNCTION app_company_id_by_slug(p_slug text) RETURNS uuid
  LANGUAGE sql STABLE SECURITY DEFINER
  SET search_path = public, pg_temp
  AS $$ SELECT id FROM companies WHERE slug = p_slug AND is_active $$;

REVOKE ALL ON FUNCTION app_company_id_by_slug(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app_current_company() TO accesos_app;
GRANT EXECUTE ON FUNCTION app_company_id_by_slug(text) TO accesos_app;
GRANT USAGE ON SCHEMA public TO accesos_app;

-- Catálogo global de acciones: solo lectura para la API.
GRANT SELECT ON permissions TO accesos_app;

-- Las empresas las da de alta el proveedor con el usuario dueño.
GRANT SELECT, UPDATE ON companies TO accesos_app;

GRANT SELECT, INSERT, UPDATE ON
  branches, departments, positions, employees, accounts, sessions, roles,
  tablets, device_keys, biometric_consents
TO accesos_app;

GRANT SELECT, INSERT, DELETE ON account_roles, role_permissions TO accesos_app;

-- Registros de evidencia: nunca se editan ni se borran.
GRANT SELECT, INSERT ON attendance_events, attendance_corrections, audit_entries TO accesos_app;

ALTER TABLE companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE companies FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON companies
  USING (id = app_current_company())
  WITH CHECK (id = app_current_company());

DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'branches', 'departments', 'positions', 'employees', 'accounts', 'sessions',
    'roles', 'account_roles', 'role_permissions', 'tablets', 'device_keys',
    'biometric_consents', 'attendance_events', 'attendance_corrections', 'audit_entries'
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
  (gen_random_uuid(), 'self.read', 'Consultar la propia cuenta'),
  (gen_random_uuid(), 'company.read', 'Consultar los datos de la empresa'),
  (gen_random_uuid(), 'branches.read', 'Consultar sucursales'),
  (gen_random_uuid(), 'branches.manage', 'Crear y modificar sucursales'),
  (gen_random_uuid(), 'accounts.read', 'Consultar cuentas y roles'),
  (gen_random_uuid(), 'accounts.manage', 'Crear cuentas, asignar roles y desactivar cuentas'),
  (gen_random_uuid(), 'employees.read', 'Consultar empleados'),
  (gen_random_uuid(), 'employees.manage', 'Crear y modificar empleados'),
  (gen_random_uuid(), 'audit.read', 'Consultar la bitácora de cambios');
