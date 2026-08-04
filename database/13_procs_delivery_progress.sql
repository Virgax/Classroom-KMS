/* =====================================================================
   Classroom - LMS by Airlink
   13_procs_delivery_progress.sql
   Esquema: dlv (inscripciones, progreso, cohortes, ILT presencial)

   GAP-04: la sesion presencial es ciudadano de primera clase. ~70% del
   entrenamiento real de Airlink pasa en el piso con un instructor, no
   frente a una pantalla. Todo lo que aplica a un curso online aplica
   igual a una sesion ILT: evidencia, firma, y credito de competencia.

   Codigos de error de este archivo: 50300-50399
   ===================================================================== */

USE AIRLINK_KMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 13_procs_delivery_progress.sql iniciado ===';
GO

/* =====================================================================
   dlv.usp_Enrollment_Create

   Congela CourseVersionId al inscribir. Si el curso se republica manana,
   este operador sigue viendo lo que se le asigno hoy.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Create
      @ActorUserId    INT
    , @EmployeeId     INT
    , @CourseId       INT
    , @Source         TINYINT          = 2
    , @SourceRequirementId INT         = NULL
    , @CohortId       INT              = NULL
    , @ProgramId      INT              = NULL
    , @DueAtUtc       DATETIME2(3)     = NULL
    , @AllowDuplicate BIT              = 0
    , @IdempotencyKey UNIQUEIDENTIFIER = NULL
    , @EnrollmentId   INT              = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------
       Proposito : inscribir un empleado en la version vigente de un curso.
       Retorna   : EnrollmentId (OUTPUT) + fila de la inscripcion.
       Errores   : 50301 curso sin version publicada
                   50302 ya existe inscripcion activa
                   50303 empleado inactivo
                   50304 prerrequisito de programa no cumplido
       --------------------------------------------------------------- */

    BEGIN TRY
        IF @ActorUserId IS NULL THROW 50010, 'ActorUserId es requerido.', 1;

        /* Auto-inscripcion permitida solo si el curso lo habilita. */
        DECLARE @IsSelf BIT = CASE WHEN EXISTS (SELECT 1 FROM sec.[User] u
                                                WHERE u.UserId = @ActorUserId AND u.EmployeeId = @EmployeeId)
                                   THEN 1 ELSE 0 END;

        IF @IsSelf = 0 AND sec.fn_UserHasPermission(@ActorUserId, N'enrollment.assign') = 0
            THROW 50002, 'El usuario no tiene permiso para inscribir a otros empleados.', 1;

        IF @IsSelf = 1 AND @Source = 3
           AND NOT EXISTS (SELECT 1 FROM lms.Course WHERE CourseId = @CourseId AND AllowSelfEnrollment = 1)
            THROW 50002, 'Este curso no admite auto-inscripcion.', 1;

        IF @IdempotencyKey IS NOT NULL
           AND EXISTS (SELECT 1 FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey)
        BEGIN
            SELECT @EnrollmentId = ResultEntityId FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey;
            RETURN 0;
        END;

        IF NOT EXISTS (SELECT 1 FROM org.Employee WHERE EmployeeId = @EmployeeId AND IsActive = 1)
            THROW 50303, 'El empleado no existe o esta inactivo.', 1;

        DECLARE @CourseVersionId INT, @PreviousEnrollmentId INT, @AttemptNumber TINYINT = 1;

        SELECT @CourseVersionId = CurrentVersionId FROM lms.Course
        WHERE CourseId = @CourseId AND IsDeleted = 0 AND [Status] = 2;

        IF @CourseVersionId IS NULL
            THROW 50301, 'El curso no tiene una version publicada vigente.', 1;

        IF @AllowDuplicate = 0
           AND EXISTS (SELECT 1 FROM dlv.Enrollment
                       WHERE EmployeeId = @EmployeeId AND CourseId = @CourseId AND [Status] IN (1,2))
            THROW 50302, 'El empleado ya tiene una inscripcion activa en este curso.', 1;

        /* Reintento: nunca se sobreescribe la inscripcion anterior. */
        SELECT TOP (1) @PreviousEnrollmentId = EnrollmentId, @AttemptNumber = AttemptNumber + 1
        FROM dlv.Enrollment
        WHERE EmployeeId = @EmployeeId AND CourseId = @CourseId
        ORDER BY EnrollmentId DESC;

        SET @AttemptNumber = ISNULL(@AttemptNumber, 1);

        /* Prerrequisitos de programa con secuencia forzada. */
        IF @ProgramId IS NOT NULL
           AND EXISTS (SELECT 1 FROM lms.Program WHERE ProgramId = @ProgramId AND EnforceSequence = 1)
           AND EXISTS (
                SELECT 1
                FROM lms.ProgramCourse pc
                JOIN lms.ProgramCourse prereq ON prereq.ProgramCourseId = pc.PrerequisiteProgramCourseId
                WHERE pc.ProgramId = @ProgramId AND pc.CourseId = @CourseId
                  AND NOT EXISTS (
                        SELECT 1 FROM dlv.Enrollment e
                        WHERE e.EmployeeId = @EmployeeId AND e.CourseId = prereq.CourseId
                          AND e.[Status] = 3 AND e.IsPassed = 1))
            THROW 50304, 'Falta completar el curso prerrequisito del programa.', 1;

        BEGIN TRANSACTION;

        INSERT INTO dlv.Enrollment (EmployeeId, CourseId, CourseVersionId, CohortId, ProgramId
                                  , [Source], SourceRequirementId, [Status], AttemptNumber
                                  , AssignedByUserId, DueAtUtc, PreviousEnrollmentId)
        VALUES (@EmployeeId, @CourseId, @CourseVersionId, @CohortId, @ProgramId
              , @Source, @SourceRequirementId, 1, @AttemptNumber
              , @ActorUserId, @DueAtUtc, @PreviousEnrollmentId);

        SET @EnrollmentId = SCOPE_IDENTITY();

        /* Sembrar el progreso: modulos y items del arbol congelado.
           Hacerlo ahora evita nulls y hace baratos los reportes. */
        INSERT INTO dlv.ModuleProgress (EnrollmentId, CourseModuleId, [Status], ItemsTotal, UnlockedAtUtc)
        SELECT  @EnrollmentId
              , m.CourseModuleId
              , CASE WHEN m.PrerequisiteModuleId IS NULL THEN 2 ELSE 1 END   -- 2=Available 1=Locked
              , (SELECT COUNT(*) FROM lms.ModuleItem i
                 WHERE i.CourseModuleId = m.CourseModuleId AND i.IsDeleted = 0 AND i.IsRequiredForCompletion = 1)
              , CASE WHEN m.PrerequisiteModuleId IS NULL THEN SYSUTCDATETIME() ELSE NULL END
        FROM lms.CourseModule m
        WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0;

        INSERT INTO dlv.ItemProgress (EnrollmentId, ModuleItemId, [Status])
        SELECT @EnrollmentId, i.ModuleItemId, 1
        FROM lms.ModuleItem i
        JOIN lms.CourseModule m ON m.CourseModuleId = i.CourseModuleId
        WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0 AND i.IsDeleted = 0;

        IF @IdempotencyKey IS NOT NULL
            INSERT INTO aud.IdempotencyKey (IdempotencyKey, OperationName, ActorUserId, ResultEntityId)
            VALUES (@IdempotencyKey, N'dlv.usp_Enrollment_Create', @ActorUserId, @EnrollmentId);

        EXEC aud.usp_Event_Log
              @EventType   = N'Enrollment.Created'
            , @EntityType  = N'Enrollment'
            , @EntityId    = @EnrollmentId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Summary     = N'Inscripcion creada.';

        COMMIT TRANSACTION;

        EXEC ops.usp_Notification_Enqueue
              @TemplateCode = N'Enrollment.Assigned'
            , @RecipientEmployeeId = @EmployeeId
            , @Priority = 2
            , @DedupeKey = NULL;

        SELECT e.EnrollmentId, e.PublicId, e.EmployeeId, e.CourseId, e.CourseVersionId
             , e.[Status], e.AttemptNumber, e.DueAtUtc, e.AssignedAtUtc
        FROM dlv.Enrollment e WHERE e.EnrollmentId = @EnrollmentId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Progress_CompleteItem

   Marca un item como completado, recalcula el modulo, desbloquea el
   siguiente si aplica, recalcula la inscripcion y — si todo cerro —
   dispara la evaluacion de certificacion.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Progress_CompleteItem
      @ActorUserId      INT
    , @EnrollmentId     INT
    , @ModuleItemId     INT
    , @ScorePercent     DECIMAL(5,2) = NULL
    , @TimeSpentSeconds INT          = NULL
    , @VideoWatchedPercent DECIMAL(5,2) = NULL
    , @IdempotencyKey   UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50310 item bloqueado por secuencia
                50311 tiempo minimo no cumplido (anti-skip)
                50312 porcentaje de video insuficiente
                50313 puntaje bajo el minimo del item                    */
    BEGIN TRY
        DECLARE @EmployeeId INT, @CourseVersionId INT, @CourseId INT
              , @CourseModuleId INT, @EnrollmentStatus TINYINT
              , @EnforceSequence BIT, @EnforceMinimumTime BIT
              , @MinimumSeconds INT, @MinimumScore DECIMAL(5,2)
              , @ItemRequired BIT, @ModuleStatus TINYINT
              , @RequiredWatch DECIMAL(5,2), @ItemType TINYINT, @TargetId INT;

        SELECT  @EmployeeId = e.EmployeeId, @CourseVersionId = e.CourseVersionId
              , @CourseId = e.CourseId, @EnrollmentStatus = e.[Status]
              , @EnforceSequence = v.EnforceSequence, @EnforceMinimumTime = v.EnforceMinimumTime
        FROM dlv.Enrollment e
        JOIN lms.CourseVersion v ON v.CourseVersionId = e.CourseVersionId
        WHERE e.EnrollmentId = @EnrollmentId;

        IF @EmployeeId IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;
        IF @EnrollmentStatus NOT IN (1,2) THROW 50305, 'La inscripcion no esta activa.', 1;

        IF NOT EXISTS (SELECT 1 FROM sec.[User] u WHERE u.UserId = @ActorUserId AND u.EmployeeId = @EmployeeId)
           AND sec.fn_UserHasPermission(@ActorUserId, N'progress.override') = 0
            THROW 50002, 'El usuario no tiene permiso para modificar este progreso.', 1;

        SELECT  @CourseModuleId = i.CourseModuleId, @MinimumSeconds = i.MinimumSeconds
              , @MinimumScore = i.MinimumScore, @ItemRequired = i.IsRequiredForCompletion
              , @ItemType = i.ItemType, @TargetId = i.TargetId
        FROM lms.ModuleItem i WHERE i.ModuleItemId = @ModuleItemId;

        IF @CourseModuleId IS NULL THROW 50001, 'Item no encontrado.', 1;

        SELECT @ModuleStatus = mp.[Status]
        FROM dlv.ModuleProgress mp
        WHERE mp.EnrollmentId = @EnrollmentId AND mp.CourseModuleId = @CourseModuleId;

        IF @EnforceSequence = 1 AND @ModuleStatus = 1
            THROW 50310, 'El modulo esta bloqueado. Complete el modulo prerrequisito.', 1;

        IF @EnforceMinimumTime = 1 AND @MinimumSeconds IS NOT NULL
           AND ISNULL(@TimeSpentSeconds, 0) < @MinimumSeconds
            THROW 50311, 'No se cumplio el tiempo minimo de lectura del contenido.', 1;

        IF @ItemType = 3 AND @TargetId IS NOT NULL   -- 3 = Video
        BEGIN
            SELECT @RequiredWatch = RequiredWatchPercent FROM lms.VideoAsset WHERE VideoAssetId = @TargetId;
            IF @RequiredWatch IS NOT NULL AND ISNULL(@VideoWatchedPercent, 0) < @RequiredWatch
                THROW 50312, 'No se alcanzo el porcentaje minimo de reproduccion del video.', 1;
        END;

        IF @MinimumScore IS NOT NULL AND ISNULL(@ScorePercent, 0) < @MinimumScore
            THROW 50313, 'El puntaje obtenido esta por debajo del minimo requerido para este item.', 1;

        BEGIN TRANSACTION;

        UPDATE dlv.ItemProgress
        SET  [Status] = 3
           , ScorePercent = COALESCE(@ScorePercent, ScorePercent)
           , TimeSpentSeconds = TimeSpentSeconds + ISNULL(@TimeSpentSeconds, 0)
           , VideoWatchedPercent = COALESCE(@VideoWatchedPercent, VideoWatchedPercent)
           , ViewCount = ViewCount + 1
           , FirstAccessedAtUtc = ISNULL(FirstAccessedAtUtc, SYSUTCDATETIME())
           , LastAccessedAtUtc = SYSUTCDATETIME()
           , CompletedAtUtc = ISNULL(CompletedAtUtc, SYSUTCDATETIME())
        WHERE EnrollmentId = @EnrollmentId AND ModuleItemId = @ModuleItemId;

        IF @@ROWCOUNT = 0
            INSERT INTO dlv.ItemProgress (EnrollmentId, ModuleItemId, [Status], ScorePercent
                                        , TimeSpentSeconds, VideoWatchedPercent, ViewCount
                                        , FirstAccessedAtUtc, LastAccessedAtUtc, CompletedAtUtc)
            VALUES (@EnrollmentId, @ModuleItemId, 3, @ScorePercent, ISNULL(@TimeSpentSeconds,0)
                  , @VideoWatchedPercent, 1, SYSUTCDATETIME(), SYSUTCDATETIME(), SYSUTCDATETIME());

        /* Recalcular el modulo */
        DECLARE @ItemsTotal INT, @ItemsDone INT;

        SELECT  @ItemsTotal = COUNT(*)
              , @ItemsDone  = SUM(CASE WHEN ip.[Status] = 3 THEN 1 ELSE 0 END)
        FROM lms.ModuleItem i
        LEFT JOIN dlv.ItemProgress ip ON ip.ModuleItemId = i.ModuleItemId AND ip.EnrollmentId = @EnrollmentId
        WHERE i.CourseModuleId = @CourseModuleId AND i.IsDeleted = 0 AND i.IsRequiredForCompletion = 1;

        UPDATE dlv.ModuleProgress
        SET  ItemsTotal = @ItemsTotal
           , ItemsCompleted = ISNULL(@ItemsDone, 0)
           , ProgressPercent = CAST(100.0 * ISNULL(@ItemsDone,0) / NULLIF(@ItemsTotal, 0) AS DECIMAL(5,2))
           , [Status] = CASE WHEN @ItemsTotal > 0 AND ISNULL(@ItemsDone,0) >= @ItemsTotal THEN 4 ELSE 3 END
           , CompletedAtUtc = CASE WHEN @ItemsTotal > 0 AND ISNULL(@ItemsDone,0) >= @ItemsTotal
                                   THEN ISNULL(CompletedAtUtc, SYSUTCDATETIME()) ELSE NULL END
           , ModifiedAtUtc = SYSUTCDATETIME()
        WHERE EnrollmentId = @EnrollmentId AND CourseModuleId = @CourseModuleId;

        /* Desbloquear los modulos que tenian este como prerrequisito */
        IF @ItemsTotal > 0 AND ISNULL(@ItemsDone,0) >= @ItemsTotal
            UPDATE mp
            SET mp.[Status] = 2, mp.UnlockedAtUtc = SYSUTCDATETIME(), mp.ModifiedAtUtc = SYSUTCDATETIME()
            FROM dlv.ModuleProgress mp
            JOIN lms.CourseModule m ON m.CourseModuleId = mp.CourseModuleId
            WHERE mp.EnrollmentId = @EnrollmentId
              AND m.PrerequisiteModuleId = @CourseModuleId
              AND mp.[Status] = 1;

        UPDATE dlv.Enrollment
        SET  [Status] = CASE WHEN [Status] = 1 THEN 2 ELSE [Status] END
           , StartedAtUtc = ISNULL(StartedAtUtc, SYSUTCDATETIME())
           , LastAccessedAtUtc = SYSUTCDATETIME()
           , LastAccessedItemId = @ModuleItemId
           , TotalTimeSpentSeconds = TotalTimeSpentSeconds + ISNULL(@TimeSpentSeconds, 0)
           , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EnrollmentId = @EnrollmentId;

        COMMIT TRANSACTION;

        EXEC dlv.usp_Progress_Recalculate @ActorUserId = @ActorUserId, @EnrollmentId = @EnrollmentId;

        SELECT ProgressPercent, [Status] FROM dlv.Enrollment WHERE EnrollmentId = @EnrollmentId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Progress_CompleteItem', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Progress_Recalculate
   Recalcula el porcentaje total y cierra la inscripcion si corresponde.
   Idempotente: se puede llamar cuantas veces sea.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Progress_Recalculate
      @ActorUserId  INT
    , @EnrollmentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @Total INT, @Done INT, @Percent DECIMAL(5,2)
              , @PassingScore DECIMAL(5,2), @AvgScore DECIMAL(5,2)
              , @CurrentStatus TINYINT, @EmployeeId INT;

        SELECT @CurrentStatus = e.[Status], @PassingScore = v.PassingScore, @EmployeeId = e.EmployeeId
        FROM dlv.Enrollment e
        JOIN lms.CourseVersion v ON v.CourseVersionId = e.CourseVersionId
        WHERE e.EnrollmentId = @EnrollmentId;

        IF @CurrentStatus IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;
        IF @CurrentStatus NOT IN (1,2) RETURN 0;   -- ya cerrada, nada que hacer

        SELECT  @Total = COUNT(*)
              , @Done  = SUM(CASE WHEN ip.[Status] = 3 THEN 1 ELSE 0 END)
        FROM lms.ModuleItem i
        JOIN lms.CourseModule m ON m.CourseModuleId = i.CourseModuleId
        JOIN dlv.Enrollment e   ON e.CourseVersionId = m.CourseVersionId AND e.EnrollmentId = @EnrollmentId
        LEFT JOIN dlv.ItemProgress ip ON ip.ModuleItemId = i.ModuleItemId AND ip.EnrollmentId = @EnrollmentId
        WHERE i.IsDeleted = 0 AND m.IsDeleted = 0 AND i.IsRequiredForCompletion = 1;

        SET @Percent = CAST(100.0 * ISNULL(@Done, 0) / NULLIF(@Total, 0) AS DECIMAL(5,2));

        /* Puntaje del curso: promedio ponderado de los items con puntaje.
           Si no hay ninguno (curso solo de lectura), queda NULL y el paso
           lo define la completitud. */
        SELECT @AvgScore = CAST(AVG(ip.ScorePercent) AS DECIMAL(5,2))
        FROM dlv.ItemProgress ip
        WHERE ip.EnrollmentId = @EnrollmentId AND ip.ScorePercent IS NOT NULL;

        BEGIN TRANSACTION;

        UPDATE dlv.Enrollment
        SET  ProgressPercent = ISNULL(@Percent, 0)
           , ScorePercent    = @AvgScore
           , ModifiedAtUtc   = SYSUTCDATETIME()
        WHERE EnrollmentId = @EnrollmentId;

        COMMIT TRANSACTION;

        /* Cierre automatico */
        IF @Total > 0 AND ISNULL(@Done,0) >= @Total
        BEGIN
            DECLARE @IsPassed BIT =
                CASE WHEN @AvgScore IS NULL THEN 1
                     WHEN @AvgScore >= @PassingScore THEN 1
                     ELSE 0 END;

            IF @IsPassed = 1
                EXEC dlv.usp_Enrollment_Complete @ActorUserId = @ActorUserId, @EnrollmentId = @EnrollmentId;
            ELSE
                EXEC dlv.usp_Enrollment_Fail @ActorUserId = @ActorUserId, @EnrollmentId = @EnrollmentId
                   , @Reason = N'Puntaje final por debajo del minimo aprobatorio.';
        END;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Progress_Recalculate', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Enrollment_Complete
   Cierra la inscripcion y le pasa la bola al motor de compliance.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Complete
      @ActorUserId  INT
    , @EnrollmentId INT
    , @ScorePercent DECIMAL(5,2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @EmployeeId INT, @CourseId INT, @Status TINYINT;

        SELECT @EmployeeId = EmployeeId, @CourseId = CourseId, @Status = [Status]
        FROM dlv.Enrollment WHERE EnrollmentId = @EnrollmentId;

        IF @EmployeeId IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;
        IF @Status = 3 RETURN 0;   -- ya completada, idempotente

        BEGIN TRANSACTION;

        UPDATE dlv.Enrollment
        SET  [Status] = 3
           , IsPassed = 1
           , ProgressPercent = 100.00
           , ScorePercent = COALESCE(@ScorePercent, ScorePercent)
           , CompletedAtUtc = SYSUTCDATETIME()
           , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EnrollmentId = @EnrollmentId;

        EXEC aud.usp_Event_Log
              @EventType   = N'Enrollment.Completed'
            , @EntityType  = N'Enrollment'
            , @EntityId    = @EnrollmentId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Inscripcion completada satisfactoriamente.';

        COMMIT TRANSACTION;

        /* Aqui es donde el LMS se gana el sueldo: completar un curso puede
           cerrar un requisito de competencia y emitir certificacion. */
        EXEC comp.usp_Certification_EvaluateAndIssue
              @ActorUserId = @ActorUserId
            , @EmployeeId  = @EmployeeId
            , @TriggerType = 1                 -- 1=EnrollmentCompleted
            , @TriggerId   = @EnrollmentId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_Complete', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Fail
      @ActorUserId INT, @EnrollmentId INT, @Reason NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @EmployeeId INT, @CourseId INT, @Attempt TINYINT, @MaxAttempts TINYINT;
        SELECT @EmployeeId = e.EmployeeId, @CourseId = e.CourseId
             , @Attempt = e.AttemptNumber, @MaxAttempts = v.MaxAttempts
        FROM dlv.Enrollment e JOIN lms.CourseVersion v ON v.CourseVersionId = e.CourseVersionId
        WHERE e.EnrollmentId = @EnrollmentId;

        IF @EmployeeId IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;

        BEGIN TRANSACTION;
        UPDATE dlv.Enrollment
        SET [Status] = 4, IsPassed = 0, CompletedAtUtc = SYSUTCDATETIME()
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EnrollmentId = @EnrollmentId;

        EXEC aud.usp_Event_Log @EventType = N'Enrollment.Failed', @EntityType = N'Enrollment'
           , @EntityId = @EnrollmentId, @EmployeeId = @EmployeeId, @ActorUserId = @ActorUserId
           , @Severity = 3, @Summary = N'Inscripcion no aprobada.';
        COMMIT TRANSACTION;

        /* Reintento automatico mientras queden intentos. Si se agotaron,
           el supervisor recibe aviso para intervencion presencial. */
        IF @Attempt < @MaxAttempts
        BEGIN
            DECLARE @NewEnrollmentId INT;
            EXEC dlv.usp_Enrollment_Create
                  @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId, @CourseId = @CourseId
                , @Source = 2, @AllowDuplicate = 1, @EnrollmentId = @NewEnrollmentId OUTPUT;
        END
        ELSE
            EXEC ops.usp_Notification_Enqueue
                  @TemplateCode = N'Enrollment.AttemptsExhausted'
                , @RecipientEmployeeId = @EmployeeId
                , @Priority = 1
                , @NotifySupervisor = 1;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_Fail', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Enrollment_CreateFromRequirement
   Llamado por el motor de gaps: inscribe al empleado en el satisfactor
   mandatorio de tipo Course del requisito.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_CreateFromRequirement
      @ActorUserId   INT
    , @EmployeeId    INT
    , @RequirementId INT
    , @DueInDays     INT = 30
    , @EnrollmentId  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @CourseId INT;

        /* Se toma el satisfactor mandatorio de menor SortOrder. Si el
           requisito solo se satisface con evaluacion practica o firma de
           documento, no hay curso que inscribir y se sale limpio. */
        SELECT TOP (1) @CourseId = rs.SatisfierId
        FROM comp.RequirementSatisfier rs
        WHERE rs.RequirementId = @RequirementId
          AND rs.SatisfierType = 1
          AND rs.IsMandatory = 1
          AND rs.SatisfierId IS NOT NULL
        ORDER BY rs.SortOrder, rs.RequirementSatisfierId;

        IF @CourseId IS NULL RETURN 0;

        IF EXISTS (SELECT 1 FROM dlv.Enrollment
                   WHERE EmployeeId = @EmployeeId AND CourseId = @CourseId AND [Status] IN (1,2))
            RETURN 0;   -- ya esta inscrito, no duplicamos

        EXEC dlv.usp_Enrollment_Create
              @ActorUserId = @ActorUserId
            , @EmployeeId  = @EmployeeId
            , @CourseId    = @CourseId
            , @Source      = 1                       -- CompetencyRequired
            , @SourceRequirementId = @RequirementId
            , @DueAtUtc    = NULL
            , @EnrollmentId = @EnrollmentId OUTPUT;

        IF @EnrollmentId IS NOT NULL AND @DueInDays IS NOT NULL
            UPDATE dlv.Enrollment
            SET DueAtUtc = DATEADD(DAY, @DueInDays, SYSUTCDATETIME())
            WHERE EnrollmentId = @EnrollmentId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_CreateFromRequirement', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Enrollment_CreateBulk  -- asignacion masiva por TVP
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_CreateBulk
      @ActorUserId INT
    , @Requests    dlv.EnrollmentRequestType READONLY
    , @Source      TINYINT = 4
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Fila mala no tumba el lote. Se devuelve un resultset con el
       resultado por fila para que el usuario vea que fallo y por que. */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'enrollment.assign') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        DECLARE @Results TABLE (
              EmployeeCode NVARCHAR(30), CourseCode NVARCHAR(40)
            , EnrollmentId INT NULL, IsSuccess BIT, [Message] NVARCHAR(400));

        DECLARE @EmployeeCode NVARCHAR(30), @CourseCode NVARCHAR(40)
              , @CohortId INT, @DueAtUtc DATETIME2(3)
              , @EmployeeId INT, @CourseId INT, @NewId INT;

        DECLARE bulk_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT EmployeeCode, CourseCode, CohortId, DueAtUtc FROM @Requests;

        OPEN bulk_cur;
        FETCH NEXT FROM bulk_cur INTO @EmployeeCode, @CourseCode, @CohortId, @DueAtUtc;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @NewId = NULL;
            BEGIN TRY
                SELECT @EmployeeId = EmployeeId FROM org.Employee WHERE EmployeeCode = @EmployeeCode AND IsActive = 1;
                SELECT @CourseId   = CourseId   FROM lms.Course   WHERE CourseCode   = @CourseCode   AND IsDeleted = 0;

                IF @EmployeeId IS NULL THROW 50303, 'Empleado no encontrado o inactivo.', 1;
                IF @CourseId   IS NULL THROW 50001, 'Curso no encontrado.', 1;

                EXEC dlv.usp_Enrollment_Create
                      @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId, @CourseId = @CourseId
                    , @Source = @Source, @CohortId = @CohortId, @DueAtUtc = @DueAtUtc
                    , @EnrollmentId = @NewId OUTPUT;

                INSERT INTO @Results VALUES (@EmployeeCode, @CourseCode, @NewId, 1, N'OK');
            END TRY
            BEGIN CATCH
                INSERT INTO @Results VALUES (@EmployeeCode, @CourseCode, NULL, 0, LEFT(ERROR_MESSAGE(), 400));
            END CATCH;
            FETCH NEXT FROM bulk_cur INTO @EmployeeCode, @CourseCode, @CohortId, @DueAtUtc;
        END;
        CLOSE bulk_cur; DEALLOCATE bulk_cur;

        SELECT * FROM @Results;
        SELECT SUM(CAST(IsSuccess AS INT)) AS Succeeded
             , SUM(CASE WHEN IsSuccess = 0 THEN 1 ELSE 0 END) AS Failed
        FROM @Results;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_CreateBulk', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Sesiones presenciales (ILT) - GAP-04
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Session_Create
      @ActorUserId INT, @CourseId INT, @SessionCode NVARCHAR(40)
    , @TitleEs NVARCHAR(250), @TitleEn NVARCHAR(250) = NULL
    , @InstructorEmployeeId INT
    , @ScheduledStartUtc DATETIME2(3), @ScheduledEndUtc DATETIME2(3)
    , @LocationType TINYINT = 1, @LocationName NVARCHAR(200) = NULL
    , @SiteId INT = NULL, @AreaId INT = NULL, @StationId INT = NULL
    , @LocaleCode NVARCHAR(10) = N'es-DO'
    , @MinParticipants INT = NULL, @MaxParticipants INT = NULL
    , @RequiredMinutes INT = NULL, @AllowWaitlist BIT = 1
    , @TrainingSessionId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* Errores: 50320 instructor no calificado para el curso
                50321 fechas invalidas
                50322 conflicto de agenda del instructor                 */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'session.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF @ScheduledEndUtc <= @ScheduledStartUtc
            THROW 50321, 'La hora de fin debe ser posterior a la de inicio.', 1;

        DECLARE @CourseVersionId INT;
        SELECT @CourseVersionId = CurrentVersionId FROM lms.Course WHERE CourseId = @CourseId;
        IF @CourseVersionId IS NULL THROW 50301, 'El curso no tiene una version publicada vigente.', 1;

        /* GAP-05: el que evalua tiene que estar calificado para evaluar.
           Un instructor sin EvaluatorQualification vigente no abre sesion. */
        IF NOT EXISTS (
            SELECT 1 FROM comp.EvaluatorQualification eq
            WHERE eq.EmployeeId = @InstructorEmployeeId
              AND eq.IsActive = 1 AND eq.CanTrain = 1
              AND eq.RevokedAtUtc IS NULL
              AND (eq.ExpiresAtUtc IS NULL OR eq.ExpiresAtUtc > SYSUTCDATETIME())
              /* si el curso satisface una competencia concreta, la
                 calificacion del instructor debe cubrir esa competencia */
              AND (NOT EXISTS (SELECT 1 FROM comp.RequirementSatisfier rs
                               JOIN comp.CompetencyRequirement r ON r.RequirementId = rs.RequirementId
                               WHERE rs.SatisfierType = 1 AND rs.SatisfierId = @CourseId)
                   OR eq.CompetencyId IN (SELECT r.CompetencyId FROM comp.RequirementSatisfier rs
                                          JOIN comp.CompetencyRequirement r ON r.RequirementId = rs.RequirementId
                                          WHERE rs.SatisfierType = 1 AND rs.SatisfierId = @CourseId)))
           AND sec.fn_UserHasPermission(@ActorUserId, N'session.override_qualification') = 0
            THROW 50320, 'El instructor no tiene calificacion vigente para impartir este curso.', 1;

        IF EXISTS (
            SELECT 1 FROM dlv.TrainingSession s
            WHERE s.InstructorEmployeeId = @InstructorEmployeeId
              AND s.[Status] NOT IN (6)
              AND s.IsDeleted = 0
              AND s.ScheduledStartUtc < @ScheduledEndUtc
              AND s.ScheduledEndUtc   > @ScheduledStartUtc)
            THROW 50322, 'El instructor ya tiene una sesion agendada en ese horario.', 1;

        INSERT INTO dlv.TrainingSession (CourseId, CourseVersionId, SessionCode, TitleEs, TitleEn
                                       , InstructorEmployeeId, LocationType, LocationName
                                       , SiteId, AreaId, StationId, LocaleCode
                                       , ScheduledStartUtc, ScheduledEndUtc, RequiredMinutes
                                       , MinParticipants, MaxParticipants, AllowWaitlist
                                       , [Status], CreatedByUserId)
        VALUES (@CourseId, @CourseVersionId, @SessionCode, @TitleEs, @TitleEn
              , @InstructorEmployeeId, @LocationType, @LocationName
              , @SiteId, @AreaId, @StationId, @LocaleCode
              , @ScheduledStartUtc, @ScheduledEndUtc, @RequiredMinutes
              , @MinParticipants, @MaxParticipants, @AllowWaitlist
              , 2, @ActorUserId);

        SET @TrainingSessionId = SCOPE_IDENTITY();
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Session_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Attendance_CheckIn
      @ActorUserId INT, @TrainingSessionId INT
    , @EmployeeCode NVARCHAR(30) = NULL, @EmployeeId INT = NULL
    , @CheckInMethod TINYINT = 2, @DeviceId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* Errores: 50323 sesion no esta en curso, 50324 empleado no inscrito */
    BEGIN TRY
        SELECT @EmployeeId = COALESCE(@EmployeeId, e.EmployeeId)
        FROM org.Employee e WHERE @EmployeeCode IS NOT NULL AND e.EmployeeCode = @EmployeeCode;

        IF @EmployeeId IS NULL THROW 50303, 'Empleado no encontrado.', 1;

        DECLARE @Status TINYINT, @CourseId INT;
        SELECT @Status = [Status], @CourseId = CourseId
        FROM dlv.TrainingSession WHERE TrainingSessionId = @TrainingSessionId;

        IF @Status IS NULL THROW 50001, 'Sesion no encontrada.', 1;
        IF @Status NOT IN (2,3,4) THROW 50323, 'La sesion no admite registro de asistencia en este momento.', 1;

        BEGIN TRANSACTION;

        /* Marcar la sesion como en curso al primer check-in. */
        UPDATE dlv.TrainingSession
        SET [Status] = 4, ActualStartUtc = ISNULL(ActualStartUtc, SYSUTCDATETIME())
        WHERE TrainingSessionId = @TrainingSessionId AND [Status] <> 4;

        MERGE dlv.SessionAttendance AS tgt
        USING (SELECT @TrainingSessionId AS SessionId, @EmployeeId AS EmployeeId) AS src
        ON tgt.TrainingSessionId = src.SessionId AND tgt.EmployeeId = src.EmployeeId
        WHEN MATCHED THEN UPDATE SET
              CheckInAtUtc = ISNULL(tgt.CheckInAtUtc, SYSUTCDATETIME())
            , AttendanceStatus = CASE WHEN tgt.AttendanceStatus = 4 THEN 1 ELSE tgt.AttendanceStatus END
            , CheckInMethod = @CheckInMethod, DeviceId = @DeviceId
        WHEN NOT MATCHED THEN INSERT
              (TrainingSessionId, EmployeeId, AttendanceStatus, CheckInAtUtc, CheckInMethod, DeviceId, RecordedByUserId)
            VALUES (@TrainingSessionId, @EmployeeId, 1, SYSUTCDATETIME(), @CheckInMethod, @DeviceId, @ActorUserId);

        COMMIT TRANSACTION;

        SELECT e.EmployeeCode, e.FullName, a.AttendanceStatus, a.CheckInAtUtc
        FROM dlv.SessionAttendance a
        JOIN org.Employee e ON e.EmployeeId = a.EmployeeId
        WHERE a.TrainingSessionId = @TrainingSessionId AND a.EmployeeId = @EmployeeId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Attendance_CheckIn', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Session_Close

   El instructor cierra la sesion y firma el roster. Esa firma es la
   evidencia primaria de que la capacitacion presencial ocurrio: es lo
   que se le ensena al auditor. Al cerrar:
     - se calculan minutos asistidos y se marca Present/Late/Absent,
     - se crea evidencia de inscripcion por participante,
     - se dispara la evaluacion de certificacion de cada uno.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Session_Close
      @ActorUserId       INT
    , @TrainingSessionId INT
    , @InstructorNotes   NVARCHAR(MAX) = NULL
    , @PayloadCanonical  NVARCHAR(MAX) = NULL
    , @AuthMethod        TINYINT       = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50325 sesion ya cerrada
                50326 quien cierra no es el instructor de la sesion       */
    BEGIN TRY
        DECLARE @Status TINYINT, @InstructorEmployeeId INT, @RequiredMinutes INT
              , @CourseId INT, @ActorEmployeeId INT, @SignatureId BIGINT;

        SELECT @Status = [Status], @InstructorEmployeeId = InstructorEmployeeId
             , @RequiredMinutes = RequiredMinutes, @CourseId = CourseId
        FROM dlv.TrainingSession WHERE TrainingSessionId = @TrainingSessionId;

        IF @Status IS NULL THROW 50001, 'Sesion no encontrada.', 1;
        IF @Status = 5 THROW 50325, 'La sesion ya fue cerrada.', 1;

        SELECT @ActorEmployeeId = EmployeeId FROM sec.[User] WHERE UserId = @ActorUserId;

        IF @ActorEmployeeId <> @InstructorEmployeeId
           AND sec.fn_UserHasPermission(@ActorUserId, N'session.close.any') = 0
            THROW 50326, 'Solo el instructor asignado puede cerrar y firmar esta sesion.', 1;

        BEGIN TRANSACTION;

        UPDATE dlv.TrainingSession
        SET [Status] = 5, ActualEndUtc = ISNULL(ActualEndUtc, SYSUTCDATETIME())
          , InstructorNotes = COALESCE(@InstructorNotes, InstructorNotes)
          , ClosedAtUtc = SYSUTCDATETIME(), ClosedByUserId = @ActorUserId
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE TrainingSessionId = @TrainingSessionId;

        /* Minutos asistidos y estatus final. Quien no marco salida se
           considera presente hasta el fin real de la sesion. */
        UPDATE a
        SET  a.CheckOutAtUtc = ISNULL(a.CheckOutAtUtc, s.ActualEndUtc)
           , a.MinutesAttended = DATEDIFF(MINUTE, a.CheckInAtUtc, ISNULL(a.CheckOutAtUtc, s.ActualEndUtc))
           , a.AttendanceStatus =
                CASE WHEN a.CheckInAtUtc IS NULL THEN 4                                   -- Absent
                     WHEN @RequiredMinutes IS NOT NULL
                      AND DATEDIFF(MINUTE, a.CheckInAtUtc, ISNULL(a.CheckOutAtUtc, s.ActualEndUtc)) < @RequiredMinutes
                     THEN 3                                                                -- LeftEarly
                     WHEN a.CheckInAtUtc > DATEADD(MINUTE, 10, s.ScheduledStartUtc) THEN 2  -- Late
                     ELSE 1 END                                                            -- Present
           , a.ResultCode =
                CASE WHEN a.CheckInAtUtc IS NULL THEN 2
                     WHEN @RequiredMinutes IS NOT NULL
                      AND DATEDIFF(MINUTE, a.CheckInAtUtc, ISNULL(a.CheckOutAtUtc, s.ActualEndUtc)) < @RequiredMinutes
                     THEN 3
                     ELSE 1 END
        FROM dlv.SessionAttendance a
        JOIN dlv.TrainingSession s ON s.TrainingSessionId = a.TrainingSessionId
        WHERE a.TrainingSessionId = @TrainingSessionId;

        /* Firma del roster por el instructor. */
        SET @PayloadCanonical = ISNULL(@PayloadCanonical,
            (SELECT TrainingSessionId = @TrainingSessionId
                  , InstructorEmployeeId = @InstructorEmployeeId
                  , ClosedAtUtc = SYSUTCDATETIME()
                  , Roster = (SELECT a.EmployeeId, a.AttendanceStatus, a.MinutesAttended
                              FROM dlv.SessionAttendance a
                              WHERE a.TrainingSessionId = @TrainingSessionId
                              ORDER BY a.EmployeeId
                              FOR JSON PATH)
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER));

        EXEC aud.usp_Signature_Create
              @ActorUserId      = @ActorUserId
            , @SignatureMeaning = N'Attended'
            , @EntityType       = N'TrainingSession'
            , @EntityId         = @TrainingSessionId
            , @PayloadCanonical = @PayloadCanonical
            , @AuthMethod       = @AuthMethod
            , @SignatureRecordId = @SignatureId OUTPUT;

        UPDATE dlv.TrainingSession SET RosterSignatureId = @SignatureId
        WHERE TrainingSessionId = @TrainingSessionId;

        /* Evidencia por participante aprobado. */
        INSERT INTO dlv.EnrollmentEvidence (EnrollmentId, EvidenceType, EvidenceId, IsPassing, ScorePercent)
        SELECT a.EnrollmentId, 3, a.SessionAttendanceId, 1, NULL
        FROM dlv.SessionAttendance a
        WHERE a.TrainingSessionId = @TrainingSessionId
          AND a.EnrollmentId IS NOT NULL
          AND a.ResultCode = 1
          AND NOT EXISTS (SELECT 1 FROM dlv.EnrollmentEvidence ee
                          WHERE ee.EnrollmentId = a.EnrollmentId AND ee.EvidenceType = 3
                            AND ee.EvidenceId = a.SessionAttendanceId);

        EXEC aud.usp_Event_Log
              @EventType   = N'TrainingSession.Closed'
            , @EntityType  = N'TrainingSession'
            , @EntityId    = @TrainingSessionId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Sesion presencial cerrada y roster firmado por el instructor.';

        COMMIT TRANSACTION;

        /* Completar inscripciones y evaluar certificacion de cada asistente. */
        DECLARE @EnrollmentId INT, @EmployeeId INT;
        DECLARE roster CURSOR LOCAL FAST_FORWARD FOR
            SELECT a.EnrollmentId, a.EmployeeId
            FROM dlv.SessionAttendance a
            WHERE a.TrainingSessionId = @TrainingSessionId AND a.ResultCode = 1;

        OPEN roster;
        FETCH NEXT FROM roster INTO @EnrollmentId, @EmployeeId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                IF @EnrollmentId IS NOT NULL
                    EXEC dlv.usp_Enrollment_Complete @ActorUserId = @ActorUserId, @EnrollmentId = @EnrollmentId;
                ELSE
                    EXEC comp.usp_Certification_EvaluateAndIssue
                          @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId
                        , @TriggerType = 3, @TriggerId = @TrainingSessionId;   -- 3=SessionAttendance
            END TRY
            BEGIN CATCH
                EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Session_Close', @ActorUserId = @ActorUserId;
            END CATCH;
            FETCH NEXT FROM roster INTO @EnrollmentId, @EmployeeId;
        END;
        CLOSE roster; DEALLOCATE roster;

        SELECT @SignatureId AS RosterSignatureId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Session_Close', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Resto del esquema dlv
   ===================================================================== */

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Get
      @ActorUserId INT, @EnrollmentId INT = NULL, @PublicId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @EnrollmentId = COALESCE(@EnrollmentId, EnrollmentId)
    FROM dlv.Enrollment WHERE @PublicId IS NOT NULL AND PublicId = @PublicId;
    IF @EnrollmentId IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;

    SELECT e.EnrollmentId, e.PublicId, e.EmployeeId, emp.EmployeeCode, emp.FullName
         , e.CourseId, c.CourseCode, c.NameEs AS CourseName
         , e.CourseVersionId, v.VersionLabel
         , e.[Source], e.SourceRequirementId, e.[Status], e.AttemptNumber
         , e.ProgressPercent, e.ScorePercent, e.IsPassed
         , e.AssignedAtUtc, e.DueAtUtc, e.StartedAtUtc, e.CompletedAtUtc
         , e.LastAccessedAtUtc, e.LastAccessedItemId, e.TotalTimeSpentSeconds
    FROM dlv.Enrollment e
    JOIN org.Employee emp ON emp.EmployeeId = e.EmployeeId
    JOIN lms.Course c ON c.CourseId = e.CourseId
    JOIN lms.CourseVersion v ON v.CourseVersionId = e.CourseVersionId
    WHERE e.EnrollmentId = @EnrollmentId;

    SELECT ee.EnrollmentEvidenceId, ee.EvidenceType, ee.EvidenceId, ee.IsPassing
         , ee.ScorePercent, ee.RecordedAtUtc
    FROM dlv.EnrollmentEvidence ee WHERE ee.EnrollmentId = @EnrollmentId
    ORDER BY ee.RecordedAtUtc;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_ListForEmployee
      @ActorUserId INT, @EmployeeId INT, @Status TINYINT = NULL
    , @IncludeCompleted BIT = 1, @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    SELECT e.EnrollmentId, e.PublicId, e.CourseId, c.CourseCode, c.NameEs AS CourseName
         , c.DeliveryType, e.[Status], e.ProgressPercent, e.ScorePercent
         , e.DueAtUtc, e.StartedAtUtc, e.CompletedAtUtc, e.[Source]
         , CASE WHEN e.DueAtUtc IS NOT NULL AND e.DueAtUtc < SYSUTCDATETIME() AND e.[Status] IN (1,2)
                THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsOverdue
    FROM dlv.Enrollment e
    JOIN lms.Course c ON c.CourseId = e.CourseId
    WHERE e.EmployeeId = @EmployeeId
      AND (@Status IS NULL OR e.[Status] = @Status)
      AND (@IncludeCompleted = 1 OR e.[Status] IN (1,2))
    ORDER BY CASE WHEN e.[Status] IN (1,2) THEN 0 ELSE 1 END, e.DueAtUtc, e.AssignedAtUtc DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_ListForSupervisor
      @ActorUserId INT, @SupervisorEmployeeId INT, @IncludeIndirect BIT = 1
    , @OnlyOverdue BIT = 0, @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    SELECT emp.EmployeeId, emp.EmployeeCode, emp.FullName
         , e.EnrollmentId, c.CourseCode, c.NameEs AS CourseName
         , e.[Status], e.ProgressPercent, e.DueAtUtc
         , CASE WHEN e.DueAtUtc < SYSUTCDATETIME() THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsOverdue
    FROM org.fn_GetTeamEmployeeIds(@SupervisorEmployeeId, @IncludeIndirect) t
    JOIN org.Employee emp ON emp.EmployeeId = t.EmployeeId
    JOIN dlv.Enrollment e ON e.EmployeeId = emp.EmployeeId AND e.[Status] IN (1,2)
    JOIN lms.Course c ON c.CourseId = e.CourseId
    WHERE (@OnlyOverdue = 0 OR (e.DueAtUtc IS NOT NULL AND e.DueAtUtc < SYSUTCDATETIME()))
    ORDER BY e.DueAtUtc, emp.FullName
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_ListForCourse
      @ActorUserId INT, @CourseId INT, @Status TINYINT = NULL
    , @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    SELECT e.EnrollmentId, e.EmployeeId, emp.EmployeeCode, emp.FullName
         , d.[Name] AS DepartmentName, e.[Status], e.ProgressPercent
         , e.ScorePercent, e.DueAtUtc, e.CompletedAtUtc
    FROM dlv.Enrollment e
    JOIN org.Employee emp ON emp.EmployeeId = e.EmployeeId
    LEFT JOIN org.Department d ON d.DepartmentId = emp.DepartmentId
    WHERE e.CourseId = @CourseId AND (@Status IS NULL OR e.[Status] = @Status)
    ORDER BY emp.FullName
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    SELECT COUNT(*) AS TotalCount FROM dlv.Enrollment
    WHERE CourseId = @CourseId AND (@Status IS NULL OR [Status] = @Status) OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Withdraw
      @ActorUserId INT, @EnrollmentId INT, @Reason NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'enrollment.withdraw') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF @Reason IS NULL OR LEN(LTRIM(@Reason)) = 0
            THROW 50306, 'La justificacion de retiro es obligatoria.', 1;

        UPDATE dlv.Enrollment
        SET [Status] = 5, WithdrawnAtUtc = SYSUTCDATETIME(), WithdrawnByUserId = @ActorUserId
          , WithdrawReason = @Reason, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EnrollmentId = @EnrollmentId AND [Status] IN (1,2);
        IF @@ROWCOUNT = 0 THROW 50001, 'Inscripcion no encontrada o ya cerrada.', 1;

        EXEC aud.usp_Event_Log @EventType = N'Enrollment.Withdrawn', @EntityType = N'Enrollment'
           , @EntityId = @EnrollmentId, @ActorUserId = @ActorUserId, @Severity = 2
           , @Summary = N'Inscripcion retirada.';
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_Withdraw', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_ExtendDueDate
      @ActorUserId INT, @EnrollmentId INT, @NewDueAtUtc DATETIME2(3)
    , @Justification NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Toda extension deja rastro. Un auditor pregunta por que un
       requisito critico se movio tres veces; aqui esta la respuesta. */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'enrollment.extend') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF @Justification IS NULL OR LEN(LTRIM(@Justification)) < 10
            THROW 50307, 'La justificacion de la extension es obligatoria y debe ser explicita.', 1;

        DECLARE @PreviousDue DATETIME2(3);
        SELECT @PreviousDue = DueAtUtc FROM dlv.Enrollment WHERE EnrollmentId = @EnrollmentId;

        BEGIN TRANSACTION;
        INSERT INTO dlv.EnrollmentExtension (EnrollmentId, PreviousDueAtUtc, NewDueAtUtc
                                           , Justification, RequestedByUserId, ApprovedByUserId)
        VALUES (@EnrollmentId, @PreviousDue, @NewDueAtUtc, @Justification, @ActorUserId, @ActorUserId);

        UPDATE dlv.Enrollment SET DueAtUtc = @NewDueAtUtc
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EnrollmentId = @EnrollmentId;
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_ExtendDueDate', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Reassign
      @ActorUserId INT, @EnrollmentId INT, @NewEmployeeId INT, @Reason NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    /* Solo aplica a inscripciones sin progreso: mover evidencia entre
       personas seria falsificar el expediente. */
    IF sec.fn_UserHasPermission(@ActorUserId, N'enrollment.assign') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    IF EXISTS (SELECT 1 FROM dlv.Enrollment WHERE EnrollmentId = @EnrollmentId AND ProgressPercent > 0)
        THROW 50308, 'No se puede reasignar una inscripcion con progreso registrado.', 1;

    UPDATE dlv.Enrollment SET EmployeeId = @NewEmployeeId
      , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE EnrollmentId = @EnrollmentId AND [Status] = 1;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_ExpireOverdue
      @ActorUserId INT = NULL, @GraceDays INT = 0, @BatchSize INT = 1000
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Job nocturno. Expira, no borra: la inscripcion vencida es evidencia
       de que se asigno y no se completo. */
    DECLARE @Affected INT = 0;
    UPDATE TOP (@BatchSize) dlv.Enrollment
    SET [Status] = 6, ModifiedAtUtc = SYSUTCDATETIME()
    WHERE [Status] IN (1,2)
      AND DueAtUtc IS NOT NULL
      AND DATEADD(DAY, @GraceDays, DueAtUtc) < SYSUTCDATETIME();
    SET @Affected = @@ROWCOUNT;
    SELECT @Affected AS EnrollmentsExpired;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Progress_StartItem
      @ActorUserId INT, @EnrollmentId INT, @ModuleItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dlv.ItemProgress AS tgt
    USING (SELECT @EnrollmentId AS EnrollmentId, @ModuleItemId AS ModuleItemId) AS src
    ON tgt.EnrollmentId = src.EnrollmentId AND tgt.ModuleItemId = src.ModuleItemId
    WHEN MATCHED THEN UPDATE SET
          [Status] = CASE WHEN tgt.[Status] = 1 THEN 2 ELSE tgt.[Status] END
        , ViewCount = tgt.ViewCount + 1
        , FirstAccessedAtUtc = ISNULL(tgt.FirstAccessedAtUtc, SYSUTCDATETIME())
        , LastAccessedAtUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
          (EnrollmentId, ModuleItemId, [Status], ViewCount, FirstAccessedAtUtc, LastAccessedAtUtc)
        VALUES (@EnrollmentId, @ModuleItemId, 2, 1, SYSUTCDATETIME(), SYSUTCDATETIME());

    UPDATE dlv.Enrollment
    SET [Status] = CASE WHEN [Status] = 1 THEN 2 ELSE [Status] END
      , StartedAtUtc = ISNULL(StartedAtUtc, SYSUTCDATETIME())
      , LastAccessedAtUtc = SYSUTCDATETIME(), LastAccessedItemId = @ModuleItemId
    WHERE EnrollmentId = @EnrollmentId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Progress_Heartbeat
      @ActorUserId INT, @EnrollmentId INT, @ModuleItemId INT = NULL
    , @SessionId UNIQUEIDENTIFIER = NULL, @IntervalSeconds SMALLINT = 30
    , @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    /* Tiempo real de exposicion al contenido. Sin esto, "cumplio el
       tiempo minimo" es un dato que no se puede defender. */
    INSERT INTO dlv.LearningActivity (EnrollmentId, ModuleItemId, SessionId, IntervalSeconds, IsActive)
    VALUES (@EnrollmentId, @ModuleItemId, @SessionId, @IntervalSeconds, @IsActive);

    IF @IsActive = 1 AND @ModuleItemId IS NOT NULL
        UPDATE dlv.ItemProgress
        SET TimeSpentSeconds = TimeSpentSeconds + @IntervalSeconds, LastAccessedAtUtc = SYSUTCDATETIME()
        WHERE EnrollmentId = @EnrollmentId AND ModuleItemId = @ModuleItemId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Progress_GetForEnrollment
      @ActorUserId INT, @EnrollmentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT mp.CourseModuleId, m.TitleEs, m.SortOrder, mp.[Status]
         , mp.ItemsTotal, mp.ItemsCompleted, mp.ProgressPercent, mp.CompletedAtUtc
    FROM dlv.ModuleProgress mp
    JOIN lms.CourseModule m ON m.CourseModuleId = mp.CourseModuleId
    WHERE mp.EnrollmentId = @EnrollmentId ORDER BY m.SortOrder;

    SELECT ip.ModuleItemId, i.CourseModuleId, i.TitleEs, i.SortOrder, i.ItemType
         , ip.[Status], ip.ScorePercent, ip.TimeSpentSeconds, ip.CompletedAtUtc
    FROM dlv.ItemProgress ip
    JOIN lms.ModuleItem i ON i.ModuleItemId = ip.ModuleItemId
    WHERE ip.EnrollmentId = @EnrollmentId ORDER BY i.CourseModuleId, i.SortOrder;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Progress_UpsertItem
      @ActorUserId INT, @EnrollmentId INT, @ModuleItemId INT
    , @Status TINYINT = NULL, @ScorePercent DECIMAL(5,2) = NULL
    , @VideoPositionSeconds INT = NULL, @VideoWatchedPercent DECIMAL(5,2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dlv.ItemProgress
    SET  [Status] = ISNULL(@Status, [Status])
       , ScorePercent = COALESCE(@ScorePercent, ScorePercent)
       , VideoPositionSeconds = COALESCE(@VideoPositionSeconds, VideoPositionSeconds)
       , VideoWatchedPercent = CASE WHEN @VideoWatchedPercent > ISNULL(VideoWatchedPercent, 0)
                                    THEN @VideoWatchedPercent ELSE VideoWatchedPercent END
       , LastAccessedAtUtc = SYSUTCDATETIME()
    WHERE EnrollmentId = @EnrollmentId AND ModuleItemId = @ModuleItemId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Cohort_Create
      @ActorUserId INT, @CourseId INT, @CohortCode NVARCHAR(40), @Name NVARCHAR(200)
    , @InstructorEmployeeId INT = NULL, @ShiftCode NVARCHAR(20) = NULL
    , @LocaleCode NVARCHAR(10) = N'es-DO'
    , @StartsAtUtc DATETIME2(3) = NULL, @EndsAtUtc DATETIME2(3) = NULL
    , @MaxParticipants INT = NULL, @CohortId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'cohort.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO dlv.Cohort (CourseId, CohortCode, [Name], InstructorEmployeeId, ShiftCode
                          , LocaleCode, StartsAtUtc, EndsAtUtc, MaxParticipants, [Status], CreatedByUserId)
    VALUES (@CourseId, @CohortCode, @Name, @InstructorEmployeeId, @ShiftCode
          , @LocaleCode, @StartsAtUtc, @EndsAtUtc, @MaxParticipants, 1, @ActorUserId);
    SET @CohortId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Session_Get @ActorUserId INT, @TrainingSessionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.*, c.CourseCode, c.NameEs AS CourseName
         , i.FullName AS InstructorName, i.EmployeeCode AS InstructorCode
    FROM dlv.TrainingSession s
    JOIN lms.Course c ON c.CourseId = s.CourseId
    JOIN org.Employee i ON i.EmployeeId = s.InstructorEmployeeId
    WHERE s.TrainingSessionId = @TrainingSessionId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Session_GetRoster @ActorUserId INT, @TrainingSessionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT  r.SessionRegistrationId, r.EmployeeId, e.EmployeeCode, e.FullName
          , d.[Name] AS DepartmentName, r.[Status] AS RegistrationStatus, r.WaitlistPosition
          , a.SessionAttendanceId, a.AttendanceStatus, a.CheckInAtUtc, a.CheckOutAtUtc
          , a.MinutesAttended, a.ResultCode, a.ParticipantSignatureId
    FROM dlv.SessionRegistration r
    JOIN org.Employee e ON e.EmployeeId = r.EmployeeId
    LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
    LEFT JOIN dlv.SessionAttendance a ON a.TrainingSessionId = r.TrainingSessionId AND a.EmployeeId = r.EmployeeId
    WHERE r.TrainingSessionId = @TrainingSessionId
    ORDER BY r.[Status], e.FullName;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_SessionRegistration_Add
      @ActorUserId INT, @TrainingSessionId INT, @EmployeeId INT, @EnrollmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50327 sesion llena y sin lista de espera */
    BEGIN TRY
        DECLARE @Max INT, @AllowWaitlist BIT, @Registered INT, @NewStatus TINYINT = 1, @WaitPos INT = NULL;
        SELECT @Max = MaxParticipants, @AllowWaitlist = AllowWaitlist
        FROM dlv.TrainingSession WHERE TrainingSessionId = @TrainingSessionId;

        SELECT @Registered = COUNT(*) FROM dlv.SessionRegistration
        WHERE TrainingSessionId = @TrainingSessionId AND [Status] IN (1,3);

        IF @Max IS NOT NULL AND @Registered >= @Max
        BEGIN
            IF @AllowWaitlist = 0 THROW 50327, 'La sesion esta llena y no admite lista de espera.', 1;
            SET @NewStatus = 2;
            SELECT @WaitPos = ISNULL(MAX(WaitlistPosition), 0) + 1
            FROM dlv.SessionRegistration WHERE TrainingSessionId = @TrainingSessionId;
        END;

        INSERT INTO dlv.SessionRegistration (TrainingSessionId, EmployeeId, EnrollmentId
                                           , [Status], WaitlistPosition, RegisteredByUserId)
        VALUES (@TrainingSessionId, @EmployeeId, @EnrollmentId, @NewStatus, @WaitPos, @ActorUserId);

        SELECT SCOPE_IDENTITY() AS SessionRegistrationId, @NewStatus AS [Status], @WaitPos AS WaitlistPosition;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_SessionRegistration_Add', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_SessionRegistration_Cancel
      @ActorUserId INT, @SessionRegistrationId INT, @Reason NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @SessionId INT;
        SELECT @SessionId = TrainingSessionId FROM dlv.SessionRegistration WHERE SessionRegistrationId = @SessionRegistrationId;

        BEGIN TRANSACTION;
        UPDATE dlv.SessionRegistration
        SET [Status] = 4, CancelledAtUtc = SYSUTCDATETIME(), CancelReason = @Reason
        WHERE SessionRegistrationId = @SessionRegistrationId;

        /* Promover al primero de la lista de espera. */
        UPDATE r
        SET r.[Status] = 1, r.WaitlistPosition = NULL, r.PromotedFromWaitlistAtUtc = SYSUTCDATETIME()
        FROM dlv.SessionRegistration r
        WHERE r.SessionRegistrationId = (
            SELECT TOP (1) SessionRegistrationId FROM dlv.SessionRegistration
            WHERE TrainingSessionId = @SessionId AND [Status] = 2
            ORDER BY WaitlistPosition);
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_SessionRegistration_Cancel', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Attendance_SetStatus
      @ActorUserId INT, @TrainingSessionId INT, @EmployeeId INT
    , @AttendanceStatus TINYINT, @Notes NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dlv.SessionAttendance AS tgt
    USING (SELECT @TrainingSessionId AS S, @EmployeeId AS E) AS src
    ON tgt.TrainingSessionId = src.S AND tgt.EmployeeId = src.E
    WHEN MATCHED THEN UPDATE SET AttendanceStatus = @AttendanceStatus, Notes = @Notes
    WHEN NOT MATCHED THEN INSERT (TrainingSessionId, EmployeeId, AttendanceStatus, Notes, RecordedByUserId)
        VALUES (@TrainingSessionId, @EmployeeId, @AttendanceStatus, @Notes, @ActorUserId);
    RETURN 0;
