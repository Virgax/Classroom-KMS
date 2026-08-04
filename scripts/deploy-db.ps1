<#
.SYNOPSIS
    Despliega el esquema de Classroom - LMS by Airlink en SQL Server.

.DESCRIPTION
    Ejecuta los scripts de database/ en ORDEN DE DEPENDENCIA, que no es el
    orden numerico. La diferencia importa:

      18_procs_platform.sql se ejecuta ANTES que 11-17.

    Motivo: todos los SPs de negocio llaman a aud.usp_Error_Log,
    aud.usp_Event_Log, aud.usp_Signature_Create y ops.usp_Notification_Enqueue.
    SQL Server permite compilar un SP que referencia otro inexistente
    (deferred name resolution), asi que el deploy no falla en el momento,
    pero el primer error real en produccion revienta dentro del CATCH al
    intentar loguear. Eso es peor que fallar en el deploy: enmascara el
    error original.

    El script es idempotente. Todos los objetos usan CREATE OR ALTER y el
    seed usa MERGE. Se puede re-ejecutar sobre una base existente.

.PARAMETER Server
    Instancia SQL Server. Formato host,puerto para puertos no estandar.
    Ej: 192.168.181.248,13999

.PARAMETER Database
    Base de datos destino. Default: AIRLINK_LMS

.PARAMETER Credential
    PSCredential para autenticacion SQL. Si se omite, usa autenticacion
    integrada de Windows.

    NUNCA pasar la contrasena como texto plano en la linea de comandos:
    queda en el historial de PowerShell y en los logs del proceso.

.PARAMETER SkipJobs
    Omite 19_jobs_agent.sql. Usar en entornos sin SQL Server Agent
    (contenedores de desarrollo, SQL Express).

.PARAMETER SkipSeed
    Omite 99_seed_reference_data.sql.

.PARAMETER WhatIf
    Muestra el plan de ejecucion sin tocar la base.

.EXAMPLE
    # Desarrollo, autenticacion integrada
    .\deploy-db.ps1 -Server "localhost" -Database "AIRLINK_LMS_DEV"

.EXAMPLE
    # Produccion, credenciales desde Key Vault
    $cred = Get-Credential -UserName "deploy_user"
    .\deploy-db.ps1 -Server "192.168.181.248,13999" -Credential $cred

.EXAMPLE
    # Ver que se haria, sin hacerlo
    .\deploy-db.ps1 -Server "localhost" -WhatIf

.NOTES
    Requiere el modulo SqlServer:  Install-Module -Name SqlServer -Scope CurrentUser
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string] $Server,

    [Parameter()]
    [string] $Database = 'AIRLINK_KMS',

    [Parameter()]
    [System.Management.Automation.PSCredential] $Credential,

    [Parameter()]
    [switch] $SkipJobs,

    [Parameter()]
    [switch] $SkipSeed,

    [Parameter()]
    [int] $QueryTimeout = 300
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------------
# Orden de ejecucion. NO reordenar sin entender por que esta asi.
# ---------------------------------------------------------------------
$ExecutionPlan = @(
    # --- Fase 1: estructura -------------------------------------------
    @{ File = '00_setup_database_roles.sql'; Phase = 'Estructura'; Note = 'DB, logins, roles, DENY explicitos' }
    @{ File = '01_schemas.sql';              Phase = 'Estructura'; Note = 'Esquemas y tipos tabla (TVP)' }

    # --- Fase 2: tablas -----------------------------------------------
    @{ File = '02_tables_core.sql';          Phase = 'Tablas'; Note = 'sec + org' }
    @{ File = '03_tables_catalog.sql';       Phase = 'Tablas'; Note = 'cursos, versiones, programas' }
    @{ File = '04_tables_content.sql';       Phase = 'Tablas'; Note = 'modulos, items, paginas, i18n' }
    @{ File = '05_tables_assessment.sql';    Phase = 'Tablas'; Note = 'bancos, quizzes, intentos, rubricas' }
    @{ File = '06_tables_delivery.sql';      Phase = 'Tablas'; Note = 'inscripciones, progreso, ILT' }
    @{ File = '07_tables_compliance.sql';    Phase = 'Tablas'; Note = 'competencias, requisitos, certificaciones' }
    @{ File = '08_tables_platform.sql';      Phase = 'Tablas'; Note = 'audit, firmas, notificaciones, integracion' }

    # --- Fase 3: funciones antes que vistas ---------------------------
    #   Las vistas rpt llaman a comp.fn_HasActiveWaiver y a
    #   comp.fn_GetCertificationStatus. Al reves, fallan al crearse.
    @{ File = '09_functions.sql';            Phase = 'Programabilidad'; Note = 'funciones escalares y TVF' }
    @{ File = '10_views_reporting.sql';      Phase = 'Programabilidad'; Note = 'vistas rpt (dependen de 09)' }

    # --- Fase 4: PLATAFORMA PRIMERO -----------------------------------
    #   Fuera de orden numerico a proposito. Ver el bloque .DESCRIPTION.
    @{ File = '18_procs_platform.sql';       Phase = 'Procedimientos'
       Note = 'aud + ops. Dependencia de TODO lo demas: se despliega antes' }

    # --- Fase 5: procedimientos de negocio ----------------------------
    @{ File = '11_procs_identity.sql';       Phase = 'Procedimientos'; Note = 'sec + org' }
    @{ File = '12_procs_catalog_content.sql';Phase = 'Procedimientos'; Note = 'lms' }
    @{ File = '13_procs_delivery_progress.sql'; Phase = 'Procedimientos'; Note = 'dlv' }
    @{ File = '14_procs_assessment.sql';     Phase = 'Procedimientos'; Note = 'asmt' }
    @{ File = '15_procs_compliance.sql';     Phase = 'Procedimientos'; Note = 'comp - el motor de compliance' }
    @{ File = '16_procs_reporting.sql';      Phase = 'Procedimientos'; Note = 'rpt' }
    @{ File = '17_procs_integration.sql';    Phase = 'Procedimientos'; Note = 'intg - sync SPN' }

    # --- Fase 6: datos y jobs -----------------------------------------
    @{ File = '99_seed_reference_data.sql';  Phase = 'Datos';  Note = 'permisos, roles, settings, plantillas'; Skippable = 'Seed' }
    @{ File = '19_jobs_agent.sql';           Phase = 'Agent';  Note = 'los 7 jobs programados'; Skippable = 'Jobs' }
)

