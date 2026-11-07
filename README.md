# Control de Recursos Humanos: servidor

API NestJS + PostgreSQL que corre en el servidor de la oficina. Guarda empresas,
empleados, departamentos, consentimientos, rostros (cifrados), PIN de respaldo,
tablets y checadas. Las tablets se conectan por HTTPS con un token de dispositivo
y firman cada checada; RH entra con correo, contraseña y doble factor.

La app de las tablets vive en su propio repositorio (`rh-frontend`).

## Desarrollo

```powershell
copy .env.example .env      # completar secretos
docker compose up -d postgres
pnpm install
pnpm run db:prepare
pnpm run test
pnpm run test:e2e
```

## Servidor de la oficina

```powershell
./deploy/generar-certificado.ps1 -Servidor 192.168.1.50
docker compose --profile servidor up -d --build
```

Alta de una empresa: `pnpm run empresa:crear -- --nombre "Empresa" --codigo empresa --correo admin@empresa.mx`.
