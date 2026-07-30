/* =====================================================================
   Classroom - LMS by Airlink
   11_procs_identity.sql
   Esquemas: sec (identidad, sesiones, roles) y org (empleados, estructura)

   REGLA CERO: la app no toca tablas. Todo entra por aqui.

   Codigos de error de este archivo: 50001-50199
   ===================================================================== */

USE AIRLINK_LMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 11_procs_identity.sql iniciado ===';
GO

/* =====================================================================
   sec.usp_User_AuthenticatePin
   GAP-09: autenticacion de piso sin correo corporativo.

   IMPORTANTE: este SP NO valida el PIN. T-SQL no hace criptografia de
   contrasenas. La API calcula PBKDF2 y compara. Este SP:
     a) devuelve el material de hash para que la API compare, y
     b) registra el intento y aplica el bloqueo.
   El flujo real es de dos pasos:
     1. EXEC sec.usp_User_AuthenticatePin @Phase = 1  -> devuelve hash/salt
     2. La API compara -> EXEC sec.usp_User_AuthenticatePin @Phase = 2
        con @IsMatch para registrar exito/fallo y crear la sesion.
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_User_AuthenticatePin
      @EmployeeCode   NVARCHAR(100)
    , @Phase          TINYINT          = 1        -- 1=GetMaterial 2=RecordResult
    , @IsMatch        BIT              = NULL     -- requerido en fase 2
    , @DeviceId       INT              = NULL
    , @IpAddress      NVARCHAR(45)     = NULL
    , @UserId         INT              = NULL OUTPUT
    , @IsAuthenticated BIT             = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------
       Proposito : autenticar operador por codigo de empleado + PIN.
       Retorna   : fase 1 -> PinHash, PinSalt, Iterations, Algorithm
                   fase 2 -> UserId, DisplayName, permisos, sesion
       Errores   : 50101 usuario no existe / inactivo
                   50102 cuenta bloqueada
                   50103 device no autorizado
                   50104 PIN vencido / debe cambiarse
       --------------------------------------------------------------- */

    BEGIN TRY
        DECLARE @MaxFailed        TINYINT = 5
              , @LockMinutes      INT     = 15
              , @NowUtc           DATETIME2(3) = SYSUTCDATETIME()
              , @LockedUntilUtc   DATETIME2(3)
              , @FailedCount      TINYINT
              , @IsActive         BIT
              , @PinExpiresAtUtc  DATETIME2(3)
              , @MustChange       BIT;

        SET @IsAuthenticated = 0;

        /* El login de piso es SIEMPRE por codigo de empleado, aunque el
           UserName sea un UPN (usuarios con Entra ademas del PIN). */
        SELECT  @UserId          = u.UserId
              , @IsActive        = u.IsActive
              , @FailedCount     = c.FailedAttemptCount
              , @LockedUntilUtc  = c.LockedUntilUtc
              , @PinExpiresAtUtc = c.ExpiresAtUtc
              , @MustChange      = c.MustChangeOnNextLogin
        FROM sec.[User] u
        LEFT JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
        LEFT JOIN sec.UserCredential c ON c.UserId = u.UserId
        WHERE (u.UserName = @EmployeeCode OR e.EmployeeCode = @EmployeeCode)
          AND u.IsDeleted = 0
          AND u.AuthMethod IN (2, 3);

        /* Usuario inexistente: se registra el intento pero el mensaje al
           cliente es generico. No confirmamos si el codigo existe. */
        IF @UserId IS NULL
        BEGIN
            INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, FailureReason, IpAddress)
            VALUES (@EmployeeCode, NULL, @DeviceId, 0, 1, @IpAddress);
            THROW 50101, 'Codigo o PIN incorrecto.', 1;
        END;

        IF @IsActive = 0
        BEGIN
            INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, FailureReason, IpAddress)
            VALUES (@EmployeeCode, @UserId, @DeviceId, 0, 4, @IpAddress);
            THROW 50101, 'Codigo o PIN incorrecto.', 1;
        END;

        IF @LockedUntilUtc IS NOT NULL AND @LockedUntilUtc > @NowUtc
        BEGIN
            INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, FailureReason, IpAddress)
            VALUES (@EmployeeCode, @UserId, @DeviceId, 0, 3, @IpAddress);
            THROW 50102, 'Cuenta bloqueada temporalmente. Contacte a su supervisor.', 1;
        END;

        /* El kiosko exige DeviceToken valido. Sin device registrado no se
           autentica por PIN, aunque el PIN sea correcto. */
        IF @DeviceId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM sec.DeviceRegistration d
                           WHERE d.DeviceId = @DeviceId AND d.IsActive = 1 AND d.RevokedAtUtc IS NULL)
        BEGIN
            INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, FailureReason, IpAddress)
            VALUES (@EmployeeCode, @UserId, @DeviceId, 0, 5, @IpAddress);
            THROW 50103, 'Terminal no autorizada.', 1;
        END;

        /* ---------- FASE 1: entregar material de hash ---------- */
        IF @Phase = 1
        BEGIN
            SELECT  c.PinHash
                  , c.PinSalt
                  , c.Iterations
                  , c.Algorithm
                  , @UserId AS UserId
            FROM sec.UserCredential c
            WHERE c.UserId = @UserId;
            RETURN 0;
        END;

        /* ---------- FASE 2: registrar resultado ---------- */
        IF @IsMatch IS NULL
            THROW 50010, 'IsMatch es requerido en fase 2.', 1;

        BEGIN TRANSACTION;

        IF @IsMatch = 0
        BEGIN
            UPDATE sec.UserCredential
            SET  FailedAttemptCount = FailedAttemptCount + 1
               , LockedUntilUtc = CASE WHEN FailedAttemptCount + 1 >= @MaxFailed
                                       THEN DATEADD(MINUTE, @LockMinutes, @NowUtc)
                                       ELSE LockedUntilUtc END
            WHERE UserId = @UserId;

            INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, FailureReason, IpAddress)
            VALUES (@EmployeeCode, @UserId, @DeviceId, 0, 2, @IpAddress);

            COMMIT TRANSACTION;
            THROW 50101, 'Codigo o PIN incorrecto.', 1;
        END;

        /* PIN correcto */
        UPDATE sec.UserCredential
        SET FailedAttemptCount = 0, LockedUntilUtc = NULL
        WHERE UserId = @UserId;

        UPDATE sec.[User] SET LastLoginAtUtc = @NowUtc WHERE UserId = @UserId;

        INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, IpAddress)
        VALUES (@EmployeeCode, @UserId, @DeviceId, 1, @IpAddress);

        COMMIT TRANSACTION;

        SET @IsAuthenticated = 1;

        SELECT  u.UserId
              , u.PublicId
              , u.EmployeeId
              , u.DisplayName
              , u.PreferredLocale
              , @MustChange      AS MustChangePin
              , CASE WHEN @PinExpiresAtUtc IS NOT NULL AND @PinExpiresAtUtc <= @NowUtc
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsPinExpired
        FROM sec.[User] u
        WHERE u.UserId = @UserId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_AuthenticatePin';
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   sec.usp_User_GetPermissions
   Devuelve permisos efectivos con su alcance. La API lo cachea 5 min.
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_User_GetPermissions
      @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT DISTINCT
                p.PermissionCode
              , p.Domain
              , ura.ScopeType
              , ura.ScopeId
        FROM sec.UserRoleAssignment ura
        JOIN sec.RolePermission rp ON rp.RoleId = ura.RoleId
        JOIN sec.Permission     p  ON p.PermissionId = rp.PermissionId
        WHERE ura.UserId = @UserId
          AND ura.IsActive = 1
          AND ura.RevokedAtUtc IS NULL
        ORDER BY p.Domain, p.PermissionCode;

        /* Segundo resultset: contexto organizacional del usuario, para que
           la API resuelva "mi departamento" sin otra llamada. */
        SELECT  u.UserId
              , u.EmployeeId
              , e.SiteId
              , e.DepartmentId
              , e.AreaId
              , e.SupervisorEmployeeId
        FROM sec.[User] u
        LEFT JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
        WHERE u.UserId = @UserId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_GetPermissions', @ActorUserId = @UserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   sec.usp_Session_Create / Validate / Revoke
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_Session_Create
      @UserId         INT
    , @SessionType    TINYINT       = 1
    , @DeviceId       INT           = NULL
    , @IpAddress      NVARCHAR(45)  = NULL
    , @UserAgent      NVARCHAR(400) = NULL
    , @TtlMinutes     INT           = 480
    , @SessionId      UNIQUEIDENTIFIER = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Kiosko: TTL corto por seguridad de piso (turno compartido). */
    BEGIN TRY
        IF @SessionType = 2 AND @TtlMinutes > 60 SET @TtlMinutes = 60;

        SET @SessionId = NEWID();

        INSERT INTO sec.UserSession (SessionId, UserId, DeviceId, SessionType, IpAddress, UserAgent, ExpiresAtUtc)
        VALUES (@SessionId, @UserId, @DeviceId, @SessionType, @IpAddress, @UserAgent,
                DATEADD(MINUTE, @TtlMinutes, SYSUTCDATETIME()));

        IF @DeviceId IS NOT NULL
            UPDATE sec.DeviceRegistration
            SET LastSeenAtUtc = SYSUTCDATETIME(), LastIpAddress = @IpAddress
            WHERE DeviceId = @DeviceId;

        SELECT @SessionId AS SessionId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_Session_Create', @ActorUserId = @UserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Session_Validate
      @SessionId UNIQUEIDENTIFIER
    , @SlideExpiration BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();

        IF @SlideExpiration = 1
            UPDATE sec.UserSession
            SET LastSeenAtUtc = @NowUtc
            WHERE SessionId = @SessionId AND EndedAtUtc IS NULL AND ExpiresAtUtc > @NowUtc;

        SELECT  s.SessionId
              , s.UserId
              , s.DeviceId
              , s.SessionType
              , s.ExpiresAtUtc
              , u.DisplayName
              , u.EmployeeId
              , u.PreferredLocale
              , CASE WHEN s.EndedAtUtc IS NULL AND s.ExpiresAtUtc > @NowUtc AND u.IsActive = 1
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsValid
        FROM sec.UserSession s
        JOIN sec.[User] u ON u.UserId = s.UserId
        WHERE s.SessionId = @SessionId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_Session_Validate';
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Session_Revoke
      @SessionId UNIQUEIDENTIFIER
    , @EndReason TINYINT = 3
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE sec.UserSession
    SET EndedAtUtc = SYSUTCDATETIME(), EndReason = @EndReason
    WHERE SessionId = @SessionId AND EndedAtUtc IS NULL;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Session_RevokeAllForUser
      @ActorUserId INT
    , @UserId      INT
    , @EndReason   TINYINT = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0 AND @ActorUserId <> @UserId
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        UPDATE sec.UserSession
        SET EndedAtUtc = SYSUTCDATETIME(), EndReason = @EndReason
        WHERE UserId = @UserId AND EndedAtUtc IS NULL;

        EXEC aud.usp_Event_Log
              @EventType    = N'Session.RevokedAll'
            , @EntityType   = N'User'
            , @EntityId     = @UserId
            , @ActorUserId  = @ActorUserId
            , @Summary      = N'Todas las sesiones del usuario fueron revocadas.';

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_Session_RevokeAllForUser', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   sec.usp_User_SetPin
   La API pasa hash + salt ya calculados. Este SP nunca ve el PIN.
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_User_SetPin
      @ActorUserId    INT
    , @UserId         INT
    , @PinHash        VARBINARY(64)
    , @PinSalt        VARBINARY(32)
    , @Iterations     INT           = 210000
    , @Algorithm      NVARCHAR(40)  = N'PBKDF2-HMACSHA256'
    , @MustChange     BIT           = 0
    , @ExpiresInDays  INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF @ActorUserId <> @UserId
           AND sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF DATALENGTH(@PinHash) = 0 OR DATALENGTH(@PinSalt) = 0
            THROW 50010, 'PinHash y PinSalt son requeridos.', 1;

        BEGIN TRANSACTION;

        MERGE sec.UserCredential AS tgt
        USING (SELECT @UserId AS UserId) AS src ON tgt.UserId = src.UserId
        WHEN MATCHED THEN UPDATE SET
              PinHash = @PinHash, PinSalt = @PinSalt
            , Iterations = @Iterations, Algorithm = @Algorithm
            , MustChangeOnNextLogin = @MustChange
            , ExpiresAtUtc = CASE WHEN @ExpiresInDays IS NULL THEN NULL
                                  ELSE DATEADD(DAY, @ExpiresInDays, SYSUTCDATETIME()) END
            , FailedAttemptCount = 0, LockedUntilUtc = NULL
            , LastChangedAtUtc = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT
              (UserId, PinHash, PinSalt, Iterations, Algorithm, MustChangeOnNextLogin, ExpiresAtUtc)
            VALUES (@UserId, @PinHash, @PinSalt, @Iterations, @Algorithm, @MustChange,
                    CASE WHEN @ExpiresInDays IS NULL THEN NULL
                         ELSE DATEADD(DAY, @ExpiresInDays, SYSUTCDATETIME()) END);

        /* Cambiar el PIN cierra las sesiones abiertas. */
        UPDATE sec.UserSession
        SET EndedAtUtc = SYSUTCDATETIME(), EndReason = 3
        WHERE UserId = @UserId AND EndedAtUtc IS NULL;

        EXEC aud.usp_Event_Log
              @EventType   = N'User.PinChanged'
            , @EntityType  = N'User'
            , @EntityId    = @UserId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'PIN de acceso actualizado.';

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_SetPin', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   sec.usp_UserRole_Assign / Revoke
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_UserRole_Assign
      @ActorUserId INT
    , @UserId      INT
    , @RoleId      INT
    , @ScopeType   TINYINT = 1
    , @ScopeId     INT     = NULL
    , @UserRoleAssignmentId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50110 rol no existe, 50111 asignacion duplicada,
                50112 violacion de segregacion de funciones (SoD)        */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'role.assign') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF NOT EXISTS (SELECT 1 FROM sec.Role WHERE RoleId = @RoleId AND IsActive = 1)
            THROW 50110, 'El rol indicado no existe o esta inactivo.', 1;

        IF EXISTS (SELECT 1 FROM sec.UserRoleAssignment
                   WHERE UserId = @UserId AND RoleId = @RoleId
                     AND ISNULL(ScopeType,0) = ISNULL(@ScopeType,0)
                     AND ISNULL(ScopeId,-1)  = ISNULL(@ScopeId,-1)
                     AND IsActive = 1)
            THROW 50111, 'El usuario ya tiene ese rol en ese alcance.', 1;

        /* SoD: quien aprueba contenido no puede ser quien lo autoriza a
           produccion. Ver doc 06 seccion 5. */
        IF EXISTS (
            SELECT 1
            FROM sec.UserRoleAssignment ura
            JOIN sec.Role r ON r.RoleId = ura.RoleId
            WHERE ura.UserId = @UserId AND ura.IsActive = 1
              AND (
                    (r.RoleCode = N'CONTENT_AUTHOR'  AND @RoleId IN (SELECT RoleId FROM sec.Role WHERE RoleCode = N'QUALITY_APPROVER'))
                 OR (r.RoleCode = N'QUALITY_APPROVER' AND @RoleId IN (SELECT RoleId FROM sec.Role WHERE RoleCode = N'CONTENT_AUTHOR'))
              )
        )
            THROW 50112, 'Conflicto de segregacion de funciones: autor de contenido y aprobador de calidad no pueden ser la misma persona.', 1;

        BEGIN TRANSACTION;

        INSERT INTO sec.UserRoleAssignment (UserId, RoleId, ScopeType, ScopeId, AssignedByUserId)
        VALUES (@UserId, @RoleId, @ScopeType, @ScopeId, @ActorUserId);

        SET @UserRoleAssignmentId = SCOPE_IDENTITY();

        EXEC aud.usp_Event_Log
              @EventType   = N'UserRole.Assigned'
            , @EntityType  = N'User'
            , @EntityId    = @UserId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Rol asignado al usuario.';

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_UserRole_Assign', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_UserRole_Revoke
      @ActorUserId INT
    , @UserRoleAssignmentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'role.assign') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        UPDATE sec.UserRoleAssignment
        SET IsActive = 0, RevokedAtUtc = SYSUTCDATETIME(), RevokedByUserId = @ActorUserId
        WHERE UserRoleAssignmentId = @UserRoleAssignmentId AND IsActive = 1;

        IF @@ROWCOUNT = 0 THROW 50001, 'Asignacion de rol no encontrada o ya revocada.', 1;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_UserRole_Revoke', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   org.usp_Employee_Get
   ===================================================================== */
