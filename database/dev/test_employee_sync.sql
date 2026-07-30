/* =====================================================================
   Prueba E2E: sincronizacion de empleados SPN -> AIRLINK_KMS
   Consume el procedure REAL de lectura (dbo.usp_KMS_Employee_GetForSync,
   creado por database/remote/spn_setup.sql) — el mismo contrato que en
   el servidor de produccion. Cross-db local = patron linked-server.
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

/* Departamentos: mismos nombres que dbo.Departamento[Descripcion] en SPN,
   para que el sync los resuelva por nombre. */
INSERT INTO org.Department (SiteId, DepartmentCode, [Name])
SELECT @SiteId, d.Code, d.Nombre
FROM (VALUES (N'PROD', N'Produccion'), (N'CAL', N'Calidad')
           , (N'OPS', N'Operaciones'), (N'RRHH', N'Recursos Humanos')) d (Code, Nombre)
WHERE NOT EXISTS (SELECT 1 FROM org.Department x WHERE x.[Name] = d.Nombre);

PRINT '--- [1] Full sync usando el procedure REAL de SPN ---';
DECLARE @Json NVARCHAR(MAX);
CREATE TABLE #spn (EmployeesJson NVARCHAR(MAX));
INSERT INTO #spn EXEC SPN.dbo.usp_KMS_Employee_GetForSync;
SELECT @Json = EmployeesJson FROM #spn;
DROP TABLE #spn;

DECLARE @RunId BIGINT;
EXEC intg.usp_EmployeeSync_Run @RunMode = 2, @EmployeesJson = @Json, @TriggeredBy = N'TestE2E', @SyncRunId = @RunId OUTPUT;

PRINT '--- [2] Resultado de la corrida ---';
SELECT SyncRunId, RunMode, [Status], RowsRead, RowsInserted, RowsUpdated, RowsSkipped, RowsErrored, DurationMs
FROM intg.SyncRun WHERE SyncRunId = @RunId;

PRINT '--- [3] Empleados en el KMS (DR0112 debe quedar INACTIVO) ---';
SELECT EmployeeCode, FirstName, LastName, NationalIdMasked, IsActive
     , (SELECT [Name] FROM org.Department d WHERE d.DepartmentId = e.DepartmentId) AS Departamento
FROM org.Employee e ORDER BY EmployeeCode;

PRINT '--- [4] Posiciones desde dbo.Posiciones[Descripcion] ---';
SELECT PositionCode, [Name], RequiresReview FROM org.[Position] WHERE IsMappedFromSource = 1 ORDER BY PositionCode;

PRINT '--- [5] Jerarquia de supervisores resuelta ---';
SELECT e.EmployeeCode, e.FullName, sup.EmployeeCode AS SupervisorCode
FROM org.Employee e
LEFT JOIN org.Employee sup ON sup.EmployeeId = e.SupervisorEmployeeId
WHERE e.IsActive = 1 ORDER BY e.EmployeeCode;

PRINT '--- [6] Re-corrida identica: todo debe saltarse (hash) ---';
CREATE TABLE #spn2 (EmployeesJson NVARCHAR(MAX));
INSERT INTO #spn2 EXEC SPN.dbo.usp_KMS_Employee_GetForSync;
SELECT @Json = EmployeesJson FROM #spn2;
DROP TABLE #spn2;

DECLARE @RunId2 BIGINT;
EXEC intg.usp_EmployeeSync_Run @RunMode = 2, @EmployeesJson = @Json, @TriggeredBy = N'TestE2E-Rerun', @SyncRunId = @RunId2 OUTPUT;
SELECT SyncRunId, RowsRead, RowsInserted, RowsUpdated, RowsSkipped FROM intg.SyncRun WHERE SyncRunId = @RunId2;

PRINT '--- [7] Baja en SPN: DR0110 pasa a Estatus T (no puede entrar) ---';
UPDATE SPN.dbo.Empleados SET Estatus = N'T' WHERE codigo = N'DR0110';

CREATE TABLE #spn3 (EmployeesJson NVARCHAR(MAX));
INSERT INTO #spn3 EXEC SPN.dbo.usp_KMS_Employee_GetForSync;
SELECT @Json = EmployeesJson FROM #spn3;
DROP TABLE #spn3;

DECLARE @RunId3 BIGINT;
EXEC intg.usp_EmployeeSync_Run @RunMode = 2, @EmployeesJson = @Json, @TriggeredBy = N'TestE2E-Baja', @SyncRunId = @RunId3 OUTPUT;
SELECT EmployeeCode, FullName, IsActive FROM org.Employee WHERE EmployeeCode = N'DR0110';
SELECT u.UserName, u.IsActive AS UsuarioActivo FROM sec.[User] u
JOIN org.Employee e ON e.EmployeeId = u.EmployeeId WHERE e.EmployeeCode = N'DR0110';

PRINT '--- [8] Reingreso: DR0110 vuelve a A (historia intacta) ---';
UPDATE SPN.dbo.Empleados SET Estatus = N'A' WHERE codigo = N'DR0110';

CREATE TABLE #spn4 (EmployeesJson NVARCHAR(MAX));
INSERT INTO #spn4 EXEC SPN.dbo.usp_KMS_Employee_GetForSync;
SELECT @Json = EmployeesJson FROM #spn4;
DROP TABLE #spn4;

DECLARE @RunId4 BIGINT;
EXEC intg.usp_EmployeeSync_Run @RunMode = 2, @EmployeesJson = @Json, @TriggeredBy = N'TestE2E-Reingreso', @SyncRunId = @RunId4 OUTPUT;
SELECT EmployeeCode, FullName, IsActive FROM org.Employee WHERE EmployeeCode = N'DR0110';
GO
