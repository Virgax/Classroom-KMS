<#
.SYNOPSIS
    Verifica que el despliegue de Classroom - LMS by Airlink quedo correcto.

.DESCRIPTION
    Corre 12 comprobaciones agrupadas en tres bloques:

      ESTRUCTURA  - existen los esquemas, tablas, vistas, funciones y SPs
      SEGURIDAD   - la REGLA CERO se cumple de verdad: AlLmsAppUser no
                    tiene ni un SELECT sobre tablas
      INTEGRIDAD  - el seed cargo, no hay SPs rotos por referencias
                    invalidas, y la cadena de firmas esta intacta

    La comprobacion de seguridad es la que importa. Un LMS de compliance
    que expone las tablas directamente no vale nada: cualquier UPDATE
    fuera de un SP se salta la firma, la auditoria y la validacion.

    Codigos de salida:
      0 = todo OK
      1 = hubo fallos
      2 = hubo advertencias, sin fallos

.PARAMETER Server
    Instancia SQL Server. Ej: 192.168.181.248,13999

.PARAMETER Database
    Base a verificar. Default: AIRLINK_LMS

.PARAMETER Credential
    PSCredential. Si se omite, autenticacion integrada.

.PARAMETER Detailed
    Muestra el detalle de cada objeto encontrado o faltante.

.EXAMPLE
    .\verify-db.ps1 -Server "192.168.181.248,13999" -Detailed
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Server,

    [Parameter()]
    [string] $Database = 'AIRLINK_LMS',

    [Parameter()]
    [System.Management.Automation.PSCredential] $Credential,

    [Parameter()]
    [switch] $Detailed
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    throw "Falta el modulo SqlServer. Instalar con: Install-Module -Name SqlServer -Scope CurrentUser"
}
Import-Module SqlServer -DisableNameChecking

$connArgs = @{
    ServerInstance = $Server
    Database       = $Database
    QueryTimeout   = 120
    ErrorAction    = 'Stop'
}
if ($Credential) { $connArgs['Credential'] = $Credential }

$script:Pass = 0
$script:Fail = 0
$script:Warn = 0

function Test-Check {
    param(
        [string] $Name,
        [string] $Query,
        [scriptblock] $Assert,
        [string] $FailMessage,
        [switch] $WarnOnly
    )

    Write-Host ("  {0,-46} " -f $Name) -NoNewline
    try {
        $result = Invoke-Sqlcmd @connArgs -Query $Query
        $ok = & $Assert $result

        if ($ok) {
            Write-Host "OK" -ForegroundColor Green
            $script:Pass++
        }
        elseif ($WarnOnly) {
            Write-Host "AVISO" -ForegroundColor Yellow
            Write-Host "      $FailMessage" -ForegroundColor Yellow
            $script:Warn++
        }
        else {
            Write-Host "FALLO" -ForegroundColor Red
            Write-Host "      $FailMessage" -ForegroundColor Red
            $script:Fail++
        }

        if ($Detailed -and $result) { $result | Format-Table -AutoSize | Out-String | Write-Host }
        return $result
    }
    catch {
        Write-Host "ERROR" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
        $script:Fail++
        return $null
    }
}

Write-Host ''
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host "  Verificacion: $Database en $Server" -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor Cyan

# =====================================================================
# ESTRUCTURA
# =====================================================================
Write-Host ''
Write-Host "  --- Estructura ---" -ForegroundColor Yellow

Test-Check -Name "1. Los 10 esquemas existen" -Query @'
SELECT Faltantes = STRING_AGG(s.Nombre, ', ')
FROM (VALUES ('sec'),('org'),('lms'),('asmt'),('dlv'),('comp'),('aud'),('intg'),('ops'),('rpt')) s(Nombre)
WHERE NOT EXISTS (SELECT 1 FROM sys.schemas x WHERE x.name = s.Nombre);
'@ -Assert { param($r) -not $r.Faltantes } `
   -FailMessage "Esquemas faltantes. Revisar 01_schemas.sql"

Test-Check -Name "2. Conteo de tablas (>= 85)" -Query @'
SELECT Total = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND temporal_type <> 1;
'@ -Assert { param($r) $r.Total -ge 85 } `
   -FailMessage "Se esperaban al menos 85 tablas. Revisar 02-08."

Test-Check -Name "3. Tablas temporales versionadas (>= 4)" -Query @'
SELECT Total = COUNT(*), Tablas = STRING_AGG(SCHEMA_NAME(schema_id) + '.' + name, ', ')
FROM sys.tables WHERE temporal_type = 2;
'@ -Assert { param($r) $r.Total -ge 4 } `
   -FailMessage "Faltan tablas temporales. Sin ellas no se puede responder 'como estabamos el 12 de marzo'."