CREATE OR ALTER PROCEDURE org.usp_Employee_Get
      @ActorUserId  INT
    , @EmployeeId   INT = NULL
    , @EmployeeCode NVARCHAR(30) = NULL
    , @PublicId     UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF @EmployeeId IS NULL AND @EmployeeCode IS NULL AND @PublicId IS NULL
            THROW 50010, 'Debe indicar EmployeeId, EmployeeCode o PublicId.', 1;

        SELECT @EmployeeId = COALESCE(@EmployeeId, e.EmployeeId)
        FROM org.Employee e
        WHERE (@EmployeeCode IS NOT NULL AND e.EmployeeCode = @EmployeeCode)
           OR (@PublicId     IS NOT NULL AND e.PublicId     = @PublicId);

        IF @EmployeeId IS NULL THROW 50120, 'Empleado no encontrado.', 1;

        /* Un supervisor solo ve su equipo; RH y Calidad ven todo. */
        IF sec.fn_UserHasPermission(@ActorUserId, N'employee.read.all') = 0
           AND NOT EXISTS (
                SELECT 1 FROM sec.[User] u
                CROSS APPLY org.fn_GetTeamEmployeeIds(u.EmployeeId, 1) t
                WHERE u.UserId = @ActorUserId AND t.EmployeeId = @EmployeeId)
           AND NOT EXISTS (SELECT 1 FROM sec.[User] u WHERE u.UserId = @ActorUserId AND u.EmployeeId = @EmployeeId)
            THROW 50002, 'El usuario no tiene permiso para ver este empleado.', 1;

        SELECT  e.EmployeeId, e.PublicId, e.EmployeeCode
              , e.FirstName, e.LastName, e.FullName
              , e.Email, e.SiteId, e.DepartmentId, e.AreaId
              , e.SupervisorEmployeeId, e.HireDateUtc, e.TerminationDateUtc
              , e.EmploymentType, e.IsActive
              , s.[Name]  AS SiteName
              , d.[Name]  AS DepartmentName
              , a.[Name]  AS AreaName
        FROM org.Employee e
        LEFT JOIN org.Site       s ON s.SiteId       = e.SiteId
        LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
        LEFT JOIN org.Area       a ON a.AreaId       = e.AreaId
        WHERE e.EmployeeId = @EmployeeId;

        /* Posiciones vigentes */
        SELECT  ep.EmployeePositionId, ep.PositionId, p.PositionCode, p.[Name] AS PositionName
              , ep.IsPrimary, ep.EffectiveFromUtc, ep.EffectiveToUtc
        FROM org.EmployeePosition ep
        JOIN org.[Position] p ON p.PositionId = ep.PositionId
        WHERE ep.EmployeeId = @EmployeeId AND ep.EffectiveToUtc IS NULL
        ORDER BY ep.IsPrimary DESC, p.[Name];

        EXEC aud.usp_DataAccess_Log
              @ActorUserId = @ActorUserId
            , @AccessType  = 1
            , @EntityType  = N'Employee'
            , @SubjectEmployeeId = @EmployeeId
            , @RecordCount = 1;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_Employee_Get', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   org.usp_Employee_List  -- listado paginado con filtros opcionales
   ===================================================================== */
