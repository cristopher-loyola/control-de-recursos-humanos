-- El administrador también da de alta y modifica departamentos y empleados.
-- Cada alta o cambio queda en audit_entries con la cuenta que lo hizo.
-- Requiere que el dueño pueda saltar RLS (superusuario, como en Docker y CI);
-- si no, las filas no se ven y no hace nada.
INSERT INTO role_permissions (company_id, role_id, permission_id)
SELECT r.company_id, r.id, p.id
FROM roles r
JOIN permissions p ON p.code IN ('departments.manage', 'employees.manage')
WHERE r.is_system AND r.code = 'ADMIN'
ON CONFLICT DO NOTHING;

UPDATE roles
SET description = 'Configura la empresa, sucursales, cuentas y roles; también da de alta departamentos y empleados.',
    updated_at = CURRENT_TIMESTAMP
WHERE is_system AND code = 'ADMIN';