END;
GO

/* El participante firma su propia asistencia desde el kiosko. Es la
   evidencia mas fuerte de que estuvo: firma suya, no del instructor. */
CREATE OR ALTER PROCEDURE dlv.usp_Attendance_SignParticipant
      @ActorUserId INT, @TrainingSessionId INT, @EmployeeId INT
    , @PayloadCanonical NVARCHAR(MAX) = NULL, @AuthMethod TINYINT = 2
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @SignatureId BIGINT, @AttendanceId INT;
        SELECT @AttendanceId = SessionAttendanceId FROM dlv.SessionAttendance
        WHERE TrainingSessionId = @TrainingSessionId AND EmployeeId = @EmployeeId;
        IF @AttendanceId IS NULL THROW 50324, 'No hay registro de asistencia para este empleado en la sesion.', 1;

        SET @PayloadCanonical = ISNULL(@PayloadCanonical,
            (SELECT TrainingSessionId = @TrainingSessionId, EmployeeId = @EmployeeId
                  , SignedAtUtc = SYSUTCDATETIME()
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER));

        EXEC aud.usp_Signature_Create
              @ActorUserId = @ActorUserId, @SignatureMeaning = N'Attended'
            , @EntityType = N'SessionAttendance', @EntityId = @AttendanceId
            , @PayloadCanonical = @PayloadCanonical, @AuthMethod = @AuthMethod
            , @SignatureRecordId = @SignatureId OUTPUT;

        UPDATE dlv.SessionAttendance SET ParticipantSignatureId = @SignatureId
        WHERE SessionAttendanceId = @AttendanceId;
        SELECT @SignatureId AS SignatureRecordId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Attendance_SignParticipant', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Session_GetConflicts
      @ActorUserId INT, @InstructorEmployeeId INT
    , @StartUtc DATETIME2(3), @EndUtc DATETIME2(3), @ExcludeSessionId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.TrainingSessionId, s.SessionCode, s.TitleEs, s.ScheduledStartUtc, s.ScheduledEndUtc
    FROM dlv.TrainingSession s
    WHERE s.InstructorEmployeeId = @InstructorEmployeeId
      AND s.IsDeleted = 0 AND s.[Status] <> 6
      AND (@ExcludeSessionId IS NULL OR s.TrainingSessionId <> @ExcludeSessionId)
      AND s.ScheduledStartUtc < @EndUtc AND s.ScheduledEndUtc > @StartUtc
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Session_Update
      @ActorUserId INT, @TrainingSessionId INT
    , @TitleEs NVARCHAR(250) = NULL, @LocationName NVARCHAR(200) = NULL
    , @ScheduledStartUtc DATETIME2(3) = NULL, @ScheduledEndUtc DATETIME2(3) = NULL
    , @MaxParticipants INT = NULL, @Status TINYINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'session.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    UPDATE dlv.TrainingSession
    SET TitleEs = ISNULL(@TitleEs, TitleEs), LocationName = ISNULL(@LocationName, LocationName)
      , ScheduledStartUtc = ISNULL(@ScheduledStartUtc, ScheduledStartUtc)
      , ScheduledEndUtc = ISNULL(@ScheduledEndUtc, ScheduledEndUtc)
      , MaxParticipants = ISNULL(@MaxParticipants, MaxParticipants)
      , [Status] = ISNULL(@Status, [Status])
      , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE TrainingSessionId = @TrainingSessionId AND [Status] <> 5;
    RETURN 0;
