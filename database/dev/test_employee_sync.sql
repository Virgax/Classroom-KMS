/* =====================================================================
   Prueba E2E: sincronizacion de empleados SPN -> AIRLINK_KMS
   Simula el patron linked-server: misma instancia, cross-database.
   ===================================================================== */
USE AIRLINK_KMS;
GO
SET NOCOUNT ON;

/* --- 0. Minimo organizacional: organizacion, sede y departamentos ---- */
IF NOT EXISTS (SELECT 1 FROM org.Organization WHERE OrganizationCode = N'AIRLINK')
    INSERT INTO org.Organization (OrganizationCode, [Name], LegalName)
    VALUES (N'AIRLINK', N'Airlink Distribution DR', N'Airlink Distribution DR SRL');

DECLARE @OrgId INT = (SELECT OrganizationId FROM org.Organization WHERE OrganizationCode = N'AIRLINK');

IF NOT EXISTS (SELECT 1 FROM org.Site WHERE SiteCode = N'SDQ')
    INSERT INTO org.Site (OrganizationId, SiteCode, [Name], City)
    VALUES (@OrgId, N'SDQ', N'Santo Domingo', N'Santo Domingo');

DECLARE @SiteId INT = (SELECT SiteId FROM org.Site WHERE SiteCode = N'SDQ');

INSERT INTO org.Department (SiteId, DepartmentCode, [Name])
SELECT @SiteId, d.Code, d.Nombre
FROM (VALUES (N'PROD', N'Produccion'), (N'CAL', N'Calidad')
           , (N'OPS', N'Operaciones'), (N'RRHH', N'Recursos Humanos')) d (Code, Nombre)
WHERE NOT EXISTS (SELECT 1 FROM org.Department x WHERE x.[Name] = d.Nombre);

PRINT '--- [1] Full sync desde SPN ---';

/* --- 1. Leer SPN (cross-db = linked server local) y correr el sync --- */
DECLARE @Json NVARCHAR(MAX) = (
    SELECT  e.Codigo          AS employeeCode
          , e.Nombre          AS firstName
          , e.Apellidos       AS lastName
          , e.Cedula          AS nationalId
          , e.Correo          AS email
          , e.Puesto          AS positionTitle
          , e.Departamento    AS department
          , e.Sede            AS site
          , e.CodigoSupervisor AS supervisorCode
          , e.FechaIngreso    AS hireDate
          , e.FechaSalida     AS terminationDate
          , e.Estatus         AS employmentStatus
    FROM SPN.dbo.Empleado e
    FOR JSON PATH);

DECLARE @RunId BIGINT;
EXEC intg.usp_EmployeeSync_Run @RunMode = 2, @EmployeesJson = @Json, @TriggeredBy = N'TestE2E', @SyncRunId = @RunId OUTPUT;

PRINT '--- [2] Resultado de la corrida ---';
SELECT SyncRunId, RunMode, [Status], RowsRead, RowsInserted, RowsUpdated, RowsSkipped, RowsErrored, DurationMs
FROM intg.SyncRun WHERE SyncRunId = @RunId;

PRINT '--- [3] Empleados en el KMS (sync desde nomina) ---';
SELECT EmployeeCode, FirstName, LastName, NationalIdMasked, IsActive
     , (SELECT [Name] FROM org.Department d WHERE d.DepartmentId = e.DepartmentId) AS Departamento
FROM org.Employee e ORDER BY EmployeeCode;

PRINT '--- [4] Posiciones auto-creadas desde SPN (RequiresReview=1) ---';
SELECT PositionCode, [Name], RequiresReview FROM org.[Position] WHERE IsMappedFromSource = 1 ORDER BY PositionCode;

PRINT '--- [5] Errores de integracion abiertos ---';
SELECT SourceKey, ErrorCode, ErrorMessage FROM intg.IntegrationError WHERE IsResolved = 0;

PRINT '--- [6] Segunda corrida identica: todo debe saltarse (hash) ---';
DECLARE @RunId2 BIGINT;
EXEC intg.usp_EmployeeSync_Run @RunMode = 2, @EmployeesJson = @Json, @TriggeredBy = N'TestE2E-Rerun', @SyncRunId = @RunId2 OUTPUT;
SELECT SyncRunId, RowsRead, RowsInserted, RowsUpdated, RowsSkipped FROM intg.SyncRun WHERE SyncRunId = @RunId2;

PRINT '--- [7] Baja en SPN: AL-0112 sale de la empresa ---';
UPDATE SPN.dbo.Empleado SET Estatus = N'TERMINADO', FechaSalida = CAST(GETDATE() AS DATE) WHERE Codigo = N'AL-0112';

DECLARE @Json3 NVARCHAR(MAX) = (
    SELECT  e.Codigo AS employeeCode, e.Nombre AS firstName, e.Apellidos AS lastName
          , e.Cedula AS nationalId, e.Correo AS email, e.Puesto AS positionTitle
          , e.Departamento AS department, e.Sede AS site, e.CodigoSupervisor AS supervisorCode
          , e.FechaIngreso AS hireDate, e.FechaSalida AS terminationDate, e.Estatus AS employmentStatus
    FROM SPN.dbo.Empleado e FOR JSON PATH);

DECLARE @RunId3 BIGINT;
EXEC intg.usp_EmployeeSync_Run @RunMode = 2, @EmployeesJson = @Json3, @TriggeredBy = N'TestE2E-Baja', @SyncRunId = @RunId3 OUTPUT;

SELECT EmployeeCode, FirstName, LastName, IsActive, TerminationDateUtc
FROM org.Employee WHERE EmployeeCode = N'AL-0112';

PRINT '--- [8] Bitacora de eventos del sync ---';
SELECT TOP (5) [Action], Severity, [Description], OccurredAtUtc FROM aud.EventLog ORDER BY EventLogId DESC;
GO