# ---------------------------------------------------------------------
# Preparacion
# ---------------------------------------------------------------------
$RepoRoot    = Split-Path -Parent $PSScriptRoot
$DatabaseDir = Join-Path $RepoRoot 'database'

if (-not (Test-Path $DatabaseDir)) {
    throw "No se encontro la carpeta database/ en '$RepoRoot'. Ejecuta el script desde scripts/."
}

if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    throw "Falta el modulo SqlServer. Instalar con: Install-Module -Name SqlServer -Scope CurrentUser"
}
Import-Module SqlServer -DisableNameChecking

# Validar que existan todos los archivos ANTES de tocar la base.
# Fallar a mitad del deploy deja el esquema inconsistente.
$missing = @()
foreach ($step in $ExecutionPlan) {
    $path = Join-Path $DatabaseDir $step.File
    if (-not (Test-Path $path)) { $missing += $step.File }
}
if ($missing.Count -gt 0) {
    throw "Faltan archivos en database/:`n  - $($missing -join "`n  - ")"
}

$connArgs = @{
    ServerInstance = $Server
    QueryTimeout   = $QueryTimeout
    ErrorAction    = 'Stop'
}
if ($Credential) { $connArgs['Credential'] = $Credential }

function Write-Banner {
    param([string] $Text, [string] $Color = 'Cyan')
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host ('=' * 70) -ForegroundColor $Color
}

Write-Banner "Classroom - LMS by Airlink | Despliegue de base de datos"
Write-Host "  Servidor : $Server"
Write-Host "  Base     : $Database"
Write-Host "  Auth     : $(if ($Credential) { "SQL ($($Credential.UserName))" } else { 'Integrada (Windows)' })"
Write-Host "  Pasos    : $($ExecutionPlan.Count)"
Write-Host ''

# ---------------------------------------------------------------------
# Verificacion de conectividad
# ---------------------------------------------------------------------
try {
    $ver = Invoke-Sqlcmd @connArgs -Database 'master' -Query @'
SELECT  ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(50))
      , Edition        = CAST(SERVERPROPERTY('Edition') AS NVARCHAR(100))
      , LoginName      = SUSER_SNAME();
'@
    Write-Host "  Conectado: SQL Server $($ver.ProductVersion) - $($ver.Edition)" -ForegroundColor Green
    Write-Host "  Login    : $($ver.LoginName)" -ForegroundColor Green

    # Temporal tables (CompetencyRequirement, Certification, Enrollment...)
    # requieren SQL Server 2016 o superior.
    $major = [int]($ver.ProductVersion -split '\.')[0]
    if ($major -lt 13) {
        throw "Se requiere SQL Server 2016 (13.x) o superior. Detectado: $($ver.ProductVersion). Las tablas temporales del sistema no existen antes de 2016."
    }
}
catch {
    Write-Host "  No se pudo conectar a '$Server'." -ForegroundColor Red
    throw
}

# ---------------------------------------------------------------------
# Ejecucion
# ---------------------------------------------------------------------
$results   = @()
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$stepNo    = 0
$lastPhase = ''

foreach ($step in $ExecutionPlan) {

    $stepNo++
    $file = $step.File
    $path = Join-Path $DatabaseDir $file

    # Saltos solicitados
    if ($step.ContainsKey('Skippable')) {
        if ($step.Skippable -eq 'Jobs' -and $SkipJobs) {
            Write-Host ("  [{0,2}/{1}] {2,-34} OMITIDO (-SkipJobs)" -f $stepNo, $ExecutionPlan.Count, $file) -ForegroundColor DarkGray
            $results += [pscustomobject]@{ Step = $stepNo; File = $file; Status = 'Omitido'; Seconds = 0 }
            continue
        }
        if ($step.Skippable -eq 'Seed' -and $SkipSeed) {
            Write-Host ("  [{0,2}/{1}] {2,-34} OMITIDO (-SkipSeed)" -f $stepNo, $ExecutionPlan.Count, $file) -ForegroundColor DarkGray
            $results += [pscustomobject]@{ Step = $stepNo; File = $file; Status = 'Omitido'; Seconds = 0 }
            continue
        }
    }

    if ($step.Phase -ne $lastPhase) {
        Write-Host ''
        Write-Host "  --- $($step.Phase) ---" -ForegroundColor Yellow
        $lastPhase = $step.Phase
    }

    # 00 crea la base y 19 corre contra msdb: ambos entran por master.
    $targetDb = switch ($file) {
        '00_setup_database_roles.sql' { 'master' }
        '19_jobs_agent.sql'           { 'master' }
        default                       { $Database }
    }

    if (-not $PSCmdlet.ShouldProcess("$Server/$targetDb", "Ejecutar $file")) {
        Write-Host ("  [{0,2}/{1}] {2,-34} (WhatIf) {3}" -f $stepNo, $ExecutionPlan.Count, $file, $step.Note) -ForegroundColor DarkGray
        continue
    }

    Write-Host ("  [{0,2}/{1}] {2,-34} " -f $stepNo, $ExecutionPlan.Count, $file) -NoNewline

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-Sqlcmd @connArgs `
            -Database $targetDb `
            -InputFile $path `
            -Verbose:$false 4>$null

        $sw.Stop()
        Write-Host ("OK  ({0,5:N1}s)  {1}" -f $sw.Elapsed.TotalSeconds, $step.Note) -ForegroundColor Green
        $results += [pscustomobject]@{
            Step = $stepNo; File = $file; Status = 'OK'
            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
    }
    catch {
        $sw.Stop()
        Write-Host "FALLO" -ForegroundColor Red
        Write-Host ''
        Write-Host "  Archivo : $file" -ForegroundColor Red
        Write-Host "  Base    : $targetDb" -ForegroundColor Red
        Write-Host "  Error   : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        Write-Host "  El despliegue se detuvo. La base quedo a medio aplicar." -ForegroundColor Yellow
        Write-Host "  Corrige el error y vuelve a ejecutar: los scripts son idempotentes," -ForegroundColor Yellow
        Write-Host "  asi que re-correr desde el inicio es seguro." -ForegroundColor Yellow

        $results += [pscustomobject]@{
            Step = $stepNo; File = $file; Status = 'FALLO'
            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }

        Write-Banner "DESPLIEGUE FALLIDO" 'Red'
        $results | Format-Table -AutoSize
        exit 1
    }
}