END;
GO

/* Serie recurrente: N sesiones con el mismo RecurrenceGroupId. */
CREATE OR ALTER PROCEDURE dlv.usp_Session_CreateRecurring
      @ActorUserId INT, @CourseId INT, @SessionCodePrefix NVARCHAR(30)
    , @TitleEs NVARCHAR(250), @InstructorEmployeeId INT
    , @FirstStartUtc DATETIME2(3), @DurationMinutes INT
    , @IntervalDays INT = 7, @Occurrences INT = 4
    , @LocationName NVARCHAR(200) = NULL, @MaxParticipants INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF @Occurrences < 1 OR @Occurrences > 52
            THROW 50328, 'El numero de ocurrencias debe estar entre 1 y 52.', 1;

        DECLARE @GroupId UNIQUEIDENTIFIER = NEWID(), @i INT = 0, @NewId INT
              , @Start DATETIME2(3), @End DATETIME2(3), @Code NVARCHAR(40);

        WHILE @i < @Occurrences
        BEGIN
            SET @Start = DATEADD(DAY, @i * @IntervalDays, @FirstStartUtc);
            SET @End   = DATEADD(MINUTE, @DurationMinutes, @Start);
            SET @Code  = @SessionCodePrefix + N'-' + RIGHT(N'00' + CAST(@i + 1 AS NVARCHAR(3)), 2);

            EXEC dlv.usp_Session_Create
                  @ActorUserId = @ActorUserId, @CourseId = @CourseId, @SessionCode = @Code
                , @TitleEs = @TitleEs, @InstructorEmployeeId = @InstructorEmployeeId
                , @ScheduledStartUtc = @Start
                , @ScheduledEndUtc = @End
                , @LocationName = @LocationName, @MaxParticipants = @MaxParticipants
                , @TrainingSessionId = @NewId OUTPUT;

            UPDATE dlv.TrainingSession SET RecurrenceGroupId = @GroupId WHERE TrainingSessionId = @NewId;
            SET @i = @i + 1;
        END;

        SELECT @GroupId AS RecurrenceGroupId, @Occurrences AS SessionsCreated;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Session_CreateRecurring', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* Alias explicito: firma del roster sin cerrar (sesion multi-dia). */
CREATE OR ALTER PROCEDURE dlv.usp_Attendance_SignRoster
      @ActorUserId INT, @TrainingSessionId INT
    , @PayloadCanonical NVARCHAR(MAX) = NULL, @AuthMethod TINYINT = 1
    , @SignatureRecordId BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @PayloadCanonical = ISNULL(@PayloadCanonical,
        (SELECT TrainingSessionId = @TrainingSessionId, SignedAtUtc = SYSUTCDATETIME()
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER));

    EXEC aud.usp_Signature_Create
          @ActorUserId = @ActorUserId, @SignatureMeaning = N'Reviewed'
        , @EntityType = N'TrainingSession', @EntityId = @TrainingSessionId
        , @PayloadCanonical = @PayloadCanonical, @AuthMethod = @AuthMethod
        , @SignatureRecordId = @SignatureRecordId OUTPUT;

    UPDATE dlv.TrainingSession SET RosterSignatureId = @SignatureRecordId
    WHERE TrainingSessionId = @TrainingSessionId;
    RETURN 0;
END;
GO

PRINT '=== 13_procs_delivery_progress.sql completado ===';
GO