Test-Check -Name "4. Vistas rpt (12)" -Query @'
SELECT Total = COUNT(*) FROM sys.views v
JOIN sys.schemas s ON s.schema_id = v.schema_id WHERE s.name = 'rpt';
'@ -Assert { param($r) $r.Total -ge 12 } `
   -FailMessage "Faltan vistas de reporting. Revisar 10_views_reporting.sql"

Test-Check -Name "5. Funciones (7)" -Query @'
SELECT Total = COUNT(*) FROM sys.objects WHERE type IN ('FN','IF','TF') AND is_ms_shipped = 0;
'@ -Assert { param($r) $r.Total -ge 7 } `
   -FailMessage "Faltan funciones. Las vistas rpt dependen de ellas."

Test-Check -Name "6. Stored procedures (>= 180)" -Query @'
SELECT  Total = COUNT(*)
      , PorEsquema = STRING_AGG(x.Detalle, ' | ')
FROM (SELECT Detalle = s.name + '=' + CAST(COUNT(*) AS NVARCHAR(10))
      FROM sys.procedures p JOIN sys.schemas s ON s.schema_id = p.schema_id
      GROUP BY s.name) x
CROSS JOIN sys.procedures;
'@ -Assert { param($r) $r.Total -ge 180 } `
   -FailMessage "Faltan stored procedures. Revisar 11-18."

Test-Check -Name "7. Tipos tabla (TVP) definidos" -Query @'
SELECT Faltantes = STRING_AGG(t.Nombre, ', ')
FROM (VALUES ('IntListType'),('StringListType'),('EnrollmentRequestType'),
             ('AnswerType'),('CriterionResultType')) t(Nombre)
WHERE NOT EXISTS (SELECT 1 FROM sys.table_types tt WHERE tt.name = t.Nombre);
'@ -Assert { param($r) -not $r.Faltantes } `
   -FailMessage "Faltan tipos tabla. Los SPs de carga masiva no compilan sin ellos."

# =====================================================================
# SEGURIDAD - la parte que de verdad importa
# =====================================================================
Write-Host ''
Write-Host "  --- Seguridad (REGLA CERO) ---" -ForegroundColor Yellow

Test-Check -Name "8. AlLmsAppUser sin acceso directo a tablas" -Query @'
/* Este es EL control del sistema. Si el usuario de aplicacion puede
   hacer SELECT o UPDATE sobre una tabla, toda la arquitectura de firmas
   y auditoria es decorativa: basta un UPDATE para falsificar una
   certificacion sin dejar rastro. */
SELECT  Violaciones = COUNT(*)
      , Detalle = STRING_AGG(
            CAST(dp.permission_name + ' sobre ' + SCHEMA_NAME(o.schema_id) + '.' + o.name AS NVARCHAR(MAX)), '; ')
FROM sys.database_permissions dp
JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
LEFT JOIN sys.objects o ON o.object_id = dp.major_id
WHERE pr.name = 'AlLmsAppUser'
  AND dp.state_desc = 'GRANT'
  AND dp.permission_name IN ('SELECT','INSERT','UPDATE','DELETE')
  AND (o.type IN ('U','V') OR dp.class_desc = 'SCHEMA');
'@ -Assert { param($r) $r.Violaciones -eq 0 } `
   -FailMessage "AlLmsAppUser tiene acceso directo a tablas o vistas. Esto rompe la REGLA CERO: revisar 00_setup_database_roles.sql"

Test-Check -Name "9. AlLmsAppUser tiene EXECUTE" -Query @'
SELECT  TienePermiso = CASE WHEN COUNT(*) > 0 THEN 1 ELSE 0 END
FROM sys.database_permissions dp
JOIN sys.database_principals pr ON pr.principal_id = dp.grantee_principal_id
WHERE pr.name = 'AlLmsAppUser'
  AND dp.state_desc = 'GRANT' AND dp.permission_name = 'EXECUTE';
'@ -Assert { param($r) $r.TienePermiso -eq 1 } `
   -FailMessage "AlLmsAppUser no tiene EXECUTE: la aplicacion no puede hacer nada."

Test-Check -Name "10. Los 3 principals existen" -Query @'
SELECT Faltantes = STRING_AGG(u.Nombre, ', ')
FROM (VALUES ('AlLmsAppUser'),('AlLmsSyncUser'),('AlLmsReportUser')) u(Nombre)
WHERE NOT EXISTS (SELECT 1 FROM sys.database_principals p WHERE p.name = u.Nombre);
'@ -Assert { param($r) -not $r.Faltantes } `
   -FailMessage "Faltan principals de base de datos."

