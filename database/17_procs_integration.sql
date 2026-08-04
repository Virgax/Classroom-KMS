/* =====================================================================
   Classroom - LMS by Airlink
   17_procs_integration.sql
   Esquema: intg (sincronizacion con SPN y AIRLINK)

   Contexto real (ver doc 07):
     - SPN  = base de nomina/empleados. Solo lectura. Es la fuente de
              verdad de quien trabaja aqui.
     - AIRLINK = base de produccion (THOR, IQC, BoxShipping). Solo
              lectura. Da contexto operacional: estaciones, procesos.
     - AlLmsSyncUser es el unico principal con acceso a esas dos bases.

   Principios de este archivo:
     1. El LMS NUNCA escribe en SPN ni en AIRLINK. Jamas.
     2. El sync es idempotente: correrlo dos veces no duplica nada.
     3. El sync NUNCA borra empleados. Un empleado que sale se marca
        inactivo. Su expediente de entrenamiento se conserva 7 anos
        porque el auditor puede preguntar por el.
     4. Una fila mala no tumba la corrida: se manda a
        intg.IntegrationError y el resto sigue.

   Codigos de error de este archivo: 50600-50699
   ===================================================================== */

USE AIRLINK_KMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 17_procs_integration.sql iniciado ===';
GO

/* =====================================================================
   intg.usp_EmployeeSync_LoadStaging

   Carga la landing zone. El SELECT contra SPN se hace con linked server
   o, mejor, con un paquete/agente externo que llama a este SP con un
   TVP. Aqui se acepta JSON para no acoplar el SP a la forma exacta de
   las tablas de SPN, que no controlamos.
   ===================================================================== */
