# database/remote — Setup del servidor real (192.168.181.248,13999)

Scripts para dejar **SPN** y **AIRLINK** listos como fuentes de solo lectura
del KMS. Se corren **una vez** en la instancia real, como sysadmin, en este
orden:

> **Principal de lectura:** por defecto los scripts otorgan `EXECUTE` a
> **`AlAppUser`** (el usuario read-only existente). Está parametrizado con
> `:setvar SyncPrincipal` — para usar otro principal:
> `sqlcmd ... -v SyncPrincipal=AlLmsSyncUser -i spn_setup.sql`.
> **Antes de darle este acceso a AlAppUser, rotar su contraseña** (fue
> expuesta en texto claro — ver nota en `00_setup_database_roles.sql`).
> AlAppUser solo lee SPN/AIRLINK; el usuario de aplicación del KMS sobre
> `AIRLINK_KMS` sigue siendo el dedicado (`AlLmsAppUser`).

## Orden de ejecución en la instancia real

```powershell
# 0. Capa de datos del KMS (crea la base y los 3 logins de la instancia).
#    Antes de correr: reemplazar los placeholders de contraseña de los 3
#    logins en 00_setup_database_roles.sql con valores del Key Vault.
.\scripts\deploy-db.ps1 -Server "192.168.181.248,13999" -Database "AIRLINK_KMS"

# 1. SPN: procedure de lectura de empleados + permisos mínimos
sqlcmd -S 192.168.181.248,13999 -d SPN -E -I -i database\remote\spn_setup.sql

# 2. AIRLINK: procedures de estaciones, contexto de producción y calidad
sqlcmd -S 192.168.181.248,13999 -d AIRLINK -E -I -i database\remote\airlink_setup.sql

# 3. Verificar el despliegue completo
.\scripts\verify-db.ps1 -Server "192.168.181.248,13999" -Database "AIRLINK_KMS"
```

## Qué ajustar antes de correr (secciones `>>> AJUSTAR <<<`)

Cada procedure tiene **una sola sección marcada** donde se mapean las tablas y
columnas reales. Los **alias de salida no se tocan** — son el contrato que el
KMS consume.

| Script | Procedure | Mapear a |
|---|---|---|
| `spn_setup.sql` | `usp_KMS_Employee_GetForSync` | Tabla real de empleados de SPN (código, nombre, apellidos, cédula, correo, puesto, departamento, sede, supervisor, fechas, estatus) |
| `airlink_setup.sql` | `usp_KMS_Station_GetForSync` | Catálogo real de estaciones de THOR/Nexus |
| `airlink_setup.sql` | `usp_KMS_ProductionHistory_GetForEmployee` | `VW_HistoryUnitProcess` (o la historia de proceso por unidad) |
| `airlink_setup.sql` | `usp_KMS_OperatorQuality_GetSummary` | Misma fuente; filtrar defectos atribuibles al operador si THOR los distingue |

## Modelo de seguridad

- El principal recibe **`EXECUTE`** sobre los procedures `usp_KMS_*`. El
  acceso a los datos dentro del procedure pasa por encadenamiento de
  propiedad (`dbo` → `dbo`), así que **no hace falta otorgar ningún
  `SELECT` nuevo**.
- Con `AlAppUser`, su `SELECT` read-only preexistente queda igual — estos
  scripts no lo amplían ni lo reducen. El contrato oficial del KMS son los
  procedures, no las tablas.
- Cada script termina con una verificación `EXECUTE AS USER` que confirma
  que el procedure ejecuta con la identidad real.
- El KMS **jamás escribe** en SPN ni en AIRLINK. Estos scripts no crean
  tablas ni tocan datos.

## Cómo consume el KMS estos procedures

```
SPN.dbo.usp_KMS_Employee_GetForSync        → intg.usp_EmployeeSync_Run (@EmployeesJson)
AIRLINK.dbo.usp_KMS_Station_GetForSync     → org.usp_Station_Upsert (por estación)
AIRLINK.dbo.usp_KMS_ProductionHistory_*    → dashboard de supervisor (en línea)
AIRLINK.dbo.usp_KMS_OperatorQuality_*      → job nocturno → esquema rpt
```

El agente que orquesta (job de SQL Agent o worker de la API) se conecta con
el principal configurado (`AlAppUser` por defecto), llama al procedure de la
fuente y entrega el resultado al SP `intg.*` correspondiente en `AIRLINK_KMS`.
Ver `docs/07-integracion-spn-airlink.md`.

## Prueba local

Los mismos scripts corren contra los mocks (`database/dev/mock_spn.sql` y
`mock_airlink.sql`), cuyas tablas usan los nombres default de las secciones
`>>> AJUSTAR <<<` — así el contrato queda probado antes de tocar el servidor
real.
