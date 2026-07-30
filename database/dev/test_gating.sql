/* =====================================================================
   Prueba E2E: AIRLINK -> estaciones -> requisitos -> brechas -> gating
   Escenario: Francisco (AL-0104) lleva semanas trabajando la estacion
   RXR-01 (IP68 test) segun AIRLINK, pero no tiene la certificacion.
   El sistema debe detectarlo ANTES que el auditor.

   Corre como sa (harness de prueba). Toda la logica va por SPs con el
   actor correcto: rperalta(1)=SYSTEM_ADMIN, Yokasta=QUALITY_APPROVER.
   ===================================================================== */
USE AIRLINK_KMS;
GO
SET NOCOUNT ON;
DECLARE @AdminUserId INT = (SELECT UserId FROM sec.[User] WHERE UserName = N'rperalta');

PRINT '--- [1] Usuaria de Calidad: Yokasta (QUALITY_APPROVER) ---';
DECLARE @QaUserId INT = (SELECT UserId FROM sec.[User] WHERE UserName = N'yminaya');
IF @QaUserId IS NULL
BEGIN
    DECLARE @YokEmpId INT = (SELECT EmployeeId FROM org.Employee WHERE EmployeeCode = N'AL-0003');
    EXEC sec.usp_User_Create @ActorUserId = @AdminUserId, @EmployeeId = @YokEmpId
       , @UserName = N'yminaya', @DisplayName = N'Yokasta Minaya'
       , @Email = N'yminaya@airlink.com.do', @UserId = @QaUserId OUTPUT;
END;
DECLARE @QaRoleId INT = (SELECT RoleId FROM sec.Role WHERE RoleCode = N'QUALITY_APPROVER');
IF NOT EXISTS (SELECT 1 FROM sec.UserRoleAssignment
               WHERE UserId = @QaUserId AND RoleId = @QaRoleId AND IsActive = 1 AND RevokedAtUtc IS NULL)
    EXEC sec.usp_UserRole_Assign @ActorUserId = @AdminUserId, @UserId = @QaUserId, @RoleId = @QaRoleId;
SELECT u.UserId, u.UserName, r.RoleCode
FROM sec.[User] u
JOIN sec.UserRoleAssignment ra ON ra.UserId = u.UserId AND ra.IsActive = 1
JOIN sec.Role r ON r.RoleId = ra.RoleId
WHERE u.UserName = N'yminaya';

PRINT '--- [2] Area TESTING + sync de estaciones desde AIRLINK ---';
DECLARE @DeptProd INT = (SELECT DepartmentId FROM org.Department WHERE [Name] = N'Produccion');
IF NOT EXISTS (SELECT 1 FROM org.Area WHERE AreaCode = N'TESTING')
    INSERT INTO org.Area (DepartmentId, AreaCode, [Name], AreaType) VALUES (@DeptProd, N'TESTING', N'Linea de Testing', 1);
IF NOT EXISTS (SELECT 1 FROM org.Area WHERE AreaCode = N'CALIDAD')
    INSERT INTO org.Area (DepartmentId, AreaCode, [Name], AreaType) VALUES (@DeptProd, N'CALIDAD', N'Linea de Calidad', 2);
IF NOT EXISTS (SELECT 1 FROM org.Area WHERE AreaCode = N'REFURB')
    INSERT INTO org.Area (DepartmentId, AreaCode, [Name], AreaType) VALUES (@DeptProd, N'REFURB', N'Linea de Refurbishment', 1);
IF NOT EXISTS (SELECT 1 FROM org.Area WHERE AreaCode = N'EMPAQUE')
    INSERT INTO org.Area (DepartmentId, AreaCode, [Name], AreaType) VALUES (@DeptProd, N'EMPAQUE', N'Linea de Empaque', 1);

/* Sync del catalogo de estaciones (cross-db local = patron linked-server) */
DECLARE @Code NVARCHAR(40), @Nm NVARCHAR(150), @Proc NVARCHAR(40), @Eq NVARCHAR(150), @Linea NVARCHAR(50), @StId INT;
DECLARE stc CURSOR LOCAL FAST_FORWARD FOR
    SELECT Codigo, Nombre, Proceso, Equipo, Linea FROM AIRLINK.dbo.Estacion WHERE Activa = 1;