CREATE OR ALTER PROCEDURE org.usp_Employee_List
      @ActorUserId   INT
    , @SearchText    NVARCHAR(100) = NULL
    , @SiteId        INT           = NULL
    , @DepartmentId  INT           = NULL
    , @AreaId        INT           = NULL
    , @PositionId    INT           = NULL
    , @SupervisorEmployeeId INT    = NULL
    , @IsActive      BIT           = 1
    , @PageNumber    INT           = 1
    , @PageSize      INT           = 50
    , @SortBy        NVARCHAR(50)  = N'FullName'
    , @SortDir       CHAR(4)       = 'ASC'
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF @PageSize  > 200 SET @PageSize  = 200;
        IF @PageSize  < 1   SET @PageSize  = 50;
        IF @PageNumber < 1  SET @PageNumber = 1;
        IF @SortDir NOT IN ('ASC','DESC') SET @SortDir = 'ASC';

        /* Whitelist de ordenamiento. Nada de concatenar el @SortBy. */
        IF @SortBy NOT IN (N'FullName', N'EmployeeCode', N'HireDateUtc', N'DepartmentName')
            SET @SortBy = N'FullName';

        DECLARE @ActorEmployeeId INT
              , @SeeAll BIT = sec.fn_UserHasPermission(@ActorUserId, N'employee.read.all');

        SELECT @ActorEmployeeId = EmployeeId FROM sec.[User] WHERE UserId = @ActorUserId;

        ;WITH Filtered AS (
            SELECT  e.EmployeeId, e.PublicId, e.EmployeeCode, e.FullName
                  , e.Email, e.SiteId, e.DepartmentId, e.AreaId
                  , e.SupervisorEmployeeId, e.HireDateUtc, e.IsActive
                  , d.[Name] AS DepartmentName
                  , a.[Name] AS AreaName
            FROM org.Employee e
            LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
            LEFT JOIN org.Area       a ON a.AreaId       = e.AreaId
            WHERE (@IsActive     IS NULL OR e.IsActive     = @IsActive)
              AND (@SiteId       IS NULL OR e.SiteId       = @SiteId)
              AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
              AND (@AreaId       IS NULL OR e.AreaId       = @AreaId)
              AND (@SupervisorEmployeeId IS NULL OR e.SupervisorEmployeeId = @SupervisorEmployeeId)
              AND (@SearchText   IS NULL OR e.FullName LIKE N'%' + @SearchText + N'%'
                                         OR e.EmployeeCode LIKE @SearchText + N'%')
              AND (@PositionId   IS NULL OR EXISTS (
                        SELECT 1 FROM org.EmployeePosition ep
                        WHERE ep.EmployeeId = e.EmployeeId AND ep.PositionId = @PositionId
                          AND ep.EffectiveToUtc IS NULL))
              AND (@SeeAll = 1
                   OR e.EmployeeId = @ActorEmployeeId
                   OR EXISTS (SELECT 1 FROM org.fn_GetTeamEmployeeIds(@ActorEmployeeId, 1) t
                              WHERE t.EmployeeId = e.EmployeeId))
        )
        SELECT *
        FROM Filtered
        ORDER BY
              CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'FullName'       THEN FullName       END ASC
            , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'FullName'       THEN FullName       END DESC
            , CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'EmployeeCode'   THEN EmployeeCode   END ASC
            , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'EmployeeCode'   THEN EmployeeCode   END DESC
            , CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'HireDateUtc'    THEN HireDateUtc    END ASC
            , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'HireDateUtc'    THEN HireDateUtc    END DESC
            , CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'DepartmentName' THEN DepartmentName END ASC
            , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'DepartmentName' THEN DepartmentName END DESC
            , EmployeeId
        OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
        OPTION (RECOMPILE);

        /* Segundo resultset: total */
        SELECT COUNT(*) AS TotalCount
        FROM org.Employee e
        WHERE (@IsActive     IS NULL OR e.IsActive     = @IsActive)
          AND (@SiteId       IS NULL OR e.SiteId       = @SiteId)
          AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
          AND (@AreaId       IS NULL OR e.AreaId       = @AreaId)
          AND (@SupervisorEmployeeId IS NULL OR e.SupervisorEmployeeId = @SupervisorEmployeeId)
          AND (@SearchText   IS NULL OR e.FullName LIKE N'%' + @SearchText + N'%'
                                     OR e.EmployeeCode LIKE @SearchText + N'%')
          AND (@SeeAll = 1
               OR e.EmployeeId = @ActorEmployeeId
               OR EXISTS (SELECT 1 FROM org.fn_GetTeamEmployeeIds(@ActorEmployeeId, 1) t
                          WHERE t.EmployeeId = e.EmployeeId))
        OPTION (RECOMPILE);

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_Employee_List', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   org.usp_EmployeePosition_Assign
   Cambiar de posicion dispara recalculo de gaps: el requisito nuevo
   aplica de inmediato. Por eso llama a comp.usp_Gap_RecalculateForEmployee.
   ===================================================================== */