$stopwatch.Stop()

# ---------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------
if ($WhatIfPreference) {
    Write-Banner "Plan mostrado (WhatIf). No se modifico nada." 'Yellow'
    exit 0
}

Write-Banner "DESPLIEGUE COMPLETADO" 'Green'
Write-Host "  Tiempo total: $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s"
Write-Host ''
$results | Format-Table -AutoSize

# Conteo de objetos como verificacion rapida
try {
    $counts = Invoke-Sqlcmd @connArgs -Database $Database -Query @'
SELECT  Tablas       = (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND temporal_type <> 1)
      , Temporales   = (SELECT COUNT(*) FROM sys.tables WHERE temporal_type = 2)
      , Vistas       = (SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0)
      , Funciones    = (SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN','IF','TF'))
      , Procedimientos = (SELECT COUNT(*) FROM sys.procedures)
      , Permisos     = (SELECT COUNT(*) FROM sec.Permission)
      , Roles        = (SELECT COUNT(*) FROM sec.Role);
'@
    Write-Host "  Objetos creados:" -ForegroundColor Cyan
    $counts | Format-List
}
catch {
    Write-Host "  (No se pudo leer el conteo de objetos: $($_.Exception.Message))" -ForegroundColor DarkGray
}

Write-Host "  Siguiente paso: .\verify-db.ps1 -Server '$Server' -Database '$Database'" -ForegroundColor Cyan
Write-Host ''
Write-Host "  Recordatorios de despliegue:" -ForegroundColor Yellow
Write-Host "    1. Reemplazar las contrasenas placeholder de los 3 logins en 00_setup_database_roles.sql"
Write-Host "    2. Reemplazar los GUID placeholder de sec.RoleGroupMapping con los ObjectId reales de Entra ID"
Write-Host "    3. Ajustar @owner_login_name de los jobs a la cuenta de servicio (no 'sa')"
Write-Host "    4. Gating.Enforce queda APAGADO. Encenderlo solo tras validar el modo Shadow."
Write-Host ''