CREATE OR ALTER PROCEDURE intg.usp_EmployeeSync_LoadStaging
      @SyncRunId      BIGINT
    , @EmployeesJson  NVARCHAR(MAX)
    , @RowsLoaded     INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50601 payload invalido */
    BEGIN TRY
        IF ISJSON(@EmployeesJson) <> 1
            THROW 50601, 'El payload de empleados no es JSON valido.', 1;

        /* Staging se limpia por corrida: no es dato de negocio. */
        DELETE FROM intg.EmployeeStaging WHERE SyncRunId = @SyncRunId;

        INSERT INTO intg.EmployeeStaging (SyncRunId, SourceEmployeeCode, FirstName, LastName
                                        , FullNameRaw, NationalId, Email, PositionTitleRaw
                                        , DepartmentRaw, SiteRaw, SupervisorCodeRaw
                                        , HireDate, TerminationDate, EmploymentStatusRaw
                                        , SourceRowHash)
        SELECT  @SyncRunId
              , LTRIM(RTRIM(j.EmployeeCode))
              , NULLIF(LTRIM(RTRIM(j.FirstName)), N'')
              , NULLIF(LTRIM(RTRIM(j.LastName)), N'')
              , NULLIF(LTRIM(RTRIM(j.FullName)), N'')
              , NULLIF(LTRIM(RTRIM(j.NationalId)), N'')
              , NULLIF(LTRIM(RTRIM(j.Email)), N'')
              , NULLIF(LTRIM(RTRIM(j.PositionTitle)), N'')
              , NULLIF(LTRIM(RTRIM(j.Department)), N'')
              , NULLIF(LTRIM(RTRIM(j.Site)), N'')
              , NULLIF(LTRIM(RTRIM(j.SupervisorCode)), N'')
              , j.HireDate
              , j.TerminationDate
              , NULLIF(LTRIM(RTRIM(j.EmploymentStatus)), N'')
              /* Hash de la fila para saltar registros sin cambios reales.
                 Ahorra el 95% del trabajo en el sync incremental. */
              , HASHBYTES('SHA2_256'
                  , CONCAT(ISNULL(j.FirstName, N''), N'|', ISNULL(j.LastName, N''), N'|'
                         , ISNULL(j.Email, N''), N'|', ISNULL(j.PositionTitle, N''), N'|'
                         , ISNULL(j.Department, N''), N'|', ISNULL(j.Site, N''), N'|'
                         , ISNULL(j.SupervisorCode, N''), N'|'
                         , ISNULL(CONVERT(NVARCHAR(10), j.HireDate, 23), N''), N'|'
                         , ISNULL(CONVERT(NVARCHAR(10), j.TerminationDate, 23), N''), N'|'
                         , ISNULL(j.EmploymentStatus, N'')))
        FROM OPENJSON(@EmployeesJson) WITH (
              EmployeeCode     NVARCHAR(30)  N'$.employeeCode'
            , FirstName        NVARCHAR(80)  N'$.firstName'
            , LastName         NVARCHAR(80)  N'$.lastName'
            , FullName         NVARCHAR(200) N'$.fullName'
            , NationalId       NVARCHAR(30)  N'$.nationalId'
            , Email            NVARCHAR(200) N'$.email'
            , PositionTitle    NVARCHAR(150) N'$.positionTitle'
            , Department       NVARCHAR(150) N'$.department'
            , Site             NVARCHAR(100) N'$.site'
            , SupervisorCode   NVARCHAR(30)  N'$.supervisorCode'
            , HireDate         DATE          N'$.hireDate'
            , TerminationDate  DATE          N'$.terminationDate'
            , EmploymentStatus NVARCHAR(50)  N'$.employmentStatus'
        ) j
        WHERE NULLIF(LTRIM(RTRIM(j.EmployeeCode)), N'') IS NOT NULL;

        SET @RowsLoaded = @@ROWCOUNT;

        /* Validacion basica antes del merge. Lo invalido no se descarta:
           se marca, para que alguien lo vea y lo arregle en SPN. */
        UPDATE intg.EmployeeStaging
        SET IsValid = 0, ValidationMessage = N'Falta nombre o apellido y no hay nombre completo.'
        WHERE SyncRunId = @SyncRunId
          AND (FirstName IS NULL OR LastName IS NULL)
          AND FullNameRaw IS NULL;

        UPDATE intg.EmployeeStaging
        SET IsValid = 0, ValidationMessage = N'Codigo de empleado duplicado en el origen.'
        WHERE SyncRunId = @SyncRunId
          AND SourceEmployeeCode IN (
                SELECT SourceEmployeeCode FROM intg.EmployeeStaging
                WHERE SyncRunId = @SyncRunId
                GROUP BY SourceEmployeeCode HAVING COUNT(*) > 1);

        SELECT @RowsLoaded AS RowsLoaded
             , (SELECT COUNT(*) FROM intg.EmployeeStaging WHERE SyncRunId = @SyncRunId AND IsValid = 0) AS InvalidRows;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'intg.usp_EmployeeSync_LoadStaging';
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   intg.usp_EmployeeSync_Merge

   El corazon del sync. Reglas de negocio que costaron discusiones:

   - Match por EmployeeCode. Es la clave natural de SPN y no cambia.
   - Si SPN trae solo "fullName", se parte por el primer espacio. Es
     imperfecto con nombres compuestos dominicanos ("Jose Luis Perez
     Ramirez"), asi que preferimos siempre firstName/lastName separados.
   - Posiciones: SPN maneja titulos de texto libre. Se mapean contra
     org.Position por nombre; lo que no matchea crea una posicion con
     RequiresReview = 1 para que Calidad la revise en vez de perderla.
   - Terminacion: se marca IsActive = 0, se cierran asignaciones y se
     cancelan inscripciones abiertas. NO se borra nada.
   - Reingreso: si un empleado terminado vuelve a aparecer activo, se
     reactiva conservando su historial. Esto pasa mas de lo que uno cree.
   ===================================================================== */
CREATE OR ALTER PROCEDURE intg.usp_EmployeeSync_Merge
      @SyncRunId       BIGINT
    , @ActorUserId     INT = NULL
    , @DryRun          BIT = 0
    , @DeactivateMissing BIT = 0   -- solo tiene sentido en sync full
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME()
              , @Inserted INT = 0, @Updated INT = 0, @Skipped INT = 0
              , @Deactivated INT = 0, @Errored INT = 0;

        /* --- 1. Resolver referencias de texto a IDs ---------------- */
        DECLARE @Resolved TABLE (
              EmployeeStagingId  BIGINT PRIMARY KEY
            , SourceEmployeeCode NVARCHAR(30) NOT NULL
            , FirstName          NVARCHAR(80) NOT NULL
            , LastName           NVARCHAR(80) NOT NULL
            , Email              NVARCHAR(200) NULL
            , NationalIdMasked   NVARCHAR(20) NULL
            , SiteId             INT NULL
            , DepartmentId       INT NULL
            , PositionId         INT NULL
            , SupervisorEmployeeId INT NULL
            , HireDateUtc        DATETIME2(3) NULL
            , TerminationDateUtc DATETIME2(3) NULL
            , IsActive           BIT NOT NULL
            , SourceRowHash      BINARY(32) NULL
        );

        INSERT INTO @Resolved
        SELECT  st.EmployeeStagingId
              , st.SourceEmployeeCode
              , /* nombre */
                ISNULL(st.FirstName,
                       CASE WHEN CHARINDEX(N' ', st.FullNameRaw) > 0
                            THEN LEFT(st.FullNameRaw, CHARINDEX(N' ', st.FullNameRaw) - 1)
                            ELSE st.FullNameRaw END)
              , ISNULL(st.LastName,
                       CASE WHEN CHARINDEX(N' ', st.FullNameRaw) > 0
                            THEN LTRIM(SUBSTRING(st.FullNameRaw, CHARINDEX(N' ', st.FullNameRaw) + 1, 200))
                            ELSE N'.' END)
              , st.Email
              /* PII: solo los ultimos 4 de la cedula quedan visibles. */
              , CASE WHEN st.NationalId IS NULL THEN NULL
                     ELSE N'****' + RIGHT(st.NationalId, 4) END
              , s.SiteId
              , d.DepartmentId
              , p.PositionId
              , sup.EmployeeId
              , CAST(st.HireDate AS DATETIME2(3))
              , CAST(st.TerminationDate AS DATETIME2(3))
              /* Activo = sin fecha de terminacion pasada y estatus no
                 marcado como baja en el origen. */
              , CASE WHEN st.TerminationDate IS NOT NULL AND st.TerminationDate <= CAST(@NowUtc AS DATE) THEN 0
                     WHEN st.EmploymentStatusRaw IN (N'INACTIVO', N'INACTIVE', N'TERMINADO', N'TERMINATED', N'BAJA') THEN 0
                     ELSE 1 END
              , st.SourceRowHash
        FROM intg.EmployeeStaging st
        LEFT JOIN org.Site s        ON s.[Name] = st.SiteRaw OR s.SiteCode = st.SiteRaw
        LEFT JOIN org.Department d  ON d.[Name] = st.DepartmentRaw OR d.DepartmentCode = st.DepartmentRaw
        LEFT JOIN org.[Position] p  ON p.[Name] = st.PositionTitleRaw OR p.PositionCode = st.PositionTitleRaw
        LEFT JOIN org.Employee sup  ON sup.EmployeeCode = st.SupervisorCodeRaw
        WHERE st.SyncRunId = @SyncRunId AND st.IsValid = 1;

        /* --- 2. Posiciones nuevas detectadas en SPN ----------------
           No se pierde el titulo: se crea la posicion marcada para
           revision. Calidad decide despues que competencias exige. */
        IF @DryRun = 0
        BEGIN
            INSERT INTO org.[Position] (PositionCode, [Name], AffectsProductQuality
                                      , IsMappedFromSource, RequiresReview, IsActive)
            SELECT DISTINCT
                   LEFT(N'SPN-' + REPLACE(UPPER(st.PositionTitleRaw), N' ', N'-'), 40)
                 , st.PositionTitleRaw
                 , 0, 1, 1, 1
            FROM intg.EmployeeStaging st
            WHERE st.SyncRunId = @SyncRunId AND st.IsValid = 1
              AND st.PositionTitleRaw IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM org.[Position] p
                              WHERE p.[Name] = st.PositionTitleRaw
                                 OR p.PositionCode = LEFT(N'SPN-' + REPLACE(UPPER(st.PositionTitleRaw), N' ', N'-'), 40));

            /* Reintentar la resolucion con las posiciones recien creadas */
            UPDATE r
            SET r.PositionId = p.PositionId
            FROM @Resolved r
            JOIN intg.EmployeeStaging st ON st.EmployeeStagingId = r.EmployeeStagingId
            JOIN org.[Position] p ON p.[Name] = st.PositionTitleRaw
            WHERE r.PositionId IS NULL;
        END;

        /* --- 3. Errores de resolucion ------------------------------ */
        INSERT INTO intg.IntegrationError (SyncRunId, SourceSystem, SourceEntity, SourceKey
                                         , ErrorCode, ErrorMessage, PayloadJson)
        SELECT  @SyncRunId, N'SPN', N'Employee', r.SourceEmployeeCode
              , N'UNRESOLVED_REFERENCE'
              , N'No se pudo resolver: '
                + CASE WHEN r.SiteId IS NULL THEN N'sitio ' ELSE N'' END
                + CASE WHEN r.DepartmentId IS NULL THEN N'departamento ' ELSE N'' END
                + CASE WHEN r.SupervisorEmployeeId IS NULL THEN N'supervisor ' ELSE N'' END
              , (SELECT st.SiteRaw, st.DepartmentRaw, st.SupervisorCodeRaw, st.PositionTitleRaw
                 FROM intg.EmployeeStaging st WHERE st.EmployeeStagingId = r.EmployeeStagingId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        FROM @Resolved r
        WHERE r.SiteId IS NULL OR r.DepartmentId IS NULL;

        IF @DryRun = 1
        BEGIN
            SELECT  (SELECT COUNT(*) FROM @Resolved r
                     WHERE NOT EXISTS (SELECT 1 FROM org.Employee e WHERE e.EmployeeCode = r.SourceEmployeeCode)) AS WouldInsert
                  , (SELECT COUNT(*) FROM @Resolved r
                     JOIN org.Employee e ON e.EmployeeCode = r.SourceEmployeeCode
                     WHERE ISNULL(e.SourceHash, 0x) <> ISNULL(r.SourceRowHash, 0x)) AS WouldUpdate
                  , (SELECT COUNT(*) FROM @Resolved r
                     JOIN org.Employee e ON e.EmployeeCode = r.SourceEmployeeCode
                     WHERE ISNULL(e.SourceHash, 0x) = ISNULL(r.SourceRowHash, 0x)) AS WouldSkip;
            SELECT * FROM @Resolved;
            RETURN 0;
        END;

        /* --- 4. MERGE de empleados --------------------------------- */
        DECLARE @Changes TABLE (Action NVARCHAR(10), EmployeeId INT, WasActive BIT, IsActive BIT);

        BEGIN TRANSACTION;

        MERGE org.Employee AS tgt
        USING (SELECT * FROM @Resolved) AS src
        ON tgt.EmployeeCode = src.SourceEmployeeCode

        WHEN MATCHED AND ISNULL(tgt.SourceHash, 0x) <> ISNULL(src.SourceRowHash, 0x) THEN
            UPDATE SET
                  tgt.FirstName        = src.FirstName
                , tgt.LastName         = src.LastName
                , tgt.Email            = COALESCE(src.Email, tgt.Email)
                , tgt.NationalIdMasked = COALESCE(src.NationalIdMasked, tgt.NationalIdMasked)
                , tgt.SiteId           = COALESCE(src.SiteId, tgt.SiteId)
                , tgt.DepartmentId     = COALESCE(src.DepartmentId, tgt.DepartmentId)
                , tgt.SupervisorEmployeeId = COALESCE(src.SupervisorEmployeeId, tgt.SupervisorEmployeeId)
                , tgt.HireDateUtc      = COALESCE(src.HireDateUtc, tgt.HireDateUtc)
                , tgt.TerminationDateUtc = src.TerminationDateUtc
                , tgt.IsActive         = src.IsActive
                , tgt.SourceHash       = src.SourceRowHash
                , tgt.LastSyncedAtUtc  = @NowUtc
                , tgt.ModifiedAtUtc    = @NowUtc
                , tgt.ModifiedByUserId = @ActorUserId

        WHEN NOT MATCHED BY TARGET THEN
            INSERT (EmployeeCode, FirstName, LastName, Email, NationalIdMasked
                  , SiteId, DepartmentId, PrimaryPositionId, SupervisorEmployeeId
                  , HireDateUtc, TerminationDateUtc, IsActive
                  , SourceSystem, SourceHash, LastSyncedAtUtc, CreatedByUserId)
            VALUES (src.SourceEmployeeCode, src.FirstName, src.LastName, src.Email, src.NationalIdMasked
                  , src.SiteId, src.DepartmentId, src.PositionId, src.SupervisorEmployeeId
                  , src.HireDateUtc, src.TerminationDateUtc, src.IsActive
                  , N'SPN', src.SourceRowHash, @NowUtc, @ActorUserId)

        OUTPUT $action, inserted.EmployeeId, deleted.IsActive, inserted.IsActive
        INTO @Changes (Action, EmployeeId, WasActive, IsActive);

        SELECT @Inserted = SUM(CASE WHEN Action = N'INSERT' THEN 1 ELSE 0 END)
             , @Updated  = SUM(CASE WHEN Action = N'UPDATE' THEN 1 ELSE 0 END)
        FROM @Changes;

        SELECT @Skipped = COUNT(*) FROM @Resolved r
        JOIN org.Employee e ON e.EmployeeCode = r.SourceEmployeeCode
        WHERE NOT EXISTS (SELECT 1 FROM @Changes c WHERE c.EmployeeId = e.EmployeeId);

        /* --- 4b. Supervisores: segunda pasada -----------------------
           En la carga inicial (o cuando jefe y subordinado vienen en el
           mismo lote) el supervisor no existia al resolver la fila. Se
           re-resuelve contra org.Employee ya poblado; aplica a TODO el
           staging del lote, no solo a los cambiados. */
        UPDATE e
        SET e.SupervisorEmployeeId = sup.EmployeeId
          , e.ModifiedAtUtc = @NowUtc, e.ModifiedByUserId = @ActorUserId
        FROM org.Employee e
        JOIN intg.EmployeeStaging st ON st.SourceEmployeeCode = e.EmployeeCode
                                    AND st.SyncRunId = @SyncRunId AND st.IsValid = 1
        JOIN org.Employee sup ON sup.EmployeeCode = st.SupervisorCodeRaw
        WHERE ISNULL(e.SupervisorEmployeeId, -1) <> sup.EmployeeId;

        /* --- 5. Posiciones ----------------------------------------- */
        /* Cerrar la posicion primaria anterior si cambio, y abrir la nueva.
           org.EmployeePosition es historia: nunca se sobreescribe. */
        UPDATE ep
        SET ep.EffectiveToUtc = @NowUtc
        FROM org.EmployeePosition ep
        JOIN org.Employee e ON e.EmployeeId = ep.EmployeeId
        JOIN @Resolved r ON r.SourceEmployeeCode = e.EmployeeCode
        WHERE ep.IsPrimary = 1 AND ep.EffectiveToUtc IS NULL
          AND r.PositionId IS NOT NULL AND ep.PositionId <> r.PositionId;

        INSERT INTO org.EmployeePosition (EmployeeId, PositionId, IsPrimary, EffectiveFromUtc, AssignedByUserId, Notes)
        SELECT e.EmployeeId, r.PositionId, 1, @NowUtc, @ActorUserId, N'Sincronizado desde SPN.'
        FROM @Resolved r
        JOIN org.Employee e ON e.EmployeeCode = r.SourceEmployeeCode
        WHERE r.PositionId IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM org.EmployeePosition ep
                          WHERE ep.EmployeeId = e.EmployeeId AND ep.PositionId = r.PositionId
                            AND ep.EffectiveToUtc IS NULL);

        UPDATE e
        SET e.PrimaryPositionId = r.PositionId
        FROM org.Employee e
        JOIN @Resolved r ON r.SourceEmployeeCode = e.EmployeeCode
        WHERE r.PositionId IS NOT NULL AND ISNULL(e.PrimaryPositionId, -1) <> r.PositionId;

        /* --- 6. Bajas ---------------------------------------------- */
        /* Cerrar asignaciones y cancelar inscripciones abiertas de quien
           salio. El expediente completo se conserva. */
        UPDATE ea
        SET ea.EffectiveToUtc = @NowUtc
        FROM org.EmployeeAssignment ea
        JOIN @Changes c ON c.EmployeeId = ea.EmployeeId
        WHERE c.IsActive = 0 AND ISNULL(c.WasActive, 1) = 1 AND ea.EffectiveToUtc IS NULL;

        UPDATE en
        SET en.[Status] = 5, en.WithdrawnAtUtc = @NowUtc
          , en.WithdrawReason = N'Empleado inactivo en el sistema de nomina.'
          , en.ModifiedAtUtc = @NowUtc
        FROM dlv.Enrollment en
        JOIN @Changes c ON c.EmployeeId = en.EmployeeId
        WHERE c.IsActive = 0 AND ISNULL(c.WasActive, 1) = 1 AND en.[Status] IN (1, 2);

        UPDATE u
        SET u.IsActive = 0, u.ModifiedAtUtc = @NowUtc
        FROM sec.[User] u
        JOIN @Changes c ON c.EmployeeId = u.EmployeeId
        WHERE c.IsActive = 0 AND u.IsActive = 1;

        /* Reingreso: el empleado vuelve activo -> su usuario tambien.
           Su historial y certificaciones no vencidas siguen validas. */
        UPDATE u
        SET u.IsActive = 1, u.ModifiedAtUtc = @NowUtc
        FROM sec.[User] u
        JOIN @Changes c ON c.EmployeeId = u.EmployeeId
        WHERE c.IsActive = 1 AND ISNULL(c.WasActive, 1) = 0 AND u.IsActive = 0 AND u.IsDeleted = 0;

        SELECT @Deactivated = COUNT(*) FROM @Changes WHERE IsActive = 0 AND ISNULL(WasActive, 1) = 1;

        /* Sync full: quien ya no aparece en SPN se desactiva. NUNCA se
           borra, y solo aplica en modo full para no matar gente por un
           incremental incompleto. */
        IF @DeactivateMissing = 1
        BEGIN
            UPDATE e
            SET e.IsActive = 0, e.ModifiedAtUtc = @NowUtc, e.ModifiedByUserId = @ActorUserId
            FROM org.Employee e
            WHERE e.SourceSystem = N'SPN' AND e.IsActive = 1
              AND NOT EXISTS (SELECT 1 FROM @Resolved r WHERE r.SourceEmployeeCode = e.EmployeeCode);
            SET @Deactivated = @Deactivated + @@ROWCOUNT;
        END;

        /* --- 7. Cierre de la corrida ------------------------------- */
        UPDATE intg.SyncRun
        SET RowsRead = (SELECT COUNT(*) FROM intg.EmployeeStaging WHERE SyncRunId = @SyncRunId)
          , RowsInserted = ISNULL(@Inserted, 0)
          , RowsUpdated  = ISNULL(@Updated, 0)
          , RowsSkipped  = ISNULL(@Skipped, 0)
          , RowsErrored  = (SELECT COUNT(*) FROM intg.IntegrationError WHERE SyncRunId = @SyncRunId)
          , [Status] = CASE WHEN (SELECT COUNT(*) FROM intg.IntegrationError WHERE SyncRunId = @SyncRunId) > 0
                            THEN 4 ELSE 2 END
          , CompletedAtUtc = @NowUtc
        WHERE SyncRunId = @SyncRunId;

        UPDATE intg.SyncWatermark
        SET WatermarkValue = CONVERT(NVARCHAR(30), @NowUtc, 126)
          , LastSuccessAtUtc = @NowUtc, LastRunAtUtc = @NowUtc
          , LastRowCount = ISNULL(@Inserted, 0) + ISNULL(@Updated, 0)
          , ConsecutiveFailures = 0, ModifiedAtUtc = @NowUtc
        WHERE SourceSystem = N'SPN' AND SourceEntity = N'Employee';

        EXEC aud.usp_Event_Log
              @EventType   = N'EmployeeSync.Completed'
            , @EntityType  = N'SyncRun'
            , @EntityId    = NULL
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Sincronizacion de empleados completada.';

        COMMIT TRANSACTION;

        /* --- 8. Recalcular compliance de los que cambiaron ---------
           Fuera de la transaccion. Un empleado que cambio de puesto
           tiene requisitos distintos desde ya. */
        DECLARE @EmpId INT;
        DECLARE ch CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT EmployeeId FROM @Changes WHERE IsActive = 1;
        OPEN ch; FETCH NEXT FROM ch INTO @EmpId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                EXEC comp.usp_Gap_RecalculateForEmployee
                      @ActorUserId = @ActorUserId, @EmployeeId = @EmpId, @AutoEnroll = 1;
            END TRY
            BEGIN CATCH
                EXEC aud.usp_Error_Log @ProcedureName = N'intg.usp_EmployeeSync_Merge', @ActorUserId = @ActorUserId;
            END CATCH;
            FETCH NEXT FROM ch INTO @EmpId;
        END;
        CLOSE ch; DEALLOCATE ch;

        SELECT  ISNULL(@Inserted, 0)    AS RowsInserted
              , ISNULL(@Updated, 0)     AS RowsUpdated
              , ISNULL(@Skipped, 0)     AS RowsSkipped
              , ISNULL(@Deactivated, 0) AS RowsDeactivated
              , (SELECT COUNT(*) FROM intg.IntegrationError WHERE SyncRunId = @SyncRunId) AS RowsErrored;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        UPDATE intg.SyncRun
        SET [Status] = 3, ErrorMessage = ERROR_MESSAGE(), CompletedAtUtc = SYSUTCDATETIME()
        WHERE SyncRunId = @SyncRunId;

        UPDATE intg.SyncWatermark
        SET ConsecutiveFailures = ConsecutiveFailures + 1, LastRunAtUtc = SYSUTCDATETIME()
        WHERE SourceSystem = N'SPN' AND SourceEntity = N'Employee';

        EXEC aud.usp_Error_Log @ProcedureName = N'intg.usp_EmployeeSync_Merge', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   intg.usp_EmployeeSync_Run   -- orquestador (lo llama el job)
   ===================================================================== */