CREATE OR ALTER PROCEDURE org.usp_EmployeePosition_Assign
      @ActorUserId  INT
    , @EmployeeId   INT
    , @PositionId   INT
    , @IsPrimary    BIT = 1
    , @EffectiveFromUtc DATETIME2(3) = NULL
    , @EmployeePositionId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'employee.position.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        SET @EffectiveFromUtc = ISNULL(@EffectiveFromUtc, SYSUTCDATETIME());

        BEGIN TRANSACTION;

        /* Si es primaria, cerrar la primaria anterior. */
        IF @IsPrimary = 1
            UPDATE org.EmployeePosition
            SET EffectiveToUtc = @EffectiveFromUtc
            WHERE EmployeeId = @EmployeeId AND IsPrimary = 1 AND EffectiveToUtc IS NULL;

        INSERT INTO org.EmployeePosition (EmployeeId, PositionId, IsPrimary, EffectiveFromUtc, AssignedByUserId)
        VALUES (@EmployeeId, @PositionId, @IsPrimary, @EffectiveFromUtc, @ActorUserId);

        /* Espejo denormalizado en org.Employee para joins baratos. */
        IF @IsPrimary = 1
            UPDATE org.Employee
            SET PrimaryPositionId = @PositionId, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
            WHERE EmployeeId = @EmployeeId;

        SET @EmployeePositionId = SCOPE_IDENTITY();

        EXEC aud.usp_Event_Log
              @EventType   = N'EmployeePosition.Assigned'
            , @EntityType  = N'Employee'
            , @EntityId    = @EmployeeId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Posicion asignada al empleado.';

        COMMIT TRANSACTION;

        /* Fuera de la transaccion: el recalculo puede ser pesado y no
           debe alargar el lock sobre EmployeePosition. */
        EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_EmployeePosition_Assign', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Resto del esquema sec/org: contratos declarados.
   Implementacion en Fase 1 semana 2-3. Se dejan como CREATE para que el
   deploy no falle y la capa Infrastructure pueda compilar contra ellos.
   ===================================================================== */