# =====================================================================
# INTEGRIDAD
# =====================================================================
Write-Host ''
Write-Host "  --- Integridad ---" -ForegroundColor Yellow

Test-Check -Name "11. Seed de referencia cargado" -Query @'
SELECT  Permisos  = (SELECT COUNT(*) FROM sec.Permission)
      , Roles     = (SELECT COUNT(*) FROM sec.Role)
      , RolPerm   = (SELECT COUNT(*) FROM sec.RolePermission)
      , Settings  = (SELECT COUNT(*) FROM ops.Setting)
      , Flags     = (SELECT COUNT(*) FROM ops.FeatureFlag)
      , Plantillas= (SELECT COUNT(*) FROM ops.NotificationTemplate);
'@ -Assert { param($r) $r.Permisos -ge 40 -and $r.Roles -ge 7 -and $r.Plantillas -ge 12 } `
   -FailMessage "El seed no cargo completo. Ejecutar 99_seed_reference_data.sql"

Test-Check -Name "12. Sin SPs rotos (referencias invalidas)" -Query @'
/* sys.sql_expression_dependencies detecta SPs que referencian objetos
   inexistentes. SQL Server los deja crear (deferred name resolution),
   asi que sin esta comprobacion el error aparece en produccion. */
SELECT  Rotos = COUNT(DISTINCT OBJECT_NAME(d.referencing_id))
      , Detalle = STRING_AGG(CAST(
            OBJECT_SCHEMA_NAME(d.referencing_id) + '.' + OBJECT_NAME(d.referencing_id)
            + ' -> ' + ISNULL(d.referenced_schema_name, '?') + '.' + d.referenced_entity_name
            AS NVARCHAR(MAX)), '; ')
FROM sys.sql_expression_dependencies d
WHERE d.referenced_id IS NULL
  AND d.is_ambiguous = 0
  AND d.referenced_server_name IS NULL
  AND d.referenced_database_name IS NULL
  AND OBJECTPROPERTY(d.referencing_id, 'IsProcedure') = 1;
'@ -Assert { param($r) $r.Rotos -eq 0 } `
   -FailMessage "Hay SPs referenciando objetos que no existen. Verificar el orden de despliegue (18 va antes de 11-17)."

Test-Check -Name "13. Cadena de firmas intacta" -Query @'
/* Si ya hay firmas, se verifica que ninguna fue alterada. En una base
   recien desplegada esto devuelve cero filas, que es correcto. */
SELECT  Firmas = COUNT(*)
      , Alteradas = SUM(CASE WHEN HASHBYTES('SHA2_256', PayloadCanonical) <> PayloadHash THEN 1 ELSE 0 END)
FROM aud.SignatureRecord;
'@ -Assert { param($r) ($null -eq $r.Alteradas) -or ($r.Alteradas -eq 0) } `
   -FailMessage "HAY FIRMAS ALTERADAS. Alguien modifico la base por fuera de la aplicacion. Investigar antes de continuar."

Test-Check -Name "14. Gating.Enforce apagado" -Query @'
SELECT Encendido = ISNULL((SELECT CAST(IsEnabled AS INT) FROM ops.FeatureFlag WHERE FlagKey = 'Gating.Enforce'), 0);
'@ -Assert { param($r) $r.Encendido -eq 0 } `
   -WarnOnly `
   -FailMessage "Gating.Enforce esta ENCENDIDO. Si no validaste antes el modo Shadow, vas a bloquear gente en el piso por datos sucios."

Test-Check -Name "15. Placeholders de Entra ID reemplazados" -Query @'
SELECT Placeholders = COUNT(*) FROM sec.RoleGroupMapping
WHERE ExternalGroupId LIKE '00000000-0000-0000-0000-%';
'@ -Assert { param($r) $r.Placeholders -eq 0 } `
   -WarnOnly `
   -FailMessage "sec.RoleGroupMapping todavia tiene GUID placeholder. Nadie recibira roles por grupo de Entra ID hasta reemplazarlos."

# =====================================================================
# Resumen
# =====================================================================
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host "  Resultado: $script:Pass OK / $script:Warn avisos / $script:Fail fallos" -ForegroundColor Cyan
Write-Host ('=' * 70) -ForegroundColor Cyan
Write-Host ''

if ($script:Fail -gt 0) {
    Write-Host "  Verificacion FALLIDA. No desplegar la aplicacion contra esta base." -ForegroundColor Red
    Write-Host ''
    exit 1
}
elseif ($script:Warn -gt 0) {
    Write-Host "  Verificacion con avisos. Revisar antes de ir a produccion." -ForegroundColor Yellow
    Write-Host ''
    exit 2
}
else {
    Write-Host "  Base de datos lista." -ForegroundColor Green
    Write-Host ''
    exit 0
}