OPEN stc; FETCH NEXT FROM stc INTO @Code, @Nm, @Proc, @Eq, @Linea;
WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @AreaId INT = (SELECT AreaId FROM org.Area WHERE AreaCode = @Linea);
    /* RXR-* requiere gating (IP68 es proceso critico R2v3), en modo Shadow */
    DECLARE @Gating BIT = CASE WHEN @Proc = N'IP68-TEST' THEN 1 ELSE 0 END;
    EXEC org.usp_Station_Upsert @ActorUserId = @AdminUserId
       , @StationCode = @Code, @Name = @Nm, @AreaId = @AreaId
       , @ProcessCode = @Proc, @EquipmentName = @Eq
       , @RequiresGating = @Gating, @GatingMode = 1   /* 1=Shadow */
       , @ResultStationId = @StId OUTPUT;
    FETCH NEXT FROM stc INTO @Code, @Nm, @Proc, @Eq, @Linea;
END;
CLOSE stc; DEALLOCATE stc;
SELECT StationCode, [Name], ProcessCode, RequiresGating, GatingMode FROM org.Station ORDER BY StationCode;

PRINT '--- [3] Competencia IP68-ROXER-OP + niveles (actor: Calidad) ---';
SELECT @QaUserId = UserId FROM sec.[User] WHERE UserName = N'yminaya';
DECLARE @CompId INT = (SELECT CompetencyId FROM comp.Competency WHERE CompetencyCode = N'IP68-ROXER-OP');
IF @CompId IS NULL
BEGIN
    EXEC comp.usp_Competency_Create @ActorUserId = @QaUserId
       , @CompetencyCode = N'IP68-ROXER-OP', @NameEs = N'Operacion Roxer SmartRox (prueba IP68)'
       , @NameEn = N'Roxer SmartRox Operation (IP68 testing)', @CompetencyType = 1
       , @CompetencyId = @CompId OUTPUT;
    EXEC comp.usp_Competency_SetLevels @ActorUserId = @QaUserId, @CompetencyId = @CompId
       , @LevelsJson = N'[
            {"levelOrdinal":1,"levelCode":"Awareness","nameEs":"Conocimiento","nameEn":"Awareness"},
            {"levelOrdinal":2,"levelCode":"Basic","nameEs":"Basico","nameEn":"Basic"},
            {"levelOrdinal":3,"levelCode":"Competent","nameEs":"Competente","nameEn":"Competent"},
            {"levelOrdinal":4,"levelCode":"Advanced","nameEs":"Avanzado","nameEn":"Advanced"},
            {"levelOrdinal":5,"levelCode":"Trainer","nameEs":"Entrenador","nameEn":"Trainer","canEvaluate":true}]';
END;

PRINT '--- [4] Requisito CRITICO con scope de estacion RXR-01 ---';
DECLARE @ReqId INT = (SELECT RequirementId FROM comp.CompetencyRequirement WHERE RequirementCode = N'REQ-IP68-RXR01');
DECLARE @LevelCompetent INT = (SELECT CompetencyLevelId FROM comp.CompetencyLevel WHERE CompetencyId = @CompId AND LevelOrdinal = 3);
DECLARE @Rxr01 INT = (SELECT StationId FROM org.Station WHERE StationCode = N'RXR-01');
IF @ReqId IS NULL
BEGIN
    EXEC comp.usp_Requirement_Create @ActorUserId = @QaUserId
       , @RequirementCode = N'REQ-IP68-RXR01', @CompetencyId = @CompId
       , @MinimumLevelId = @LevelCompetent
       , @ScopeType = 4 /* Station */, @ScopeId = @Rxr01
       , @ValidityMonths = 12, @Criticality = 1 /* Critical */
       , @RegulatoryBasis = N'R2v3 Core 4 - FA4', @Status = 1
       , @RequirementId = @ReqId OUTPUT;

    DECLARE @StationReqJson NVARCHAR(MAX) =
        N'[{"requirementId":' + CAST(@ReqId AS NVARCHAR(12)) + N',"isBlocking":true}]';
    EXEC comp.usp_Station_SetRequirements @ActorUserId = @QaUserId
       , @StationId = @Rxr01, @RequirementsJson = @StationReqJson;