CREATE OR ALTER PROCEDURE sec.usp_User_Create
      @ActorUserId INT, @EmployeeId INT = NULL, @UserName NVARCHAR(100)
    , @DisplayName NVARCHAR(200), @Email NVARCHAR(256) = NULL
    , @ExternalObjectId NVARCHAR(100) = NULL, @AuthMethod TINYINT = 1
    , @PreferredLocale NVARCHAR(10) = N'es-DO'
    , @UserId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50105 UserName duplicado, 50106 empleado ya tiene usuario */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF EXISTS (SELECT 1 FROM sec.[User] WHERE UserName = @UserName AND IsDeleted = 0)
            THROW 50105, 'Ya existe un usuario con ese nombre de usuario.', 1;
        IF @EmployeeId IS NOT NULL AND EXISTS (SELECT 1 FROM sec.[User] WHERE EmployeeId = @EmployeeId AND IsDeleted = 0)
            THROW 50106, 'El empleado ya tiene un usuario asociado.', 1;

        INSERT INTO sec.[User] (EmployeeId, UserName, DisplayName, Email, ExternalObjectId, AuthMethod, PreferredLocale, CreatedByUserId)
        VALUES (@EmployeeId, @UserName, @DisplayName, @Email, @ExternalObjectId, @AuthMethod, @PreferredLocale, @ActorUserId);
        SET @UserId = SCOPE_IDENTITY();

        EXEC aud.usp_Event_Log @EventType = N'User.Created', @EntityType = N'User'
           , @EntityId = @UserId, @ActorUserId = @ActorUserId, @Severity = 2
           , @Summary = N'Usuario creado.';
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_User_GetByExternalId
      @ExternalObjectId NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.UserId, u.PublicId, u.EmployeeId, u.UserName, u.DisplayName, u.Email
         , u.PreferredLocale, u.TimeZoneId, u.IsActive
    FROM sec.[User] u
    WHERE u.ExternalObjectId = @ExternalObjectId AND u.IsDeleted = 0;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_User_GetByEmployeeCode
      @EmployeeCode NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.UserId, u.PublicId, u.EmployeeId, u.UserName, u.DisplayName
         , u.PreferredLocale, u.AuthMethod, u.IsActive
    FROM sec.[User] u
    JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
    WHERE e.EmployeeCode = @EmployeeCode AND u.IsDeleted = 0;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_User_Update
      @ActorUserId INT, @UserId INT
    , @DisplayName NVARCHAR(200) = NULL, @Email NVARCHAR(256) = NULL
    , @PreferredLocale NVARCHAR(10) = NULL, @AuthMethod TINYINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF @ActorUserId <> @UserId AND sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        UPDATE sec.[User]
        SET  DisplayName     = ISNULL(@DisplayName, DisplayName)
           , Email           = ISNULL(@Email, Email)
           , PreferredLocale = ISNULL(@PreferredLocale, PreferredLocale)
           , AuthMethod      = ISNULL(@AuthMethod, AuthMethod)
           , ModifiedAtUtc   = SYSUTCDATETIME()
           , ModifiedByUserId = @ActorUserId
        WHERE UserId = @UserId AND IsDeleted = 0;
        IF @@ROWCOUNT = 0 THROW 50001, 'Usuario no encontrado.', 1;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_Update', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_User_Deactivate
      @ActorUserId INT, @UserId INT, @Reason NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        BEGIN TRANSACTION;
        UPDATE sec.[User] SET IsActive = 0, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE UserId = @UserId;
        UPDATE sec.UserSession SET EndedAtUtc = SYSUTCDATETIME(), EndReason = 3
        WHERE UserId = @UserId AND EndedAtUtc IS NULL;
        UPDATE sec.UserRoleAssignment SET IsActive = 0, RevokedAtUtc = SYSUTCDATETIME(), RevokedByUserId = @ActorUserId
        WHERE UserId = @UserId AND IsActive = 1;
        EXEC aud.usp_Event_Log @EventType = N'User.Deactivated', @EntityType = N'User'
           , @EntityId = @UserId, @ActorUserId = @ActorUserId, @Severity = 3, @Summary = N'Usuario desactivado.';
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_Deactivate', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_User_List
      @ActorUserId INT, @SearchText NVARCHAR(100) = NULL, @RoleId INT = NULL
    , @IsActive BIT = 1, @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    IF sec.fn_UserHasPermission(@ActorUserId, N'user.read') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

    SELECT u.UserId, u.PublicId, u.UserName, u.DisplayName, u.Email
         , u.EmployeeId, u.AuthMethod, u.IsActive, u.LastLoginAtUtc
    FROM sec.[User] u
    WHERE u.IsDeleted = 0
      AND (@IsActive IS NULL OR u.IsActive = @IsActive)
      AND (@SearchText IS NULL OR u.DisplayName LIKE N'%' + @SearchText + N'%' OR u.UserName LIKE @SearchText + N'%')
      AND (@RoleId IS NULL OR EXISTS (SELECT 1 FROM sec.UserRoleAssignment ura
                                      WHERE ura.UserId = u.UserId AND ura.RoleId = @RoleId AND ura.IsActive = 1))
    ORDER BY u.DisplayName
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    SELECT COUNT(*) AS TotalCount FROM sec.[User] u
    WHERE u.IsDeleted = 0 AND (@IsActive IS NULL OR u.IsActive = @IsActive)
      AND (@SearchText IS NULL OR u.DisplayName LIKE N'%' + @SearchText + N'%' OR u.UserName LIKE @SearchText + N'%')
      AND (@RoleId IS NULL OR EXISTS (SELECT 1 FROM sec.UserRoleAssignment ura
                                      WHERE ura.UserId = u.UserId AND ura.RoleId = @RoleId AND ura.IsActive = 1))
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Role_Create
      @ActorUserId INT, @RoleCode NVARCHAR(50)
    , @DisplayNameEs NVARCHAR(100), @DisplayNameEn NVARCHAR(100)
    , @Description NVARCHAR(400) = NULL, @RoleId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'role.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO sec.Role (RoleCode, DisplayNameEs, DisplayNameEn, [Description], IsSystem, CreatedByUserId)
    VALUES (@RoleCode, @DisplayNameEs, @DisplayNameEn, @Description, 0, @ActorUserId);
    SET @RoleId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

