/* =============================================================================
   Classroom LMS by Airlink
   09_functions.sql  -  Funciones escalares y con valores de tabla
   ============================================================================= */
USE AIRLINK_LMS;
GO
SET NOCOUNT ON;
GO

/* -----------------------------------------------------------------------------
   sec.fn_UserHasPermission
   Devuelve 1 si el usuario tiene el permiso en cualquier scope.
   Para validar scope especifico usar sec.fn_UserScopeIncludes.
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION sec.fn_UserHasPermission
(
      @UserId         INT
    , @PermissionCode NVARCHAR(80)
)
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @Result BIT = 0;

    IF EXISTS (
        SELECT 1
        FROM sec.UserRoleAssignment ura
        JOIN sec.RolePermission     rp ON rp.RoleId = ura.RoleId
        JOIN sec.Permission         p  ON p.PermissionId = rp.PermissionId
        JOIN sec.Role               r  ON r.RoleId = ura.RoleId
        WHERE ura.UserId       = @UserId
          AND ura.IsActive     = 1
          AND ura.RevokedAtUtc IS NULL
          AND r.IsActive       = 1
          AND r.IsDeleted      = 0
          AND p.PermissionCode = @PermissionCode
    )
        SET @Result = 1;

    RETURN @Result;
END;
GO

/* -----------------------------------------------------------------------------
   sec.fn_UserScopeIncludes
   Verifica que el usuario tenga el permiso Y que el scope de su asignacion
   cubra el objetivo. Global cubre todo; Site cubre sus departamentos; etc.
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION sec.fn_UserScopeIncludes
(
      @UserId          INT
    , @PermissionCode  NVARCHAR(80)
    , @TargetSiteId    INT
    , @TargetDepartmentId INT
    , @TargetAreaId    INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @Result BIT = 0;

    IF EXISTS (
        SELECT 1
        FROM sec.UserRoleAssignment ura
        JOIN sec.RolePermission     rp ON rp.RoleId = ura.RoleId
        JOIN sec.Permission         p  ON p.PermissionId = rp.PermissionId
        WHERE ura.UserId       = @UserId
          AND ura.IsActive     = 1
          AND ura.RevokedAtUtc IS NULL
          AND p.PermissionCode = @PermissionCode
          AND (
                 ura.ScopeType = 1                                        -- Global
              OR (ura.ScopeType = 2 AND ura.ScopeId = @TargetSiteId)       -- Site
              OR (ura.ScopeType = 3 AND ura.ScopeId = @TargetDepartmentId) -- Department
              OR (ura.ScopeType = 4 AND ura.ScopeId = @TargetAreaId)       -- Area
              OR (ura.ScopeType = 2 AND EXISTS (
                     SELECT 1 FROM org.Department d
                     WHERE d.DepartmentId = @TargetDepartmentId
                       AND d.SiteId = ura.ScopeId))
              OR (ura.ScopeType = 3 AND EXISTS (
                     SELECT 1 FROM org.Area a
                     WHERE a.AreaId = @TargetAreaId
                       AND a.DepartmentId = ura.ScopeId))
          )
    )
        SET @Result = 1;

    RETURN @Result;
END;
GO

/* -----------------------------------------------------------------------------
   comp.fn_GetCertificationStatus
   Estado derivado de una certificacion en un momento dado.
   1=Valid 2=ExpiringSoon 3=Expired 4=RetrainingRequired 5=Revoked 6=Provisional
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION comp.fn_GetCertificationStatus
(
      @StoredStatus     TINYINT
    , @ExpiresAtUtc     DATETIME2(3)
    , @AlertWindowDays  INT
    , @AsOfUtc          DATETIME2(3)
)
RETURNS TINYINT
AS
BEGIN
    -- Revoked y RetrainingRequired son estados explicitos: no se derivan.
    IF @StoredStatus IN (4, 5) RETURN @StoredStatus;

    IF @ExpiresAtUtc IS NULL
        RETURN CASE WHEN @StoredStatus = 6 THEN 6 ELSE 1 END;

    IF @AsOfUtc > @ExpiresAtUtc                       RETURN 3;  -- Expired
    IF @AsOfUtc > DATEADD(DAY, -ISNULL(@AlertWindowDays, 30), @ExpiresAtUtc)
                                                       RETURN 2;  -- ExpiringSoon
    IF @StoredStatus = 6                               RETURN 6;  -- Provisional
    RETURN 1;                                                     -- Valid
END;
GO

/* -----------------------------------------------------------------------------
   comp.fn_GetEffectiveRequirements
   Requisitos efectivos de un empleado: union de todas sus posiciones vigentes,
   su departamento, su area, su sitio, los globales y los asignados a el
   directamente. Deduplicado quedandose con el nivel MAS ALTO exigido.

   Es la funcion mas usada del motor de compliance.
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION comp.fn_GetEffectiveRequirements (@EmployeeId INT)
RETURNS TABLE
AS
RETURN
(
    WITH EmployeeContext AS (
        SELECT  e.EmployeeId
              , e.SiteId
              , e.DepartmentId
              , e.AreaId
              , e.HireDateUtc
        FROM org.Employee e
        WHERE e.EmployeeId = @EmployeeId
    ),
    EmployeePositions AS (
        SELECT ep.PositionId
        FROM org.EmployeePosition ep
        WHERE ep.EmployeeId = @EmployeeId
          AND ep.EffectiveToUtc IS NULL
    ),
    EmployeeStations AS (
        SELECT ea.StationId
        FROM org.EmployeeAssignment ea
        WHERE ea.EmployeeId = @EmployeeId
          AND ea.EffectiveToUtc IS NULL
          AND ea.StationId IS NOT NULL
    ),
    Applicable AS (
        SELECT  r.RequirementId
              , r.CompetencyId
              , r.MinimumLevelId
              , r.ValidityMonths
              , r.AlertWindowDays
              , r.Criticality
              , r.RegulatoryBasis
              , r.GracePeriodDays
              , r.AllowProvisional
              , r.AppliesFromHireDays
              , r.ScopeType
              , cl.LevelOrdinal AS RequiredLevelOrdinal
        FROM comp.CompetencyRequirement r
        JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = r.MinimumLevelId
        CROSS JOIN EmployeeContext ec
        WHERE r.[Status] = 1
          AND (r.EffectiveToUtc IS NULL OR r.EffectiveToUtc > SYSUTCDATETIME())
          AND r.EffectiveFromUtc <= SYSUTCDATETIME()
          -- el requisito aplica solo despues de N dias desde el ingreso
          AND (ec.HireDateUtc IS NULL
               OR DATEADD(DAY, r.AppliesFromHireDays, ec.HireDateUtc) <= SYSUTCDATETIME())
          AND (
                 (r.ScopeType = 7)                                                    -- Global
              OR (r.ScopeType = 6 AND r.ScopeId = ec.SiteId)                          -- Site
              OR (r.ScopeType = 2 AND r.ScopeId = ec.DepartmentId)                    -- Department
              OR (r.ScopeType = 3 AND r.ScopeId = ec.AreaId)                          -- Area
              OR (r.ScopeType = 5 AND r.ScopeId = ec.EmployeeId)                      -- Employee
              OR (r.ScopeType = 1 AND r.ScopeId IN (SELECT PositionId FROM EmployeePositions))
              OR (r.ScopeType = 4 AND r.ScopeId IN (SELECT StationId  FROM EmployeeStations))
          )
    ),
    Ranked AS (
        SELECT  a.*
              , ROW_NUMBER() OVER (
                    PARTITION BY a.CompetencyId
                    ORDER BY a.RequiredLevelOrdinal DESC   -- gana el nivel mas alto
                           , a.Criticality ASC             -- luego el mas critico
                           , a.RequirementId ASC
                ) AS rn
        FROM Applicable a
    )
    SELECT  RequirementId
          , CompetencyId
          , MinimumLevelId
          , RequiredLevelOrdinal
          , ValidityMonths
          , AlertWindowDays
          , Criticality
          , RegulatoryBasis
          , GracePeriodDays
          , AllowProvisional
          , ScopeType
    FROM Ranked
    WHERE rn = 1
);
GO

/* -----------------------------------------------------------------------------
   comp.fn_HasActiveWaiver
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION comp.fn_HasActiveWaiver
(
      @EmployeeId    INT
    , @RequirementId INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @Result BIT = 0;

    IF EXISTS (
        SELECT 1
        FROM comp.Waiver w
        WHERE w.EmployeeId    = @EmployeeId
          AND w.RequirementId = @RequirementId
          AND w.[Status]      = 2                                  -- Approved
          AND w.RevokedAtUtc IS NULL
          AND (w.EffectiveFromUtc IS NULL OR w.EffectiveFromUtc <= SYSUTCDATETIME())
          AND (w.ExpiresAtUtc     IS NULL OR w.ExpiresAtUtc     >  SYSUTCDATETIME())
    )
        SET @Result = 1;

    RETURN @Result;
END;
GO

/* -----------------------------------------------------------------------------
   ops.fn_SplitAlertWindow -> primer valor (el mas amplio) de '60,30,7'
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION ops.fn_FirstAlertWindowDays (@AlertWindowDays NVARCHAR(50))
RETURNS INT
AS
BEGIN
    IF @AlertWindowDays IS NULL OR LEN(@AlertWindowDays) = 0 RETURN 30;

    DECLARE @First NVARCHAR(20) =
        CASE WHEN CHARINDEX(N',', @AlertWindowDays) > 0
             THEN LEFT(@AlertWindowDays, CHARINDEX(N',', @AlertWindowDays) - 1)
             ELSE @AlertWindowDays
        END;

    RETURN TRY_CONVERT(INT, LTRIM(RTRIM(@First)));
END;
GO

/* -----------------------------------------------------------------------------
   org.fn_GetTeamEmployeeIds
   Reportes directos e indirectos de un supervisor (jerarquia recursiva).
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION org.fn_GetTeamEmployeeIds
(
      @SupervisorEmployeeId INT
    , @IncludeIndirect      BIT
)
RETURNS TABLE
AS
RETURN
(
    WITH Team AS (
        SELECT e.EmployeeId, 1 AS [Level]
        FROM org.Employee e
        WHERE e.SupervisorEmployeeId = @SupervisorEmployeeId
          AND e.IsActive = 1

        UNION ALL

        SELECT e.EmployeeId, t.[Level] + 1
        FROM org.Employee e
        JOIN Team t ON t.EmployeeId = e.SupervisorEmployeeId
        WHERE @IncludeIndirect = 1
          AND e.IsActive = 1
          AND t.[Level] < 10          -- corta ciclos de datos malos
    )
    SELECT EmployeeId, [Level] FROM Team
);
GO

PRINT '=== 09_functions.sql completado ===';
GO