END;

PRINT '--- [5] Francisco asignado a RXR-01 (dispara recalculo de brechas) ---';
DECLARE @FranId INT = (SELECT EmployeeId FROM org.Employee WHERE EmployeeCode = N'AL-0104');
DECLARE @AreaTesting INT = (SELECT AreaId FROM org.Area WHERE AreaCode = N'TESTING');
EXEC org.usp_EmployeeAssignment_Set @ActorUserId = @AdminUserId
   , @EmployeeId = @FranId, @DepartmentId = @DeptProd
   , @AreaId = @AreaTesting, @StationId = @Rxr01, @ShiftCode = N'T1';

PRINT '--- [6] Brechas detectadas para Francisco ---';
SELECT g.GapType, g.Severity, g.RequiredLevelOrdinal, g.HasActiveWaiver, g.ResolvedAtUtc
     , r.RequirementCode
FROM comp.CompetencyGap g
JOIN comp.CompetencyRequirement r ON r.RequirementId = g.RequirementId
WHERE g.EmployeeId = @FranId;

PRINT '--- [7] Elegibilidad en RXR-01 (Shadow: registra, no bloquea) ---';
DECLARE @Decision TINYINT;
EXEC comp.usp_Eligibility_CheckEmployeeForStation
      @EmployeeCode = N'AL-0104', @StationCode = N'RXR-01'
    , @RequestSource = N'Nexus', @Decision = @Decision OUTPUT;
SELECT DecisionCodigo = @Decision;  /* 1=Allowed 2=AllowedWithSupervision 3=Blocked */

PRINT '--- [8] El hallazgo incomodo: AIRLINK dice que YA trabaja ahi ---';
EXEC AIRLINK.dbo.usp_KMS_ProductionHistory_GetForEmployee @CodigoEmpleado = N'AL-0104';

PRINT '--- [9] Waiver de emergencia: pide admin, aprueba Calidad (SoD) ---';
DECLARE @WaiverId INT = (SELECT WaiverId FROM comp.Waiver WHERE EmployeeId = @FranId AND RequirementId = @ReqId AND [Status] IN (1,2));
IF @WaiverId IS NULL
BEGIN
    DECLARE @WaiverExpires DATETIME2(3) = DATEADD(DAY, 30, SYSUTCDATETIME());
    EXEC comp.usp_Waiver_Request @ActorUserId = @AdminUserId
       , @EmployeeId = @FranId, @RequirementId = @ReqId
       , @WaiverType = 4 /* Emergency */
       , @Justification = N'Operador con 3 semanas de experiencia practica en RXR-01 segun AIRLINK. Se autoriza operacion bajo supervision directa mientras completa la certificacion IP68. Plan: sesion practica programada.'
       , @RequiresSupervision = 1
       , @ExpiresAtUtc = @WaiverExpires
       , @WaiverId = @WaiverId OUTPUT;
    EXEC comp.usp_Waiver_Approve @ActorUserId = @QaUserId, @WaiverId = @WaiverId
       , @ApproverComments = N'Aprobado por experiencia demostrada. Supervision directa obligatoria. Vence en 30 dias.';
END;

PRINT '--- [10] Elegibilidad tras waiver ---';
EXEC comp.usp_Eligibility_CheckEmployeeForStation
      @EmployeeCode = N'AL-0104', @StationCode = N'RXR-01'
    , @RequestSource = N'Nexus', @Decision = @Decision OUTPUT;
SELECT DecisionTrasWaiver = @Decision;

PRINT '--- [11] Bitacora de gating (evidencia del Shadow mode) ---';
SELECT gl.EvaluatedAtUtc, s.StationCode, gl.Decision, gl.GatingMode, gl.WasEnforced, gl.RequestSource
FROM comp.GatingDecisionLog gl
LEFT JOIN org.Station s ON s.StationId = gl.StationId
WHERE gl.EmployeeId = @FranId
ORDER BY gl.GatingDecisionLogId;
GO