/* Recibe el set completo de permisos via TVP. Reemplaza, no acumula. */
CREATE OR ALTER PROCEDURE sec.usp_Role_SetPermissions
      @ActorUserId INT, @RoleId INT, @PermissionIds ops.IntListType READONLY
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'role.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF EXISTS (SELECT 1 FROM sec.Role WHERE RoleId = @RoleId AND IsSystem = 1)
            THROW 50113, 'No se pueden modificar los permisos de un rol de sistema.', 1;

        BEGIN TRANSACTION;
        DELETE rp FROM sec.RolePermission rp
        WHERE rp.RoleId = @RoleId AND rp.PermissionId NOT IN (SELECT [Value] FROM @PermissionIds);

        INSERT INTO sec.RolePermission (RoleId, PermissionId)
        SELECT @RoleId, p.[Value] FROM @PermissionIds p
        WHERE NOT EXISTS (SELECT 1 FROM sec.RolePermission rp WHERE rp.RoleId = @RoleId AND rp.PermissionId = p.[Value]);

        EXEC aud.usp_Event_Log @EventType = N'Role.PermissionsChanged', @EntityType = N'Role'
           , @EntityId = @RoleId, @ActorUserId = @ActorUserId, @Severity = 3
           , @Summary = N'Permisos del rol actualizados.';
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_Role_SetPermissions', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Device_Register
      @ActorUserId INT, @DeviceName NVARCHAR(100), @DeviceTokenHash VARBINARY(64)
    , @SiteId INT = NULL, @DepartmentId INT = NULL, @AreaId INT = NULL, @StationId INT = NULL
    , @DeviceId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'device.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO sec.DeviceRegistration (DeviceName, DeviceTokenHash, SiteId, DepartmentId, AreaId, StationId, RegisteredByUserId)
    VALUES (@DeviceName, @DeviceTokenHash, @SiteId, @DepartmentId, @AreaId, @StationId, @ActorUserId);
    SET @DeviceId = SCOPE_IDENTITY();
    EXEC aud.usp_Event_Log @EventType = N'Device.Registered', @EntityType = N'Device'
       , @EntityId = @DeviceId, @ActorUserId = @ActorUserId, @Severity = 2, @Summary = N'Terminal registrada.';
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Device_Validate
      @DeviceName NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    /* La API compara el hash del token. Aqui solo devolvemos el material. */
    SELECT d.DeviceId, d.PublicId, d.DeviceTokenHash, d.SiteId, d.DepartmentId
         , d.AreaId, d.StationId, d.IsKiosk, d.IsActive
    FROM sec.DeviceRegistration d
    WHERE d.DeviceName = @DeviceName AND d.IsActive = 1 AND d.RevokedAtUtc IS NULL;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Device_List
      @ActorUserId INT, @SiteId INT = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'device.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    SELECT d.DeviceId, d.PublicId, d.DeviceName, d.SiteId, d.DepartmentId, d.AreaId
         , d.StationId, d.IsKiosk, d.IsActive, d.LastSeenAtUtc, d.LastIpAddress
    FROM sec.DeviceRegistration d
    WHERE (@SiteId IS NULL OR d.SiteId = @SiteId)
      AND (@IsActive IS NULL OR d.IsActive = @IsActive)
    ORDER BY d.DeviceName
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Employee_GetPositions
      @ActorUserId INT, @EmployeeId INT, @IncludeHistory BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ep.EmployeePositionId, ep.PositionId, p.PositionCode, p.[Name] AS PositionName
         , ep.IsPrimary, ep.EffectiveFromUtc, ep.EffectiveToUtc
    FROM org.EmployeePosition ep
    JOIN org.[Position] p ON p.PositionId = ep.PositionId
    WHERE ep.EmployeeId = @EmployeeId
      AND (@IncludeHistory = 1 OR ep.EffectiveToUtc IS NULL)
    ORDER BY ep.EffectiveFromUtc DESC
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Employee_GetTeam
      @ActorUserId INT, @SupervisorEmployeeId INT, @IncludeIndirect BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.EmployeeId, e.EmployeeCode, e.FullName, e.DepartmentId, e.AreaId
         , e.IsActive, t.[Level] AS DepthLevel
    FROM org.fn_GetTeamEmployeeIds(@SupervisorEmployeeId, @IncludeIndirect) t
    JOIN org.Employee e ON e.EmployeeId = t.EmployeeId
    ORDER BY t.[Level], e.FullName
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_EmployeePosition_End
      @ActorUserId INT, @EmployeePositionId INT, @EffectiveToUtc DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'employee.position.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        DECLARE @EmployeeId INT;
        SELECT @EmployeeId = EmployeeId FROM org.EmployeePosition WHERE EmployeePositionId = @EmployeePositionId;
        IF @EmployeeId IS NULL THROW 50001, 'Asignacion de posicion no encontrada.', 1;

        UPDATE org.EmployeePosition
        SET EffectiveToUtc = ISNULL(@EffectiveToUtc, SYSUTCDATETIME())
        WHERE EmployeePositionId = @EmployeePositionId AND EffectiveToUtc IS NULL;

        EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_EmployeePosition_End', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Position_Create
      @ActorUserId INT, @PositionCode NVARCHAR(40), @Name NVARCHAR(150)
    , @NameEn NVARCHAR(150) = NULL, @JobFamily NVARCHAR(80) = NULL
    , @Description NVARCHAR(1000) = NULL
    , @AffectsProductQuality BIT = 0
    , @PositionId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'org.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    /* AffectsProductQuality = 1 marca la posicion como sujeta a ISO 9001
       cl.7.2. Calidad revisa este flag en la matriz de competencias. */
    INSERT INTO org.[Position] (PositionCode, [Name], NameEn, JobFamily, [Description]
                              , AffectsProductQuality, IsMappedFromSource, RequiresReview)
    VALUES (@PositionCode, @Name, @NameEn, @JobFamily, @Description, @AffectsProductQuality, 0, 0);
    SET @PositionId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Site_List @ActorUserId INT, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SiteId, SiteCode, [Name], OrganizationId, TimeZoneId, IsActive
    FROM org.Site WHERE (@IsActive IS NULL OR IsActive = @IsActive) ORDER BY [Name]
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Department_List @ActorUserId INT, @SiteId INT = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DepartmentId, DepartmentCode, [Name], SiteId, ManagerEmployeeId, IsActive
    FROM org.Department
    WHERE (@SiteId IS NULL OR SiteId = @SiteId) AND (@IsActive IS NULL OR IsActive = @IsActive)
    ORDER BY [Name] OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Area_List @ActorUserId INT, @DepartmentId INT = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT AreaId, AreaCode, [Name], DepartmentId, AreaType, SupervisorEmployeeId, IsActive
    FROM org.Area
    WHERE (@DepartmentId IS NULL OR DepartmentId = @DepartmentId) AND (@IsActive IS NULL OR IsActive = @IsActive)
    ORDER BY [Name] OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Station_List @ActorUserId INT, @AreaId INT = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.StationId, s.PublicId, s.StationCode, s.[Name], s.AreaId
         , s.ProcessCode, s.EquipmentName, s.RequiresGating, s.GatingMode, s.IsActive
         , (SELECT COUNT(*) FROM comp.StationCompetency sc WHERE sc.StationId = s.StationId) AS RequirementCount
    FROM org.Station s
    WHERE (@AreaId IS NULL OR s.AreaId = @AreaId) AND (@IsActive IS NULL OR s.IsActive = @IsActive)
    ORDER BY s.[Name] OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Station_Upsert
      @ActorUserId INT, @StationId INT = NULL, @StationCode NVARCHAR(40)
    , @Name NVARCHAR(150), @AreaId INT
    , @ProcessCode NVARCHAR(40) = NULL, @EquipmentName NVARCHAR(150) = NULL
    , @RequiresGating BIT = 0, @GatingMode TINYINT = 1
    , @ResultStationId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'org.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        /* Upsert real: sin @StationId, resolver por StationCode. Un sync
           de estaciones re-ejecutado no debe duplicar. */
        IF @StationId IS NULL
            SELECT @StationId = StationId FROM org.Station WHERE StationCode = @StationCode;

        IF @StationId IS NULL
        BEGIN
            INSERT INTO org.Station (StationCode, [Name], AreaId, ProcessCode, EquipmentName, RequiresGating, GatingMode)
            VALUES (@StationCode, @Name, @AreaId, @ProcessCode, @EquipmentName, @RequiresGating, @GatingMode);
            SET @ResultStationId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE org.Station
            SET StationCode = @StationCode, [Name] = @Name, AreaId = @AreaId
              , ProcessCode = @ProcessCode, EquipmentName = @EquipmentName
              , RequiresGating = @RequiresGating, GatingMode = @GatingMode
            WHERE StationId = @StationId;
            SET @ResultStationId = @StationId;
        END;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_Station_Upsert', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   org.usp_EmployeeAssignment_Set

   Ubica al empleado: sitio/departamento/area/estacion/turno vigente.
   Cierra la asignacion abierta y abre la nueva (historia, nunca update).
   La estacion es la unidad de gating: cambiarla dispara recalculo de
   brechas de inmediato.

   Errores: 50002 sin permiso, 50110 empleado no existe,
            50111 estacion no existe
   ===================================================================== */