CREATE OR ALTER PROCEDURE intg.usp_EmployeeSync_Run
      @ActorUserId   INT = NULL
    , @RunMode       TINYINT = 1        -- 1=Incremental 2=Full 3=Manual
    , @EmployeesJson NVARCHAR(MAX) = NULL
    , @TriggeredBy   NVARCHAR(100) = N'SqlAgent'
    , @SyncRunId     BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50602 ya hay una corrida en progreso */
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM intg.SyncRun
                   WHERE SourceSystem = N'SPN' AND SourceEntity = N'Employee'
                     AND [Status] = 1
                     AND StartedAtUtc > DATEADD(HOUR, -2, SYSUTCDATETIME()))
            THROW 50602, 'Ya hay una sincronizacion de empleados en progreso.', 1;

        DECLARE @Watermark NVARCHAR(100), @RowsLoaded INT;

        SELECT @Watermark = WatermarkValue FROM intg.SyncWatermark
        WHERE SourceSystem = N'SPN' AND SourceEntity = N'Employee';

        INSERT INTO intg.SyncRun (SourceSystem, SourceEntity, RunMode, [Status]
                                , WatermarkFrom, TriggeredBy)
        VALUES (N'SPN', N'Employee', @RunMode, 1
              , CASE WHEN @RunMode = 2 THEN NULL ELSE @Watermark END, @TriggeredBy);

        SET @SyncRunId = SCOPE_IDENTITY();

        /* Si no viene payload, el agente externo lo entrega llamando a
           LoadStaging con este @SyncRunId. Devolvemos el id y salimos. */
        IF @EmployeesJson IS NULL
        BEGIN
            SELECT @SyncRunId AS SyncRunId, N'Awaiting staging load' AS [Status];
            RETURN 0;
        END;

        EXEC intg.usp_EmployeeSync_LoadStaging
              @SyncRunId = @SyncRunId, @EmployeesJson = @EmployeesJson
            , @RowsLoaded = @RowsLoaded OUTPUT;

        DECLARE @DeactivateMissing BIT = CASE WHEN @RunMode = 2 THEN 1 ELSE 0 END;
        EXEC intg.usp_EmployeeSync_Merge
              @SyncRunId = @SyncRunId, @ActorUserId = @ActorUserId
            , @DeactivateMissing = @DeactivateMissing;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @SyncRunId IS NOT NULL
            UPDATE intg.SyncRun
            SET [Status] = 3, ErrorMessage = ERROR_MESSAGE(), CompletedAtUtc = SYSUTCDATETIME()
            WHERE SyncRunId = @SyncRunId;
        EXEC aud.usp_Error_Log @ProcedureName = N'intg.usp_EmployeeSync_Run', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   intg.usp_ProductionContext_GetForEmployee

   Puente de lectura hacia AIRLINK. Devuelve donde ha estado trabajando
   el empleado segun produccion, para cruzarlo con lo que esta
   certificado para hacer.

   Este SP es el que destapa el hallazgo incomodo: "el operador X lleva
   3 semanas en la estacion RXR-01 y su certificacion vencio hace 40
   dias". Mejor que lo encuentre el sistema y no el auditor.

   NOTA DE IMPLEMENTACION: el acceso a AIRLINK se hace por linked server
   o por vista sinonimo creada con AlLmsSyncUser. Aqui se deja el
   contrato y la logica de cruce; la fuente concreta se conecta en el
   deploy segun como quede configurado el enlace (ver doc 07 seccion 3).
   ===================================================================== */
