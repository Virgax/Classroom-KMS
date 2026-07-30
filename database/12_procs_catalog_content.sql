/* =====================================================================
   Classroom - LMS by Airlink
   12_procs_catalog_content.sql
   Esquema: lms (cursos, versiones, modulos, items, paginas, traduccion)

   Regla de oro del catalogo: una version publicada NO se edita jamas.
   Editar = crear un draft nuevo desde la publicada. Esto es lo que
   permite contestar "que decia el curso el dia que Fulano lo tomo".

   Codigos de error de este archivo: 50200-50299
   ===================================================================== */

USE AIRLINK_LMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 12_procs_catalog_content.sql iniciado ===';
GO

/* =====================================================================
   lms.usp_Course_Create
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_Course_Create
      @ActorUserId       INT
    , @CourseCode        NVARCHAR(40)
    , @NameEs            NVARCHAR(250)
    , @NameEn            NVARCHAR(250) = NULL
    , @CourseCategoryId  INT           = NULL
    , @DeliveryType      TINYINT       = 1     -- 1=Online 2=ILT 3=Blended 4=OJT
    , @OwnerDepartmentId INT           = NULL
    , @EstimatedMinutes  INT           = NULL
    , @AllowSelfEnrollment BIT         = 0
    , @IsBlueprint       BIT           = 0
    , @IdempotencyKey    UNIQUEIDENTIFIER = NULL
    , @CourseId          INT           = NULL OUTPUT
    , @CourseVersionId   INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------
       Proposito : crear un curso y su version 1 en estado Draft.
       Retorna   : CourseId, CourseVersionId (OUTPUT) + fila del curso.
       Errores   : 50201 codigo duplicado
       --------------------------------------------------------------- */

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.create') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF @IdempotencyKey IS NOT NULL
           AND EXISTS (SELECT 1 FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey)
        BEGIN
            SELECT @CourseId = ResultEntityId FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey;
            RETURN 0;
        END;

        IF EXISTS (SELECT 1 FROM lms.Course WHERE CourseCode = @CourseCode AND IsDeleted = 0)
            THROW 50201, 'Ya existe un curso con ese codigo.', 1;

        BEGIN TRANSACTION;

        INSERT INTO lms.Course (CourseCode, NameEs, NameEn, CourseCategoryId, DeliveryType
                              , OwnerDepartmentId, OwnerUserId, EstimatedMinutes
                              , IsBlueprint, AllowSelfEnrollment, [Status], CreatedByUserId)
        VALUES (@CourseCode, @NameEs, @NameEn, @CourseCategoryId, @DeliveryType
              , @OwnerDepartmentId, @ActorUserId, @EstimatedMinutes
              , @IsBlueprint, @AllowSelfEnrollment, 1, @ActorUserId);

        SET @CourseId = SCOPE_IDENTITY();

        INSERT INTO lms.CourseVersion (CourseId, VersionNumber, VersionLabel, [Status], CreatedByUserId)
        VALUES (@CourseId, 1, N'Rev.0', 1, @ActorUserId);

        SET @CourseVersionId = SCOPE_IDENTITY();

        /* Locale base siempre disponible. El ingles arranca pendiente. */
        INSERT INTO lms.CourseVersionLocale (CourseVersionId, LocaleCode, TranslationStatus, CompletionPercent, IsAvailable)
        VALUES (@CourseVersionId, N'es-DO', 3, 100.00, 1)
             , (@CourseVersionId, N'en-US', 1,   0.00, 0);

        IF @IdempotencyKey IS NOT NULL
            INSERT INTO aud.IdempotencyKey (IdempotencyKey, OperationName, ActorUserId, ResultEntityId)
            VALUES (@IdempotencyKey, N'lms.usp_Course_Create', @ActorUserId, @CourseId);

        EXEC aud.usp_Event_Log
              @EventType   = N'Course.Created'
            , @EntityType  = N'Course'
            , @EntityId    = @CourseId
            , @ActorUserId = @ActorUserId
            , @Summary     = N'Curso creado en estado borrador.';

        COMMIT TRANSACTION;

        SELECT c.CourseId, c.PublicId, c.CourseCode, c.NameEs, c.NameEn, c.[Status]
             , @CourseVersionId AS CourseVersionId
        FROM lms.Course c WHERE c.CourseId = @CourseId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Course_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   lms.usp_CourseVersion_CreateDraft
   Clona la version publicada completa (modulos, items, paginas) en una
   version nueva editable. Es la unica forma de "editar" un curso vivo.
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_CourseVersion_CreateDraft
      @ActorUserId     INT
    , @CourseId        INT
    , @SourceVersionId INT           = NULL   -- NULL = clona la vigente
    , @ChangeSummary   NVARCHAR(1000) = NULL
    , @NewVersionId    INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50202 ya existe un draft abierto, 50203 version origen invalida */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF EXISTS (SELECT 1 FROM lms.CourseVersion WHERE CourseId = @CourseId AND [Status] IN (1,2))
            THROW 50202, 'Ya existe un borrador o una version en revision para este curso. Publiquela o descartela primero.', 1;

        SELECT @SourceVersionId = COALESCE(@SourceVersionId, c.CurrentVersionId)
        FROM lms.Course c WHERE c.CourseId = @CourseId;

        IF @SourceVersionId IS NULL
            THROW 50203, 'No hay version de origen para clonar.', 1;

        DECLARE @NextNumber INT;
        SELECT @NextNumber = ISNULL(MAX(VersionNumber), 0) + 1
        FROM lms.CourseVersion WHERE CourseId = @CourseId;

        BEGIN TRANSACTION;

        INSERT INTO lms.CourseVersion (CourseId, VersionNumber, VersionLabel, [Status]
                                     , DescriptionEs, DescriptionEn, ObjectivesEs, ObjectivesEn
                                     , PassingScore, MaxAttempts, EnforceSequence, EnforceMinimumTime
                                     , RequiresRetraining, ChangeSummary, CreatedByUserId)
        SELECT  @CourseId, @NextNumber, N'Rev.' + CAST(@NextNumber - 1 AS NVARCHAR(10)), 1
              , v.DescriptionEs, v.DescriptionEn, v.ObjectivesEs, v.ObjectivesEn
              , v.PassingScore, v.MaxAttempts, v.EnforceSequence, v.EnforceMinimumTime
              , 0, @ChangeSummary, @ActorUserId
        FROM lms.CourseVersion v WHERE v.CourseVersionId = @SourceVersionId;

        SET @NewVersionId = SCOPE_IDENTITY();

        /* Paginas primero: los items apuntan a ellas. Guardamos el mapeo
           viejo->nuevo para reapuntar ModuleItem.TargetId. */
        DECLARE @PageMap TABLE (OldId INT PRIMARY KEY, NewId INT NOT NULL);

        MERGE lms.Page AS tgt
        USING (SELECT PageId, TitleEs, TitleEn, BodyHtmlEs, BodyHtmlEn, EstimatedMinutes
               FROM lms.Page WHERE CourseVersionId = @SourceVersionId AND IsDeleted = 0) AS src
        ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (CourseVersionId, TitleEs, TitleEn, BodyHtmlEs, BodyHtmlEn, EstimatedMinutes, CreatedByUserId)
            VALUES (@NewVersionId, src.TitleEs, src.TitleEn, src.BodyHtmlEs, src.BodyHtmlEn, src.EstimatedMinutes, @ActorUserId)
        OUTPUT src.PageId, inserted.PageId INTO @PageMap (OldId, NewId);

        /* Modulos */
        DECLARE @ModuleMap TABLE (OldId INT PRIMARY KEY, NewId INT NOT NULL);

        MERGE lms.CourseModule AS tgt
        USING (SELECT CourseModuleId, TitleEs, TitleEn, SortOrder, CompletionRule
                    , MinimumScore, IsRequired
               FROM lms.CourseModule WHERE CourseVersionId = @SourceVersionId AND IsDeleted = 0) AS src
        ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (CourseVersionId, TitleEs, TitleEn, SortOrder, CompletionRule, MinimumScore, IsRequired, CreatedByUserId)
            VALUES (@NewVersionId, src.TitleEs, src.TitleEn, src.SortOrder, src.CompletionRule
                  , src.MinimumScore, src.IsRequired, @ActorUserId)
        OUTPUT src.CourseModuleId, inserted.CourseModuleId INTO @ModuleMap (OldId, NewId);

        /* Prerrequisitos de modulo: reapuntar al modulo clonado. */
        UPDATE nm
        SET PrerequisiteModuleId = pm.NewId
        FROM lms.CourseModule nm
        JOIN @ModuleMap mm ON mm.NewId = nm.CourseModuleId
        JOIN lms.CourseModule om ON om.CourseModuleId = mm.OldId
        JOIN @ModuleMap pm ON pm.OldId = om.PrerequisiteModuleId
        WHERE nm.CourseVersionId = @NewVersionId;

        /* Items. ItemType 1=Page se reapunta via @PageMap; los demas tipos
           (Quiz, Video, Documento controlado) se reapuntan en su propio
           bloque o quedan apuntando al recurso compartido. */
        INSERT INTO lms.ModuleItem (CourseModuleId, ItemType, TargetId, TitleEs, TitleEn
                                  , SortOrder, Indent, IsRequiredForCompletion, CompletionCriteria
                                  , MinimumScore, MinimumSeconds, Points, CreatedByUserId)
        SELECT  mm.NewId
              , i.ItemType
              , CASE WHEN i.ItemType = 1 THEN pm.NewId ELSE i.TargetId END
              , i.TitleEs, i.TitleEn, i.SortOrder, i.Indent
              , i.IsRequiredForCompletion, i.CompletionCriteria
              , i.MinimumScore, i.MinimumSeconds, i.Points, @ActorUserId
        FROM lms.ModuleItem i
        JOIN @ModuleMap mm ON mm.OldId = i.CourseModuleId
        LEFT JOIN @PageMap pm ON pm.OldId = i.TargetId AND i.ItemType = 1
        WHERE i.IsDeleted = 0;

        /* Locales */
        INSERT INTO lms.CourseVersionLocale (CourseVersionId, LocaleCode, TranslationStatus, CompletionPercent, IsAvailable)
        SELECT @NewVersionId, LocaleCode, TranslationStatus, CompletionPercent, IsAvailable
        FROM lms.CourseVersionLocale WHERE CourseVersionId = @SourceVersionId;

        EXEC aud.usp_Event_Log
              @EventType   = N'CourseVersion.DraftCreated'
            , @EntityType  = N'CourseVersion'
            , @EntityId    = @NewVersionId
            , @ActorUserId = @ActorUserId
            , @Summary     = N'Borrador creado a partir de una version existente.';

        COMMIT TRANSACTION;

        SELECT @NewVersionId AS CourseVersionId, @NextNumber AS VersionNumber;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_CourseVersion_CreateDraft', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   lms.usp_CourseVersion_SubmitForReview
   Crea las filas de aprobacion. SoD: el autor no puede ser el aprobador
   de calidad (validado tambien en sec.usp_UserRole_Assign).
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_CourseVersion_SubmitForReview
      @ActorUserId        INT
    , @CourseVersionId    INT
    , @TechnicalReviewerUserId INT
    , @QualityApproverUserId   INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50204 version no esta en Draft
                50205 conflicto de segregacion de funciones
                50206 curso sin contenido evaluable */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.submit') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        DECLARE @AuthorUserId INT, @Status TINYINT;
        SELECT @Status = [Status], @AuthorUserId = CreatedByUserId
        FROM lms.CourseVersion WHERE CourseVersionId = @CourseVersionId;

        IF @Status IS NULL THROW 50001, 'Version de curso no encontrada.', 1;
        IF @Status <> 1 THROW 50204, 'Solo una version en borrador puede enviarse a revision.', 1;

        IF @QualityApproverUserId IN (@AuthorUserId, @ActorUserId)
            THROW 50205, 'El aprobador de calidad no puede ser el autor ni quien envia a revision.', 1;

        IF NOT EXISTS (SELECT 1 FROM lms.CourseModule m
                       JOIN lms.ModuleItem i ON i.CourseModuleId = m.CourseModuleId AND i.IsDeleted = 0
                       WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0)
            THROW 50206, 'La version no tiene contenido. Agregue al menos un modulo con items.', 1;

        BEGIN TRANSACTION;

        UPDATE lms.CourseVersion
        SET [Status] = 2, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE CourseVersionId = @CourseVersionId;

        DELETE FROM lms.CourseApproval WHERE CourseVersionId = @CourseVersionId AND DecidedAtUtc IS NULL;

        INSERT INTO lms.CourseApproval (CourseVersionId, ApprovalRole, ApproverUserId)
        VALUES (@CourseVersionId, 2, @TechnicalReviewerUserId)
             , (@CourseVersionId, 3, @QualityApproverUserId);

        EXEC ops.usp_Notification_Enqueue
              @TemplateCode = N'Course.ReviewRequested'
            , @RecipientUserId = @TechnicalReviewerUserId
            , @Priority = 1
            , @DedupeKey = NULL;

        EXEC aud.usp_Event_Log
              @EventType   = N'CourseVersion.SubmittedForReview'
            , @EntityType  = N'CourseVersion'
            , @EntityId    = @CourseVersionId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Version enviada a revision tecnica y aprobacion de calidad.';

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_CourseVersion_SubmitForReview', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   lms.usp_CourseVersion_Publish

   Punto de control mas delicado del catalogo. Al publicar:
     1. valida que todas las aprobaciones esten en Approved,
     2. retira la version anterior,
     3. deja firma electronica de la publicacion,
     4. si RequiresRetraining = 1, marca las certificaciones apoyadas en
        la version anterior como RetrainingRequired (GAP-02/GAP-03).

   Las inscripciones EN CURSO no se mueven de version: quien empezo con
   Rev.1 la termina con Rev.1. El retraining se maneja como inscripcion
   nueva, no como cambio de piso bajo los pies del operador.
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_CourseVersion_Publish
      @ActorUserId     INT
    , @CourseVersionId INT
    , @EffectiveAtUtc  DATETIME2(3) = NULL
    , @SignatureMeaning NVARCHAR(60) = N'Approved'
    , @PayloadCanonical NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50207 aprobaciones incompletas
                50208 version no esta en revision                       */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.publish') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        DECLARE @CourseId INT, @Status TINYINT, @RequiresRetraining BIT, @PreviousVersionId INT;

        SELECT @CourseId = CourseId, @Status = [Status], @RequiresRetraining = RequiresRetraining
        FROM lms.CourseVersion WHERE CourseVersionId = @CourseVersionId;

        IF @CourseId IS NULL THROW 50001, 'Version de curso no encontrada.', 1;
        IF @Status <> 2 THROW 50208, 'Solo una version en revision puede publicarse.', 1;

        IF EXISTS (SELECT 1 FROM lms.CourseApproval
                   WHERE CourseVersionId = @CourseVersionId
                     AND (Decision IS NULL OR Decision <> 1))
            THROW 50207, 'Faltan aprobaciones. Todas deben estar en Aprobado antes de publicar.', 1;

        SET @EffectiveAtUtc = ISNULL(@EffectiveAtUtc, SYSUTCDATETIME());
        SELECT @PreviousVersionId = CurrentVersionId FROM lms.Course WHERE CourseId = @CourseId;

        BEGIN TRANSACTION;

        UPDATE lms.CourseVersion
        SET [Status] = 3, PublishedAtUtc = @EffectiveAtUtc, PublishedByUserId = @ActorUserId
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE CourseVersionId = @CourseVersionId;

        IF @PreviousVersionId IS NOT NULL AND @PreviousVersionId <> @CourseVersionId
            UPDATE lms.CourseVersion
            SET [Status] = 4, RetiredAtUtc = @EffectiveAtUtc
            WHERE CourseVersionId = @PreviousVersionId;

        UPDATE lms.Course
        SET CurrentVersionId = @CourseVersionId, [Status] = 2
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE CourseId = @CourseId;

        /* Firma de la publicacion: evidencia de aprobacion formal. */
        DECLARE @SignatureId BIGINT;
        SET @PayloadCanonical = ISNULL(@PayloadCanonical,
            (SELECT CourseVersionId = @CourseVersionId, CourseId = @CourseId
                  , PublishedAtUtc = @EffectiveAtUtc
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER));

        EXEC aud.usp_Signature_Create
              @ActorUserId      = @ActorUserId
            , @SignatureMeaning = @SignatureMeaning
            , @EntityType       = N'CourseVersion'
            , @EntityId         = @CourseVersionId
            , @PayloadCanonical = @PayloadCanonical
            , @AuthMethod       = 1
            , @SignatureRecordId = @SignatureId OUTPUT;

        COMMIT TRANSACTION;

        /* Retraining: fuera de la transaccion de publicacion porque puede
           tocar miles de certificaciones. Idempotente. */
        IF @RequiresRetraining = 1 AND @PreviousVersionId IS NOT NULL
            EXEC comp.usp_Certification_FlagRetrainingForCourseVersion
                  @ActorUserId       = @ActorUserId
                , @PreviousVersionId = @PreviousVersionId
                , @NewVersionId      = @CourseVersionId;

        EXEC aud.usp_Event_Log
              @EventType   = N'CourseVersion.Published'
            , @EntityType  = N'CourseVersion'
            , @EntityId    = @CourseVersionId
            , @ActorUserId = @ActorUserId
            , @Severity    = 3
            , @Summary     = N'Version publicada y puesta como vigente.';

        SELECT @CourseVersionId AS CourseVersionId, @SignatureId AS SignatureRecordId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_CourseVersion_Publish', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   lms.usp_CourseVersion_GetForLearner
   Devuelve el arbol completo del curso en el idioma del aprendiz, con
   fallback a es-DO si la traduccion no esta disponible (GAP-10).
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_CourseVersion_GetForLearner
      @ActorUserId     INT
    , @EnrollmentId    INT
    , @LocaleCode      NVARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @CourseVersionId INT, @EmployeeId INT, @UseEn BIT = 0;

        SELECT @CourseVersionId = e.CourseVersionId, @EmployeeId = e.EmployeeId
        FROM dlv.Enrollment e WHERE e.EnrollmentId = @EnrollmentId;

        IF @CourseVersionId IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;

        /* El aprendiz solo ve sus propias inscripciones. */
        IF NOT EXISTS (SELECT 1 FROM sec.[User] u WHERE u.UserId = @ActorUserId AND u.EmployeeId = @EmployeeId)
           AND sec.fn_UserHasPermission(@ActorUserId, N'enrollment.read.all') = 0
            THROW 50002, 'El usuario no tiene permiso para ver esta inscripcion.', 1;

        SELECT @LocaleCode = ISNULL(@LocaleCode, u.PreferredLocale)
        FROM sec.[User] u WHERE u.UserId = @ActorUserId;

        /* Fallback: si en-US no esta disponible en esta version, se sirve es-DO. */
        IF @LocaleCode = N'en-US'
           AND EXISTS (SELECT 1 FROM lms.CourseVersionLocale
                       WHERE CourseVersionId = @CourseVersionId AND LocaleCode = N'en-US' AND IsAvailable = 1)
            SET @UseEn = 1;

        /* Resultset 1: cabecera */
        SELECT  v.CourseVersionId, v.CourseId, v.VersionNumber, v.VersionLabel
              , CASE WHEN @UseEn = 1 THEN ISNULL(c.NameEn, c.NameEs) ELSE c.NameEs END AS CourseName
              , CASE WHEN @UseEn = 1 THEN ISNULL(v.DescriptionEn, v.DescriptionEs) ELSE v.DescriptionEs END AS [Description]
              , CASE WHEN @UseEn = 1 THEN ISNULL(v.ObjectivesEn, v.ObjectivesEs) ELSE v.ObjectivesEs END AS Objectives
              , v.PassingScore, v.MaxAttempts, v.EnforceSequence, v.EnforceMinimumTime
              , c.DeliveryType, c.EstimatedMinutes
              , @UseEn AS IsEnglish
        FROM lms.CourseVersion v
        JOIN lms.Course c ON c.CourseId = v.CourseId
        WHERE v.CourseVersionId = @CourseVersionId;

        /* Resultset 2: modulos con progreso */
        SELECT  m.CourseModuleId
              , CASE WHEN @UseEn = 1 THEN ISNULL(m.TitleEn, m.TitleEs) ELSE m.TitleEs END AS Title
              , m.SortOrder, m.PrerequisiteModuleId, m.CompletionRule, m.MinimumScore, m.IsRequired
              , ISNULL(mp.[Status], 1) AS ProgressStatus
              , ISNULL(mp.ProgressPercent, 0) AS ProgressPercent
        FROM lms.CourseModule m
        LEFT JOIN dlv.ModuleProgress mp ON mp.CourseModuleId = m.CourseModuleId AND mp.EnrollmentId = @EnrollmentId
        WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0
        ORDER BY m.SortOrder;

        /* Resultset 3: items con progreso */
        SELECT  i.ModuleItemId, i.CourseModuleId, i.ItemType, i.TargetId
              , CASE WHEN @UseEn = 1 THEN ISNULL(i.TitleEn, i.TitleEs) ELSE i.TitleEs END AS Title
              , i.SortOrder, i.Indent, i.IsRequiredForCompletion, i.CompletionCriteria
              , i.MinimumScore, i.MinimumSeconds, i.Points
              , ISNULL(ip.[Status], 1) AS ProgressStatus
              , ip.ScorePercent, ip.TimeSpentSeconds, ip.VideoPositionSeconds, ip.CompletedAtUtc
        FROM lms.ModuleItem i
        JOIN lms.CourseModule m ON m.CourseModuleId = i.CourseModuleId
        LEFT JOIN dlv.ItemProgress ip ON ip.ModuleItemId = i.ModuleItemId AND ip.EnrollmentId = @EnrollmentId
        WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0 AND i.IsDeleted = 0
        ORDER BY m.SortOrder, i.SortOrder;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_CourseVersion_GetForLearner', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Catalogo: lectura y mantenimiento
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_Course_Get
      @ActorUserId INT, @CourseId INT = NULL, @CourseCode NVARCHAR(40) = NULL
    , @PublicId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @CourseId = COALESCE(@CourseId, c.CourseId)
    FROM lms.Course c
    WHERE (@CourseCode IS NOT NULL AND c.CourseCode = @CourseCode)
       OR (@PublicId   IS NOT NULL AND c.PublicId   = @PublicId);

    IF @CourseId IS NULL THROW 50001, 'Curso no encontrado.', 1;

    SELECT c.CourseId, c.PublicId, c.CourseCode, c.NameEs, c.NameEn
         , c.CourseCategoryId, c.DeliveryType, c.OwnerDepartmentId, c.OwnerUserId
         , c.EstimatedMinutes, c.IsBlueprint, c.AllowSelfEnrollment
         , c.CurrentVersionId, c.[Status], c.CreatedAtUtc
    FROM lms.Course c WHERE c.CourseId = @CourseId AND c.IsDeleted = 0;

    SELECT v.CourseVersionId, v.VersionNumber, v.VersionLabel, v.[Status]
         , v.PassingScore, v.MaxAttempts, v.RequiresRetraining
         , v.PublishedAtUtc, v.RetiredAtUtc, v.ChangeSummary
    FROM lms.CourseVersion v WHERE v.CourseId = @CourseId
    ORDER BY v.VersionNumber DESC;

    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Course_List
      @ActorUserId INT, @SearchText NVARCHAR(100) = NULL
    , @CourseCategoryId INT = NULL, @DeliveryType TINYINT = NULL
    , @Status TINYINT = NULL, @OwnerDepartmentId INT = NULL
    , @PageNumber INT = 1, @PageSize INT = 50
    , @SortBy NVARCHAR(50) = N'NameEs', @SortDir CHAR(4) = 'ASC'
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    IF @SortDir NOT IN ('ASC','DESC') SET @SortDir = 'ASC';
    IF @SortBy NOT IN (N'NameEs', N'CourseCode', N'CreatedAtUtc') SET @SortBy = N'NameEs';

    SELECT  c.CourseId, c.PublicId, c.CourseCode, c.NameEs, c.NameEn
          , c.DeliveryType, c.[Status], c.CurrentVersionId, c.EstimatedMinutes
          , cat.NameEs AS CategoryName
          , (SELECT COUNT(*) FROM dlv.Enrollment e
             WHERE e.CourseId = c.CourseId AND e.[Status] IN (1,2)) AS ActiveEnrollments
    FROM lms.Course c
    LEFT JOIN lms.CourseCategory cat ON cat.CourseCategoryId = c.CourseCategoryId
    WHERE c.IsDeleted = 0
      AND (@SearchText       IS NULL OR c.NameEs LIKE N'%' + @SearchText + N'%' OR c.CourseCode LIKE @SearchText + N'%')
      AND (@CourseCategoryId IS NULL OR c.CourseCategoryId = @CourseCategoryId)
      AND (@DeliveryType     IS NULL OR c.DeliveryType     = @DeliveryType)
      AND (@Status           IS NULL OR c.[Status]         = @Status)
      AND (@OwnerDepartmentId IS NULL OR c.OwnerDepartmentId = @OwnerDepartmentId)
    ORDER BY
          CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'NameEs'       THEN c.NameEs       END ASC
        , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'NameEs'       THEN c.NameEs       END DESC
        , CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'CourseCode'   THEN c.CourseCode   END ASC
        , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'CourseCode'   THEN c.CourseCode   END DESC
        , CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC
        , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC
        , c.CourseId
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    SELECT COUNT(*) AS TotalCount FROM lms.Course c
    WHERE c.IsDeleted = 0
      AND (@SearchText       IS NULL OR c.NameEs LIKE N'%' + @SearchText + N'%' OR c.CourseCode LIKE @SearchText + N'%')
      AND (@CourseCategoryId IS NULL OR c.CourseCategoryId = @CourseCategoryId)
      AND (@DeliveryType     IS NULL OR c.DeliveryType     = @DeliveryType)
      AND (@Status           IS NULL OR c.[Status]         = @Status)
      AND (@OwnerDepartmentId IS NULL OR c.OwnerDepartmentId = @OwnerDepartmentId)
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Course_Update
      @ActorUserId INT, @CourseId INT
    , @NameEs NVARCHAR(250) = NULL, @NameEn NVARCHAR(250) = NULL
    , @CourseCategoryId INT = NULL, @OwnerDepartmentId INT = NULL
    , @EstimatedMinutes INT = NULL, @AllowSelfEnrollment BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    UPDATE lms.Course
    SET  NameEs = ISNULL(@NameEs, NameEs)
       , NameEn = ISNULL(@NameEn, NameEn)
       , CourseCategoryId = ISNULL(@CourseCategoryId, CourseCategoryId)
       , OwnerDepartmentId = ISNULL(@OwnerDepartmentId, OwnerDepartmentId)
       , EstimatedMinutes = ISNULL(@EstimatedMinutes, EstimatedMinutes)
       , AllowSelfEnrollment = ISNULL(@AllowSelfEnrollment, AllowSelfEnrollment)
       , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE CourseId = @CourseId AND IsDeleted = 0;
    IF @@ROWCOUNT = 0 THROW 50001, 'Curso no encontrado.', 1;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Course_Retire
      @ActorUserId INT, @CourseId INT, @Reason NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50209 el curso satisface requisitos activos */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.retire') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF EXISTS (SELECT 1 FROM comp.RequirementSatisfier rs
                   JOIN comp.CompetencyRequirement r ON r.RequirementId = rs.RequirementId AND r.[Status] = 1
                   WHERE rs.SatisfierType = 1 AND rs.SatisfierId = @CourseId)
            THROW 50209, 'No se puede retirar: el curso satisface requisitos de competencia activos. Reemplacelo primero.', 1;

        BEGIN TRANSACTION;
        UPDATE lms.Course SET [Status] = 3, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE CourseId = @CourseId;

        EXEC aud.usp_Event_Log @EventType = N'Course.Retired', @EntityType = N'Course'
           , @EntityId = @CourseId, @ActorUserId = @ActorUserId, @Severity = 3
           , @Summary = N'Curso retirado del catalogo.';
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Course_Retire', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_CourseVersion_Get
      @ActorUserId INT, @CourseVersionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT v.*, c.CourseCode, c.NameEs AS CourseNameEs
    FROM lms.CourseVersion v JOIN lms.Course c ON c.CourseId = v.CourseId
    WHERE v.CourseVersionId = @CourseVersionId;

    SELECT m.CourseModuleId, m.TitleEs, m.TitleEn, m.SortOrder, m.PrerequisiteModuleId
         , m.CompletionRule, m.MinimumScore, m.IsRequired
    FROM lms.CourseModule m
    WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0 ORDER BY m.SortOrder;

    SELECT i.ModuleItemId, i.CourseModuleId, i.ItemType, i.TargetId, i.TitleEs, i.TitleEn
         , i.SortOrder, i.Indent, i.IsRequiredForCompletion, i.CompletionCriteria
         , i.MinimumScore, i.MinimumSeconds, i.Points
    FROM lms.ModuleItem i
    JOIN lms.CourseModule m ON m.CourseModuleId = i.CourseModuleId
    WHERE m.CourseVersionId = @CourseVersionId AND i.IsDeleted = 0
    ORDER BY m.SortOrder, i.SortOrder;

    SELECT a.CourseApprovalId, a.ApprovalRole, a.ApproverUserId, u.DisplayName AS ApproverName
         , a.Decision, a.Comments, a.RequestedAtUtc, a.DecidedAtUtc
    FROM lms.CourseApproval a
    LEFT JOIN sec.[User] u ON u.UserId = a.ApproverUserId
    WHERE a.CourseVersionId = @CourseVersionId ORDER BY a.ApprovalRole;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Module_Add
      @ActorUserId INT, @CourseVersionId INT
    , @TitleEs NVARCHAR(250), @TitleEn NVARCHAR(250) = NULL
    , @SortOrder INT = NULL, @PrerequisiteModuleId INT = NULL
    , @CompletionRule TINYINT = 1, @MinimumScore DECIMAL(5,2) = NULL
    , @IsRequired BIT = 1, @CourseModuleId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50210 no se puede editar una version publicada */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF EXISTS (SELECT 1 FROM lms.CourseVersion WHERE CourseVersionId = @CourseVersionId AND [Status] NOT IN (1,2))
            THROW 50210, 'No se puede modificar una version publicada o retirada. Cree un borrador nuevo.', 1;

        IF @SortOrder IS NULL
            SELECT @SortOrder = ISNULL(MAX(SortOrder), 0) + 10
            FROM lms.CourseModule WHERE CourseVersionId = @CourseVersionId;

        INSERT INTO lms.CourseModule (CourseVersionId, TitleEs, TitleEn, SortOrder, PrerequisiteModuleId
                                    , CompletionRule, MinimumScore, IsRequired, CreatedByUserId)
        VALUES (@CourseVersionId, @TitleEs, @TitleEn, @SortOrder, @PrerequisiteModuleId
              , @CompletionRule, @MinimumScore, @IsRequired, @ActorUserId);
        SET @CourseModuleId = SCOPE_IDENTITY();
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Module_Add', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Module_SetRequirements
      @ActorUserId INT, @CourseModuleId INT
    , @CompletionRule TINYINT, @MinimumScore DECIMAL(5,2) = NULL
    , @IsRequired BIT = 1, @PrerequisiteModuleId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    UPDATE lms.CourseModule
    SET CompletionRule = @CompletionRule, MinimumScore = @MinimumScore
      , IsRequired = @IsRequired, PrerequisiteModuleId = @PrerequisiteModuleId
      , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE CourseModuleId = @CourseModuleId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_ModuleItem_Add
      @ActorUserId INT, @CourseModuleId INT, @ItemType TINYINT, @TargetId INT = NULL
    , @TitleEs NVARCHAR(250), @TitleEn NVARCHAR(250) = NULL
    , @SortOrder INT = NULL, @Indent TINYINT = 0
    , @IsRequiredForCompletion BIT = 1, @CompletionCriteria TINYINT = 1
    , @MinimumScore DECIMAL(5,2) = NULL, @MinimumSeconds INT = NULL
    , @Points DECIMAL(9,2) = NULL, @ModuleItemId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50211 TargetId requerido para este ItemType */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        /* ItemType 7 = SubHeader es el unico que admite TargetId NULL. */
        IF @ItemType <> 7 AND @TargetId IS NULL
            THROW 50211, 'TargetId es requerido para este tipo de item.', 1;

        IF @SortOrder IS NULL
            SELECT @SortOrder = ISNULL(MAX(SortOrder), 0) + 10
            FROM lms.ModuleItem WHERE CourseModuleId = @CourseModuleId;

        INSERT INTO lms.ModuleItem (CourseModuleId, ItemType, TargetId, TitleEs, TitleEn, SortOrder, Indent
                                  , IsRequiredForCompletion, CompletionCriteria, MinimumScore, MinimumSeconds
                                  , Points, CreatedByUserId)
        VALUES (@CourseModuleId, @ItemType, @TargetId, @TitleEs, @TitleEn, @SortOrder, @Indent
              , @IsRequiredForCompletion, @CompletionCriteria, @MinimumScore, @MinimumSeconds
              , @Points, @ActorUserId);
        SET @ModuleItemId = SCOPE_IDENTITY();
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_ModuleItem_Add', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_ModuleItem_Update
      @ActorUserId INT, @ModuleItemId INT
    , @TitleEs NVARCHAR(250) = NULL, @TitleEn NVARCHAR(250) = NULL
    , @SortOrder INT = NULL, @Indent TINYINT = NULL
    , @IsRequiredForCompletion BIT = NULL, @CompletionCriteria TINYINT = NULL
    , @MinimumScore DECIMAL(5,2) = NULL, @MinimumSeconds INT = NULL, @Points DECIMAL(9,2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    UPDATE lms.ModuleItem
    SET  TitleEs = ISNULL(@TitleEs, TitleEs), TitleEn = ISNULL(@TitleEn, TitleEn)
       , SortOrder = ISNULL(@SortOrder, SortOrder), Indent = ISNULL(@Indent, Indent)
       , IsRequiredForCompletion = ISNULL(@IsRequiredForCompletion, IsRequiredForCompletion)
       , CompletionCriteria = ISNULL(@CompletionCriteria, CompletionCriteria)
       , MinimumScore = ISNULL(@MinimumScore, MinimumScore)
       , MinimumSeconds = ISNULL(@MinimumSeconds, MinimumSeconds)
       , Points = ISNULL(@Points, Points)
       , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE ModuleItemId = @ModuleItemId AND IsDeleted = 0;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Page_Upsert
      @ActorUserId INT, @CourseVersionId INT, @PageId INT = NULL
    , @TitleEs NVARCHAR(250), @TitleEn NVARCHAR(250) = NULL
    , @BodyHtmlEs NVARCHAR(MAX) = NULL, @BodyHtmlEn NVARCHAR(MAX) = NULL
    , @EstimatedMinutes INT = NULL, @ResultPageId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    /* El HTML llega ya sanitizado por la API. T-SQL no sanitiza HTML. */
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

    IF @PageId IS NULL
    BEGIN
        INSERT INTO lms.Page (CourseVersionId, TitleEs, TitleEn, BodyHtmlEs, BodyHtmlEn, EstimatedMinutes, CreatedByUserId)
        VALUES (@CourseVersionId, @TitleEs, @TitleEn, @BodyHtmlEs, @BodyHtmlEn, @EstimatedMinutes, @ActorUserId);
        SET @ResultPageId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE lms.Page
        SET TitleEs = @TitleEs, TitleEn = @TitleEn, BodyHtmlEs = @BodyHtmlEs, BodyHtmlEn = @BodyHtmlEn
          , EstimatedMinutes = @EstimatedMinutes, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE PageId = @PageId AND IsDeleted = 0;
        SET @ResultPageId = @PageId;
    END;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Page_Get
      @ActorUserId INT, @PageId INT, @LocaleCode NVARCHAR(10) = N'es-DO'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.PageId, p.PublicId, p.CourseVersionId
         , CASE WHEN @LocaleCode = N'en-US' THEN ISNULL(p.TitleEn, p.TitleEs) ELSE p.TitleEs END AS Title
         , CASE WHEN @LocaleCode = N'en-US' THEN ISNULL(p.BodyHtmlEn, p.BodyHtmlEs) ELSE p.BodyHtmlEs END AS BodyHtml
         , p.EstimatedMinutes
    FROM lms.Page p WHERE p.PageId = @PageId AND p.IsDeleted = 0;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Category_Upsert
      @ActorUserId INT, @CourseCategoryId INT = NULL, @CategoryCode NVARCHAR(40)
    , @NameEs NVARCHAR(150), @NameEn NVARCHAR(150) = NULL
    , @ParentCategoryId INT = NULL, @SortOrder INT = 0
    , @ResultCategoryId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    IF @CourseCategoryId IS NULL
    BEGIN
        INSERT INTO lms.CourseCategory (CategoryCode, NameEs, NameEn, ParentCategoryId, SortOrder)
        VALUES (@CategoryCode, @NameEs, @NameEn, @ParentCategoryId, @SortOrder);
        SET @ResultCategoryId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE lms.CourseCategory
        SET CategoryCode = @CategoryCode, NameEs = @NameEs, NameEn = @NameEn
          , ParentCategoryId = @ParentCategoryId, SortOrder = @SortOrder
        WHERE CourseCategoryId = @CourseCategoryId;
        SET @ResultCategoryId = @CourseCategoryId;
    END;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Program_Create
      @ActorUserId INT, @ProgramCode NVARCHAR(40), @NameEs NVARCHAR(250)
    , @NameEn NVARCHAR(250) = NULL, @DescriptionEs NVARCHAR(MAX) = NULL
    , @EnforceSequence BIT = 1, @ProgramId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'program.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO lms.Program (ProgramCode, NameEs, NameEn, DescriptionEs, EnforceSequence, [Status], CreatedByUserId)
    VALUES (@ProgramCode, @NameEs, @NameEn, @DescriptionEs, @EnforceSequence, 1, @ActorUserId);
    SET @ProgramId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

/* =====================================================================
   Traduccion (GAP-10)
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_Translation_Upsert
      @ActorUserId INT, @EntityType TINYINT, @EntityId INT
    , @LocaleCode NVARCHAR(10), @FieldName NVARCHAR(50), @TranslatedText NVARCHAR(MAX)
    , @IsReview BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.translate') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        MERGE lms.ContentTranslation AS tgt
        USING (SELECT @EntityType AS EntityType, @EntityId AS EntityId
                    , @LocaleCode AS LocaleCode, @FieldName AS FieldName) AS src
        ON  tgt.EntityType = src.EntityType AND tgt.EntityId = src.EntityId
        AND tgt.LocaleCode = src.LocaleCode AND tgt.FieldName = src.FieldName
        WHEN MATCHED THEN UPDATE SET
              TranslatedText = @TranslatedText
            , TranslatedByUserId = CASE WHEN @IsReview = 0 THEN @ActorUserId ELSE tgt.TranslatedByUserId END
            , ReviewedByUserId   = CASE WHEN @IsReview = 1 THEN @ActorUserId ELSE tgt.ReviewedByUserId END
            , ModifiedAtUtc = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT
              (EntityType, EntityId, LocaleCode, FieldName, TranslatedText, TranslatedByUserId)
            VALUES (@EntityType, @EntityId, @LocaleCode, @FieldName, @TranslatedText, @ActorUserId);
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Translation_Upsert', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Translation_GetStatus
      @ActorUserId INT, @CourseVersionId INT
AS
BEGIN
    SET NOCOUNT ON;
    /* Cuenta campos traducibles vs traducidos por locale. Alimenta el
       semaforo de "listo para publicar en ingles". */
    ;WITH Translatable AS (
        SELECT 1 AS EntityType, p.PageId AS EntityId, N'Title' AS FieldName, p.TitleEn AS Existing
        FROM lms.Page p WHERE p.CourseVersionId = @CourseVersionId AND p.IsDeleted = 0
        UNION ALL
        SELECT 1, p.PageId, N'Body', p.BodyHtmlEn
        FROM lms.Page p WHERE p.CourseVersionId = @CourseVersionId AND p.IsDeleted = 0
        UNION ALL
        SELECT 2, m.CourseModuleId, N'Title', m.TitleEn
        FROM lms.CourseModule m WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0
        UNION ALL
        SELECT 3, i.ModuleItemId, N'Title', i.TitleEn
        FROM lms.ModuleItem i
        JOIN lms.CourseModule m ON m.CourseModuleId = i.CourseModuleId
        WHERE m.CourseVersionId = @CourseVersionId AND i.IsDeleted = 0
    )
    SELECT  COUNT(*) AS TotalFields
          , SUM(CASE WHEN Existing IS NOT NULL AND LEN(Existing) > 0 THEN 1 ELSE 0 END) AS TranslatedFields
          , CAST(100.0 * SUM(CASE WHEN Existing IS NOT NULL AND LEN(Existing) > 0 THEN 1 ELSE 0 END)
                 / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS CompletionPercent
    FROM Translatable;

    SELECT LocaleCode, TranslationStatus, CompletionPercent, IsAvailable
    FROM lms.CourseVersionLocale WHERE CourseVersionId = @CourseVersionId;
    RETURN 0;
END;
GO

/* =====================================================================
   Blueprint (cursos maestros replicados por sitio)
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_Blueprint_Link
      @ActorUserId INT, @BlueprintCourseId INT, @DerivedCourseId INT
    , @SyncContent BIT = 1, @SyncSettings BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.blueprint') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    IF @BlueprintCourseId = @DerivedCourseId
        THROW 50212, 'Un curso no puede ser blueprint de si mismo.', 1;

    INSERT INTO lms.CourseBlueprintLink (BlueprintCourseId, DerivedCourseId, SyncContent, SyncSettings)
    VALUES (@BlueprintCourseId, @DerivedCourseId, @SyncContent, @SyncSettings);
    RETURN 0;
END;
GO

/* Fase 3. Empuja la version publicada del blueprint a los derivados que
   tengan SyncContent = 1, creando un draft en cada uno. */
CREATE OR ALTER PROCEDURE lms.usp_Blueprint_PushUpdates
      @ActorUserId INT, @BlueprintCourseId INT, @AutoPublish BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.blueprint') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        DECLARE @SourceVersionId INT;
        SELECT @SourceVersionId = CurrentVersionId FROM lms.Course WHERE CourseId = @BlueprintCourseId;
        IF @SourceVersionId IS NULL THROW 50213, 'El blueprint no tiene una version publicada.', 1;

        DECLARE @DerivedCourseId INT, @NewVersionId INT;
        DECLARE derived CURSOR LOCAL FAST_FORWARD FOR
            SELECT DerivedCourseId FROM lms.CourseBlueprintLink
            WHERE BlueprintCourseId = @BlueprintCourseId AND SyncContent = 1;

        OPEN derived;
        FETCH NEXT FROM derived INTO @DerivedCourseId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                EXEC lms.usp_CourseVersion_CreateDraft
                      @ActorUserId = @ActorUserId, @CourseId = @DerivedCourseId
                    , @SourceVersionId = @SourceVersionId
                    , @ChangeSummary = N'Sincronizacion desde blueprint.'
                    , @NewVersionId = @NewVersionId OUTPUT;

                UPDATE lms.CourseBlueprintLink
                SET LastSyncedAtUtc = SYSUTCDATETIME(), LastSyncedVersionId = @SourceVersionId
                WHERE BlueprintCourseId = @BlueprintCourseId AND DerivedCourseId = @DerivedCourseId;
            END TRY
            BEGIN CATCH
                /* Un derivado con draft abierto no detiene al resto. */
                EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Blueprint_PushUpdates', @ActorUserId = @ActorUserId;
            END CATCH;
            FETCH NEXT FROM derived INTO @DerivedCourseId;
        END;
        CLOSE derived; DEALLOCATE derived;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Blueprint_PushUpdates', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

PRINT '=== 12_procs_catalog_content.sql completado ===';
GO