CREATE OR ALTER PROCEDURE org.usp_EmployeeAssignment_Set
      @ActorUserId  INT
    , @EmployeeId   INT
    , @SiteId       INT = NULL
    , @DepartmentId INT = NULL
    , @AreaId       INT = NULL
    , @StationId    INT = NULL
    , @ShiftCode    NVARCHAR(20) = NULL
    , @EffectiveFromUtc DATETIME2(3) = NULL
    , @EmployeeAssignmentId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'employee.position.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF NOT EXISTS (SELECT 1 FROM org.Employee WHERE EmployeeId = @EmployeeId)
            THROW 50110, 'El empleado no existe.', 1;

        IF @StationId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM org.Station
                           WHERE StationId = @StationId AND IsDeleted = 0)
            THROW 50111, 'La estacion no existe.', 1;

        SET @EffectiveFromUtc = ISNULL(@EffectiveFromUtc, SYSUTCDATETIME());

        BEGIN TRANSACTION;

        UPDATE org.EmployeeAssignment
        SET EffectiveToUtc = @EffectiveFromUtc
        WHERE EmployeeId = @EmployeeId AND EffectiveToUtc IS NULL;

        INSERT INTO org.EmployeeAssignment (EmployeeId, SiteId, DepartmentId, AreaId
                                          , StationId, ShiftCode, EffectiveFromUtc)
        VALUES (@EmployeeId, @SiteId, @DepartmentId, @AreaId
              , @StationId, @ShiftCode, @EffectiveFromUtc);

        SET @EmployeeAssignmentId = SCOPE_IDENTITY();

        /* Espejo denormalizado en org.Employee para joins baratos. */
        UPDATE org.Employee
        SET SiteId = COALESCE(@SiteId, SiteId)
          , DepartmentId = COALESCE(@DepartmentId, DepartmentId)
          , AreaId = COALESCE(@AreaId, AreaId)
          , ShiftCode = COALESCE(@ShiftCode, ShiftCode)
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EmployeeId = @EmployeeId;

        EXEC aud.usp_Event_Log
              @EventType   = N'EmployeeAssignment.Set'
            , @EntityType  = N'Employee'
            , @EntityId    = @EmployeeId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Asignacion de ubicacion/estacion actualizada.';

        COMMIT TRANSACTION;

        /* Fuera de la transaccion: una estacion nueva puede traer
           requisitos nuevos. */
        EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_EmployeeAssignment_Set', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   sec.usp_User_ProvisionForEmployees

   Aprovisionamiento masivo: crea el usuario de aplicacion (AuthMethod=2,
   PIN) para todo empleado activo que no tenga uno. UserName = codigo de
   empleado. Es la base del login universal de piso: no todo el mundo
   tiene correo/Entra.

   Devuelve los usuarios que quedaron SIN credencial y su semilla de PIN
   inicial (ultimos 4 de la cedula, derivados de NationalIdMasked). La
   API hashea la semilla con PBKDF2 y llama a sec.usp_User_SetPin por
   usuario: T-SQL nunca hace criptografia de contrasenas.

   Empleados sin cedula en el origen quedan reportados en el segundo
   resultset: a esos el PIN se les asigna manualmente.

   Errores: 50002 sin permiso
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_User_ProvisionForEmployees
      @ActorUserId INT
    , @DefaultLocale NVARCHAR(10) = N'es-DO'
    , @UsersCreated INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();
        DECLARE @Created TABLE (UserId INT, EmployeeId INT);

        BEGIN TRANSACTION;

        INSERT INTO sec.[User] (EmployeeId, UserName, DisplayName, Email
                              , AuthMethod, PreferredLocale, IsActive, CreatedByUserId)
        OUTPUT inserted.UserId, inserted.EmployeeId INTO @Created (UserId, EmployeeId)
        SELECT  e.EmployeeId, e.EmployeeCode, e.FullName, e.Email
              , 2 /* Pin */, @DefaultLocale, 1, @ActorUserId
        FROM org.Employee e
        WHERE e.IsActive = 1
          AND NOT EXISTS (SELECT 1 FROM sec.[User] u
                          WHERE u.EmployeeId = e.EmployeeId AND u.IsDeleted = 0);

        SET @UsersCreated = @@ROWCOUNT;

        /* Rol base LEARNER a los recien creados (sus accesos se resuelven
           por pertenencia, no por permisos explicitos). */
        DECLARE @LearnerRoleId INT = (SELECT RoleId FROM sec.Role WHERE RoleCode = N'LEARNER');
        INSERT INTO sec.UserRoleAssignment (UserId, RoleId, ScopeType, AssignedByUserId)
        SELECT c.UserId, @LearnerRoleId, 1, @ActorUserId
        FROM @Created c
        WHERE @LearnerRoleId IS NOT NULL;

        EXEC aud.usp_Event_Log
              @EventType   = N'User.BulkProvisioned'
            , @EntityType  = N'User'
            , @ActorUserId = @ActorUserId
            , @Severity    = 3
            , @Summary     = N'Aprovisionamiento masivo de usuarios de piso.';

        COMMIT TRANSACTION;

        /* Resultset 1: usuarios pendientes de credencial + semilla de PIN
           (ultimos 4 de la cedula). Incluye usuarios de corridas
           anteriores que quedaron sin PIN. */
        SELECT  u.UserId
              , u.UserName AS EmployeeCode
              , u.DisplayName
              , RIGHT(e.NationalIdMasked, 4) AS PinSeed
        FROM sec.[User] u
        JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
        WHERE u.IsActive = 1 AND u.IsDeleted = 0
          AND u.AuthMethod IN (2, 3)
          AND e.NationalIdMasked IS NOT NULL
          AND LEN(e.NationalIdMasked) >= 4
          AND NOT EXISTS (SELECT 1 FROM sec.UserCredential c WHERE c.UserId = u.UserId);

        /* Resultset 2: sin cedula en el origen -> PIN manual */
        SELECT  u.UserId, u.UserName AS EmployeeCode, u.DisplayName
        FROM sec.[User] u
        JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
        WHERE u.IsActive = 1 AND u.IsDeleted = 0
          AND u.AuthMethod IN (2, 3)
          AND (e.NationalIdMasked IS NULL OR LEN(e.NationalIdMasked) < 4)
          AND NOT EXISTS (SELECT 1 FROM sec.UserCredential c WHERE c.UserId = u.UserId);

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_ProvisionForEmployees', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

PRINT '=== 11_procs_identity.sql completado ===';
GO