CREATE OR ALTER PROCEDURE intg.usp_ProductionContext_GetForEmployee
      @ActorUserId INT
    , @EmployeeId  INT
    , @DaysBack    INT = 30
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @FromUtc DATETIME2(3) = DATEADD(DAY, -@DaysBack, SYSUTCDATETIME());

        /* 1. Estaciones donde el LMS sabe que estuvo asignado */
        SELECT  ea.StationId, s.StationCode, s.[Name] AS StationName
              , s.ProcessCode, s.EquipmentName
              , s.RequiresGating, s.GatingMode
              , ea.EffectiveFromUtc, ea.EffectiveToUtc
        FROM org.EmployeeAssignment ea
        JOIN org.Station s ON s.StationId = ea.StationId
        WHERE ea.EmployeeId = @EmployeeId
          AND (ea.EffectiveToUtc IS NULL OR ea.EffectiveToUtc >= @FromUtc)
        ORDER BY ea.EffectiveFromUtc DESC;

        /* 2. Elegibilidad para cada una de esas estaciones */
        SELECT  s.StationId, s.StationCode
              , SUM(CASE WHEN g.CompetencyGapId IS NOT NULL AND sc.IsBlocking = 1
                          AND ISNULL(g.HasActiveWaiver, 0) = 0 THEN 1 ELSE 0 END) AS BlockingGaps
              , SUM(CASE WHEN g.CompetencyGapId IS NOT NULL THEN 1 ELSE 0 END) AS TotalGaps
              , CASE WHEN SUM(CASE WHEN g.CompetencyGapId IS NOT NULL AND sc.IsBlocking = 1
                                    AND ISNULL(g.HasActiveWaiver, 0) = 0 THEN 1 ELSE 0 END) > 0
                     THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS IsEligible
        FROM org.EmployeeAssignment ea
        JOIN org.Station s ON s.StationId = ea.StationId
        LEFT JOIN comp.StationCompetency sc ON sc.StationId = s.StationId
        LEFT JOIN comp.CompetencyGap g ON g.RequirementId = sc.RequirementId
                                      AND g.EmployeeId = @EmployeeId AND g.ResolvedAtUtc IS NULL
        WHERE ea.EmployeeId = @EmployeeId AND ea.EffectiveToUtc IS NULL
        GROUP BY s.StationId, s.StationCode;

        /* 3. Historial de decisiones de gating: la evidencia de si el
              operador estuvo trabajando sin certificacion vigente. */
        SELECT TOP (100)
                gl.EvaluatedAtUtc, gl.StationId, s.StationCode
              , gl.Decision, gl.GatingMode, gl.WasEnforced, gl.RequestSource
        FROM comp.GatingDecisionLog gl
        LEFT JOIN org.Station s ON s.StationId = gl.StationId
        WHERE gl.EmployeeId = @EmployeeId AND gl.EvaluatedAtUtc >= @FromUtc
        ORDER BY gl.EvaluatedAtUtc DESC;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'intg.usp_ProductionContext_GetForEmployee', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Utilitarios de integracion
   ===================================================================== */
CREATE OR ALTER PROCEDURE intg.usp_Watermark_Get
      @SourceSystem NVARCHAR(50) = NULL, @SourceEntity NVARCHAR(80) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SyncWatermarkId, SourceSystem, SourceEntity, WatermarkValue
         , LastSuccessAtUtc, LastRunAtUtc, LastRowCount, ConsecutiveFailures, IsEnabled
    FROM intg.SyncWatermark
    WHERE (@SourceSystem IS NULL OR SourceSystem = @SourceSystem)
      AND (@SourceEntity IS NULL OR SourceEntity = @SourceEntity)
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE intg.usp_EmployeeSync_GetLastRun
      @ActorUserId INT = NULL, @Top INT = 10
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top)
           r.SyncRunId, r.RunMode, r.[Status], r.RowsRead, r.RowsInserted
         , r.RowsUpdated, r.RowsSkipped, r.RowsErrored
         , r.StartedAtUtc, r.CompletedAtUtc, r.DurationMs, r.TriggeredBy, r.ErrorMessage
    FROM intg.SyncRun r
    WHERE r.SourceSystem = N'SPN' AND r.SourceEntity = N'Employee'
    ORDER BY r.SyncRunId DESC;

    /* Errores abiertos: lo que un humano tiene que ir a arreglar en SPN. */
    SELECT TOP (100)
           e.IntegrationErrorId, e.SyncRunId, e.SourceKey, e.ErrorCode
         , e.ErrorMessage, e.PayloadJson, e.OccurredAtUtc
    FROM intg.IntegrationError e
    WHERE e.IsResolved = 0 AND e.SourceEntity = N'Employee'
    ORDER BY e.OccurredAtUtc DESC;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE intg.usp_ExternalId_Map
      @ActorUserId INT = NULL, @SourceSystem NVARCHAR(50), @EntityType NVARCHAR(60)
    , @InternalId INT, @ExternalId NVARCHAR(100), @ExternalCode NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    MERGE intg.ExternalIdMap AS tgt
    USING (SELECT @SourceSystem AS S, @EntityType AS E, @ExternalId AS X) AS src
    ON tgt.SourceSystem = src.S AND tgt.EntityType = src.E AND tgt.ExternalId = src.X
    WHEN MATCHED THEN UPDATE SET
          InternalId = @InternalId, ExternalCode = @ExternalCode
        , IsActive = 1, ModifiedAtUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (SourceSystem, EntityType, InternalId, ExternalId, ExternalCode)
        VALUES (@SourceSystem, @EntityType, @InternalId, @ExternalId, @ExternalCode);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE intg.usp_IntegrationError_Log
      @SyncRunId BIGINT = NULL, @SourceSystem NVARCHAR(50), @SourceEntity NVARCHAR(80)
    , @SourceKey NVARCHAR(100) = NULL, @ErrorCode NVARCHAR(40) = NULL
    , @ErrorMessage NVARCHAR(MAX), @PayloadJson NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO intg.IntegrationError (SyncRunId, SourceSystem, SourceEntity, SourceKey
                                     , ErrorCode, ErrorMessage, PayloadJson)
    VALUES (@SyncRunId, @SourceSystem, @SourceEntity, @SourceKey
          , @ErrorCode, @ErrorMessage, @PayloadJson);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE intg.usp_IntegrationError_Resolve
      @ActorUserId INT, @IntegrationErrorId BIGINT, @ResolutionNote NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE intg.IntegrationError
    SET IsResolved = 1, ResolvedByUserId = @ActorUserId
      , ResolvedAtUtc = SYSUTCDATETIME(), ResolutionNote = @ResolutionNote
    WHERE IntegrationErrorId = @IntegrationErrorId;
    RETURN 0;
END;
GO

PRINT '=== 17_procs_integration.sql completado ===';
GO
