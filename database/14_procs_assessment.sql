/* =====================================================================
   Classroom - LMS by Airlink
   14_procs_assessment.sql
   Esquema: asmt (bancos, preguntas, quizzes, intentos, rubricas,
            evaluacion practica / OJT)

   Principio no negociable de este archivo: EL INTENTO ES UN SNAPSHOT.
   Cuando un operador arranca un quiz, se copian pregunta, opciones,
   puntos y cual era la correcta a las tablas QuizAttempt*. Si manana
   Calidad edita la pregunta, el intento de ayer sigue mostrando lo que
   el operador realmente vio. Sin esto, el expediente no se defiende.

   GAP-05: la evaluacion practica (OJT) tiene el mismo peso que un quiz.
   Un operador de Roxer no se certifica contestando preguntas: se
   certifica ejecutando el proceso delante de un evaluador calificado.

   Codigos de error de este archivo: 50400-50499
   ===================================================================== */

USE AIRLINK_LMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 14_procs_assessment.sql iniciado ===';
GO

/* =====================================================================
   asmt.usp_Attempt_Start

   Materializa el intento. Selecciona preguntas segun el modo de cada
   seccion (fijas o N tomadas de un banco), las baraja si aplica, y
   congela todo en QuizAttemptQuestion / QuizAttemptOption.
   ===================================================================== */
CREATE OR ALTER PROCEDURE asmt.usp_Attempt_Start
      @ActorUserId    INT
    , @QuizId         INT
    , @EnrollmentId   INT              = NULL
    , @ModuleItemId   INT              = NULL
    , @LocaleCode     NVARCHAR(10)     = NULL
    , @SessionId      UNIQUEIDENTIFIER = NULL
    , @DeviceId       INT              = NULL
    , @IpAddress      NVARCHAR(45)     = NULL
    , @IdempotencyKey UNIQUEIDENTIFIER = NULL
    , @QuizAttemptId  INT              = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------
       Proposito : abrir un intento de quiz con snapshot completo.
       Retorna   : cabecera del intento + preguntas + opciones (sin
                   revelar cual es la correcta).
       Errores   : 50401 quiz inactivo o sin preguntas
                   50402 intentos agotados
                   50403 ya hay un intento en progreso
                   50404 banco sin preguntas suficientes
       --------------------------------------------------------------- */

    BEGIN TRY
        DECLARE @EmployeeId INT, @MaxAttempts TINYINT, @TimeLimit INT
              , @ShuffleQ BIT, @ShuffleO BIT, @AttemptNumber TINYINT
              , @UseEn BIT = 0, @NowUtc DATETIME2(3) = SYSUTCDATETIME();

        IF @IdempotencyKey IS NOT NULL
           AND EXISTS (SELECT 1 FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey)
        BEGIN
            SELECT @QuizAttemptId = ResultEntityId FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey;
            RETURN 0;
        END;

        SELECT @EmployeeId = u.EmployeeId, @LocaleCode = ISNULL(@LocaleCode, u.PreferredLocale)
        FROM sec.[User] u WHERE u.UserId = @ActorUserId;

        IF @EmployeeId IS NULL THROW 50405, 'El usuario no tiene empleado asociado; no puede tomar evaluaciones.', 1;

        SET @UseEn = CASE WHEN @LocaleCode = N'en-US' THEN 1 ELSE 0 END;

        SELECT @MaxAttempts = q.MaxAttempts, @TimeLimit = q.TimeLimitMinutes
             , @ShuffleQ = q.ShuffleQuestions, @ShuffleO = q.ShuffleOptions
        FROM asmt.Quiz q WHERE q.QuizId = @QuizId AND q.IsActive = 1 AND q.IsDeleted = 0;

        IF @MaxAttempts IS NULL THROW 50401, 'El quiz no existe o esta inactivo.', 1;

        IF EXISTS (SELECT 1 FROM asmt.QuizAttempt
                   WHERE QuizId = @QuizId AND EmployeeId = @EmployeeId AND [Status] = 1)
            THROW 50403, 'Ya existe un intento en progreso para este quiz.', 1;

        SELECT @AttemptNumber = ISNULL(MAX(AttemptNumber), 0) + 1
        FROM asmt.QuizAttempt WHERE QuizId = @QuizId AND EmployeeId = @EmployeeId;

        IF @AttemptNumber > @MaxAttempts
            THROW 50402, 'Se agotaron los intentos permitidos para este quiz.', 1;

        BEGIN TRANSACTION;

        INSERT INTO asmt.QuizAttempt (QuizId, EnrollmentId, EmployeeId, ModuleItemId, AttemptNumber
                                    , [Status], StartedAtUtc, ExpiresAtUtc, SessionId, DeviceId, IpAddress)
        VALUES (@QuizId, @EnrollmentId, @EmployeeId, @ModuleItemId, @AttemptNumber
              , 1, @NowUtc
              , CASE WHEN @TimeLimit IS NULL THEN NULL ELSE DATEADD(MINUTE, @TimeLimit, @NowUtc) END
              , @SessionId, @DeviceId, @IpAddress);

        SET @QuizAttemptId = SCOPE_IDENTITY();

        /* --- Seleccion de preguntas ---------------------------------
           SelectionMode 1 = preguntas fijas (asmt.QuizQuestion)
           SelectionMode 2 = N aleatorias de banco (asmt.QuizSectionSource)
           Se resuelve por seccion respetando el orden de las secciones. */

        DECLARE @Selected TABLE (
              RowNo         INT IDENTITY(1,1) PRIMARY KEY
            , QuestionId    INT NOT NULL
            , SectionOrder  INT NOT NULL
            , PointsOverride DECIMAL(9,2) NULL
        );

        /* Fijas */
        INSERT INTO @Selected (QuestionId, SectionOrder, PointsOverride)
        SELECT qq.QuestionId, s.SortOrder, qq.PointsOverride
        FROM asmt.QuizSection s
        JOIN asmt.QuizQuestion qq ON qq.QuizSectionId = s.QuizSectionId
        JOIN asmt.Question qn ON qn.QuestionId = qq.QuestionId AND qn.IsActive = 1 AND qn.IsDeleted = 0
        WHERE s.QuizId = @QuizId AND s.SelectionMode = 1
        ORDER BY s.SortOrder, qq.SortOrder;

        /* Aleatorias de banco, seccion por seccion */
        DECLARE @SectionId INT, @SectionOrder INT, @BankId INT, @Count INT
              , @Difficulty TINYINT, @PtsPerQ DECIMAL(9,2), @Available INT;

        DECLARE src CURSOR LOCAL FAST_FORWARD FOR
            SELECT s.QuizSectionId, s.SortOrder, ss.QuestionBankId, ss.QuestionCount
                 , ss.DifficultyFilter, ss.PointsPerQuestion
            FROM asmt.QuizSection s
            JOIN asmt.QuizSectionSource ss ON ss.QuizSectionId = s.QuizSectionId
            WHERE s.QuizId = @QuizId AND s.SelectionMode = 2
            ORDER BY s.SortOrder;

        OPEN src;
        FETCH NEXT FROM src INTO @SectionId, @SectionOrder, @BankId, @Count, @Difficulty, @PtsPerQ;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @Available = COUNT(*)
            FROM asmt.Question
            WHERE QuestionBankId = @BankId AND IsActive = 1 AND IsDeleted = 0
              AND (@Difficulty IS NULL OR Difficulty = @Difficulty);

            IF @Available < @Count
            BEGIN
                CLOSE src; DEALLOCATE src;
                THROW 50404, 'El banco de preguntas no tiene suficientes preguntas activas para armar el quiz.', 1;
            END;

            INSERT INTO @Selected (QuestionId, SectionOrder, PointsOverride)
            SELECT TOP (@Count) QuestionId, @SectionOrder, @PtsPerQ
            FROM asmt.Question
            WHERE QuestionBankId = @BankId AND IsActive = 1 AND IsDeleted = 0
              AND (@Difficulty IS NULL OR Difficulty = @Difficulty)
            ORDER BY NEWID();

            FETCH NEXT FROM src INTO @SectionId, @SectionOrder, @BankId, @Count, @Difficulty, @PtsPerQ;
        END;
        CLOSE src; DEALLOCATE src;

        IF NOT EXISTS (SELECT 1 FROM @Selected)
        BEGIN
            ROLLBACK TRANSACTION;
            THROW 50401, 'El quiz no tiene preguntas configuradas.', 1;
        END;

        /* --- Snapshot de preguntas --------------------------------- */
        INSERT INTO asmt.QuizAttemptQuestion (QuizAttemptId, QuestionId, QuestionType
                                            , QuestionTextSnapshot, LocaleCode, PointsPossible
                                            , PresentedOrder, NumericAnswerSnapshot
                                            , NumericToleranceSnapshot, ReferenceDocumentCode)
        SELECT  @QuizAttemptId
              , q.QuestionId
              , q.QuestionType
              , CASE WHEN @UseEn = 1 THEN ISNULL(q.TextEn, q.TextEs) ELSE q.TextEs END
              , @LocaleCode
              , ISNULL(s.PointsOverride, q.Points)
              , ROW_NUMBER() OVER (ORDER BY s.SectionOrder
                                          , CASE WHEN @ShuffleQ = 1 THEN NEWID() ELSE NULL END
                                          , s.RowNo)
              , q.NumericAnswer
              , q.NumericTolerance
              , q.ReferenceDocumentCode
        FROM @Selected s
        JOIN asmt.Question q ON q.QuestionId = s.QuestionId;

        /* --- Snapshot de opciones ---------------------------------- */
        INSERT INTO asmt.QuizAttemptOption (AttemptQuestionId, QuestionOptionId, OptionTextSnapshot
                                          , IsCorrectSnapshot, PresentedOrder, MatchGroupKey
                                          , HotSpotX, HotSpotY, HotSpotRadius, PartialCredit)
        SELECT  aq.AttemptQuestionId
              , o.QuestionOptionId
              , CASE WHEN @UseEn = 1 THEN ISNULL(o.TextEn, o.TextEs) ELSE o.TextEs END
              , o.IsCorrect
              , ROW_NUMBER() OVER (PARTITION BY aq.AttemptQuestionId
                                   ORDER BY CASE WHEN @ShuffleO = 1 THEN NEWID() ELSE NULL END, o.SortOrder)
              , o.MatchGroupKey, o.HotSpotX, o.HotSpotY, o.HotSpotRadius, o.PartialCredit
        FROM asmt.QuizAttemptQuestion aq
        JOIN asmt.QuestionOption o ON o.QuestionId = aq.QuestionId AND o.IsDeleted = 0
        WHERE aq.QuizAttemptId = @QuizAttemptId;

        UPDATE a
        SET a.PointsPossible = (SELECT SUM(aq.PointsPossible) FROM asmt.QuizAttemptQuestion aq
                                WHERE aq.QuizAttemptId = @QuizAttemptId)
        FROM asmt.QuizAttempt a WHERE a.QuizAttemptId = @QuizAttemptId;

        IF @IdempotencyKey IS NOT NULL
            INSERT INTO aud.IdempotencyKey (IdempotencyKey, OperationName, ActorUserId, ResultEntityId)
            VALUES (@IdempotencyKey, N'asmt.usp_Attempt_Start', @ActorUserId, @QuizAttemptId);

        COMMIT TRANSACTION;

        /* Resultset 1: cabecera */
        SELECT a.QuizAttemptId, a.PublicId, a.QuizId, a.AttemptNumber, a.StartedAtUtc
             , a.ExpiresAtUtc, a.PointsPossible
             , q.PassingScore, q.OneQuestionAtATime, q.AllowBacktrack, q.ShowScoreImmediately
             , CASE WHEN @UseEn = 1 THEN ISNULL(q.TitleEn, q.TitleEs) ELSE q.TitleEs END AS Title
             , CASE WHEN @UseEn = 1 THEN ISNULL(q.InstructionsEn, q.InstructionsEs) ELSE q.InstructionsEs END AS Instructions
        FROM asmt.QuizAttempt a JOIN asmt.Quiz q ON q.QuizId = a.QuizId
        WHERE a.QuizAttemptId = @QuizAttemptId;

        /* Resultset 2: preguntas */
        SELECT aq.AttemptQuestionId, aq.QuestionType, aq.QuestionTextSnapshot
             , aq.PointsPossible, aq.PresentedOrder
        FROM asmt.QuizAttemptQuestion aq
        WHERE aq.QuizAttemptId = @QuizAttemptId ORDER BY aq.PresentedOrder;

        /* Resultset 3: opciones. IsCorrectSnapshot NO se expone aqui. */
        SELECT ao.AttemptOptionId, ao.AttemptQuestionId, ao.OptionTextSnapshot
             , ao.PresentedOrder, ao.MatchGroupKey
        FROM asmt.QuizAttemptOption ao
        JOIN asmt.QuizAttemptQuestion aq ON aq.AttemptQuestionId = ao.AttemptQuestionId
        WHERE aq.QuizAttemptId = @QuizAttemptId
        ORDER BY aq.PresentedOrder, ao.PresentedOrder;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Attempt_Start', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   asmt.usp_Attempt_SaveAnswer  -- guardado incremental (autosave)
   ===================================================================== */
CREATE OR ALTER PROCEDURE asmt.usp_Attempt_SaveAnswer
      @ActorUserId  INT
    , @QuizAttemptId INT
    , @Answers      asmt.AnswerType READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50406 intento no esta en progreso, 50407 intento vencido */
    BEGIN TRY
        DECLARE @Status TINYINT, @ExpiresAtUtc DATETIME2(3), @EmployeeId INT;
        SELECT @Status = [Status], @ExpiresAtUtc = ExpiresAtUtc, @EmployeeId = EmployeeId
        FROM asmt.QuizAttempt WHERE QuizAttemptId = @QuizAttemptId;

        IF @Status IS NULL THROW 50001, 'Intento no encontrado.', 1;
        IF @Status <> 1 THROW 50406, 'El intento no esta en progreso.', 1;

        IF NOT EXISTS (SELECT 1 FROM sec.[User] WHERE UserId = @ActorUserId AND EmployeeId = @EmployeeId)
            THROW 50002, 'El usuario no puede responder este intento.', 1;

        IF @ExpiresAtUtc IS NOT NULL AND @ExpiresAtUtc < SYSUTCDATETIME()
            THROW 50407, 'El tiempo del intento expiro.', 1;

        MERGE asmt.QuizAttemptAnswer AS tgt
        USING (SELECT a.AttemptQuestionId, a.SelectedOptionIds, a.TextAnswer, a.NumericAnswer
               FROM @Answers a
               JOIN asmt.QuizAttemptQuestion aq ON aq.AttemptQuestionId = a.AttemptQuestionId
               WHERE aq.QuizAttemptId = @QuizAttemptId) AS src
        ON tgt.AttemptQuestionId = src.AttemptQuestionId
        WHEN MATCHED THEN UPDATE SET
              SelectedOptionIds = src.SelectedOptionIds
            , TextAnswer = src.TextAnswer
            , NumericAnswer = src.NumericAnswer
            , AnsweredAtUtc = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT
              (AttemptQuestionId, SelectedOptionIds, TextAnswer, NumericAnswer)
            VALUES (src.AttemptQuestionId, src.SelectedOptionIds, src.TextAnswer, src.NumericAnswer);

        SELECT COUNT(*) AS AnswersSaved FROM @Answers;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Attempt_SaveAnswer', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   asmt.usp_Attempt_Submit

   Califica contra el SNAPSHOT, nunca contra las tablas maestras.
   Tipos auto-calificables: 1,2,3,4,5,7 y 9.
   Tipos manuales: 6 (ShortAnswer), 8 (Essay), 10 (FileUpload) -> el
   intento queda en PendingManualGrading.
   ===================================================================== */
CREATE OR ALTER PROCEDURE asmt.usp_Attempt_Submit
      @ActorUserId    INT
    , @QuizAttemptId  INT
    , @Answers        asmt.AnswerType READONLY
    , @TimeSpentSeconds INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50406 intento no esta en progreso */
    BEGIN TRY
        DECLARE @Status TINYINT, @EmployeeId INT, @QuizId INT, @EnrollmentId INT
              , @ModuleItemId INT, @PassingScore DECIMAL(5,2), @ScorePolicy TINYINT
              , @ShowCorrect TINYINT, @NowUtc DATETIME2(3) = SYSUTCDATETIME();

        SELECT @Status = a.[Status], @EmployeeId = a.EmployeeId, @QuizId = a.QuizId
             , @EnrollmentId = a.EnrollmentId, @ModuleItemId = a.ModuleItemId
             , @PassingScore = q.PassingScore, @ScorePolicy = q.ScorePolicy
             , @ShowCorrect = q.ShowCorrectAnswers
        FROM asmt.QuizAttempt a JOIN asmt.Quiz q ON q.QuizId = a.QuizId
        WHERE a.QuizAttemptId = @QuizAttemptId;

        IF @Status IS NULL THROW 50001, 'Intento no encontrado.', 1;
        IF @Status <> 1 THROW 50406, 'El intento no esta en progreso.', 1;

        BEGIN TRANSACTION;

        /* Guardar el ultimo lote de respuestas */
        MERGE asmt.QuizAttemptAnswer AS tgt
        USING (SELECT a.AttemptQuestionId, a.SelectedOptionIds, a.TextAnswer, a.NumericAnswer
               FROM @Answers a
               JOIN asmt.QuizAttemptQuestion aq ON aq.AttemptQuestionId = a.AttemptQuestionId
               WHERE aq.QuizAttemptId = @QuizAttemptId) AS src
        ON tgt.AttemptQuestionId = src.AttemptQuestionId
        WHEN MATCHED THEN UPDATE SET
              SelectedOptionIds = src.SelectedOptionIds, TextAnswer = src.TextAnswer
            , NumericAnswer = src.NumericAnswer, AnsweredAtUtc = @NowUtc
        WHEN NOT MATCHED THEN INSERT (AttemptQuestionId, SelectedOptionIds, TextAnswer, NumericAnswer)
            VALUES (src.AttemptQuestionId, src.SelectedOptionIds, src.TextAnswer, src.NumericAnswer);

        /* Asegurar una fila de respuesta por pregunta, aunque este vacia:
           "no contestada" tambien es un dato de la evaluacion. */
        INSERT INTO asmt.QuizAttemptAnswer (AttemptQuestionId)
        SELECT aq.AttemptQuestionId
        FROM asmt.QuizAttemptQuestion aq
        WHERE aq.QuizAttemptId = @QuizAttemptId
          AND NOT EXISTS (SELECT 1 FROM asmt.QuizAttemptAnswer x WHERE x.AttemptQuestionId = aq.AttemptQuestionId);

        /* --- Calificacion automatica ------------------------------- */

        /* Opcion unica / VerdaderoFalso / HotSpot: una sola seleccion. */
        UPDATE ans
        SET  ans.IsCorrect = CASE WHEN opt.IsCorrectSnapshot = 1 THEN 1 ELSE 0 END
           , ans.PointsEarned = CASE WHEN opt.IsCorrectSnapshot = 1 THEN aq.PointsPossible ELSE 0 END
           , ans.GradedAtUtc = @NowUtc
        FROM asmt.QuizAttemptAnswer ans
        JOIN asmt.QuizAttemptQuestion aq ON aq.AttemptQuestionId = ans.AttemptQuestionId
        LEFT JOIN asmt.QuizAttemptOption opt
               ON opt.AttemptOptionId = TRY_CONVERT(INT, ans.SelectedOptionIds)
              AND opt.AttemptQuestionId = aq.AttemptQuestionId
        WHERE aq.QuizAttemptId = @QuizAttemptId
          AND aq.QuestionType IN (1, 3, 9);

        /* Opcion multiple: credito total solo si el conjunto coincide
           exacto. Airlink no da credito parcial en preguntas de proceso:
           media respuesta correcta en el piso es una unidad mal armada. */
        ;WITH Parsed AS (
            SELECT  ans.AttemptAnswerId
                  , aq.AttemptQuestionId
                  , aq.PointsPossible
                  , SelectedCount = (SELECT COUNT(*) FROM STRING_SPLIT(ISNULL(ans.SelectedOptionIds, N''), N',')
                                     WHERE RTRIM(LTRIM([value])) <> N'')
                  , CorrectSelected = (
                        SELECT COUNT(*)
                        FROM STRING_SPLIT(ISNULL(ans.SelectedOptionIds, N''), N',') s
                        JOIN asmt.QuizAttemptOption o
                          ON o.AttemptOptionId = TRY_CONVERT(INT, RTRIM(LTRIM(s.[value])))
                         AND o.AttemptQuestionId = aq.AttemptQuestionId
                        WHERE o.IsCorrectSnapshot = 1)
                  , TotalCorrect = (SELECT COUNT(*) FROM asmt.QuizAttemptOption o2
                                    WHERE o2.AttemptQuestionId = aq.AttemptQuestionId AND o2.IsCorrectSnapshot = 1)
            FROM asmt.QuizAttemptAnswer ans
            JOIN asmt.QuizAttemptQuestion aq ON aq.AttemptQuestionId = ans.AttemptQuestionId
            WHERE aq.QuizAttemptId = @QuizAttemptId AND aq.QuestionType = 2
        )
        UPDATE ans
        SET  ans.IsCorrect = CASE WHEN p.CorrectSelected = p.TotalCorrect
                                   AND p.SelectedCount = p.TotalCorrect THEN 1 ELSE 0 END
           , ans.PointsEarned = CASE WHEN p.CorrectSelected = p.TotalCorrect
                                      AND p.SelectedCount = p.TotalCorrect THEN p.PointsPossible ELSE 0 END
           , ans.GradedAtUtc = @NowUtc
        FROM asmt.QuizAttemptAnswer ans
        JOIN Parsed p ON p.AttemptAnswerId = ans.AttemptAnswerId;

        /* Emparejamiento / Ordenamiento: la respuesta llega como CSV de
           AttemptOptionId en el orden elegido. Correcto = el CSV coincide
           con el orden correcto guardado en el snapshot. */
        ;WITH Expected AS (
            SELECT  aq.AttemptQuestionId
                  , ExpectedCsv = STUFF((
                        SELECT N',' + CAST(o.AttemptOptionId AS NVARCHAR(20))
                        FROM asmt.QuizAttemptOption o
                        WHERE o.AttemptQuestionId = aq.AttemptQuestionId AND o.IsCorrectSnapshot = 1
                        ORDER BY o.MatchGroupKey, o.AttemptOptionId
                        FOR XML PATH(N''), TYPE).value(N'.', N'NVARCHAR(MAX)'), 1, 1, N'')
            FROM asmt.QuizAttemptQuestion aq
            WHERE aq.QuizAttemptId = @QuizAttemptId AND aq.QuestionType IN (4, 5)
        )
        UPDATE ans
        SET  ans.IsCorrect = CASE WHEN REPLACE(ISNULL(ans.SelectedOptionIds, N''), N' ', N'') = e.ExpectedCsv
                                  THEN 1 ELSE 0 END
           , ans.PointsEarned = CASE WHEN REPLACE(ISNULL(ans.SelectedOptionIds, N''), N' ', N'') = e.ExpectedCsv
                                     THEN aq.PointsPossible ELSE 0 END
           , ans.GradedAtUtc = @NowUtc
        FROM asmt.QuizAttemptAnswer ans
        JOIN asmt.QuizAttemptQuestion aq ON aq.AttemptQuestionId = ans.AttemptQuestionId
        JOIN Expected e ON e.AttemptQuestionId = aq.AttemptQuestionId;

        /* Numerica con tolerancia. Critica para mediciones de proceso
           (presion, temperatura, torque). */
        UPDATE ans
        SET  ans.IsCorrect = CASE
                WHEN ans.NumericAnswer IS NULL THEN 0
                WHEN aq.NumericAnswerSnapshot IS NULL THEN 0
                WHEN ABS(ans.NumericAnswer - aq.NumericAnswerSnapshot)
                     <= ISNULL(aq.NumericToleranceSnapshot, 0) THEN 1
                ELSE 0 END
           , ans.PointsEarned = CASE
                WHEN ans.NumericAnswer IS NOT NULL AND aq.NumericAnswerSnapshot IS NOT NULL
                 AND ABS(ans.NumericAnswer - aq.NumericAnswerSnapshot)
                     <= ISNULL(aq.NumericToleranceSnapshot, 0) THEN aq.PointsPossible
                ELSE 0 END
           , ans.GradedAtUtc = @NowUtc
        FROM asmt.QuizAttemptAnswer ans
        JOIN asmt.QuizAttemptQuestion aq ON aq.AttemptQuestionId = ans.AttemptQuestionId
        WHERE aq.QuizAttemptId = @QuizAttemptId AND aq.QuestionType = 7;

        /* --- Cierre del intento ------------------------------------ */
        DECLARE @PendingManual INT, @Earned DECIMAL(9,2), @Possible DECIMAL(9,2), @Percent DECIMAL(5,2);

        SELECT @PendingManual = COUNT(*)
        FROM asmt.QuizAttemptQuestion aq
        WHERE aq.QuizAttemptId = @QuizAttemptId AND aq.QuestionType IN (6, 8, 10);

        SELECT  @Earned   = ISNULL(SUM(ans.PointsEarned), 0)
              , @Possible = ISNULL(SUM(aq.PointsPossible), 0)
        FROM asmt.QuizAttemptQuestion aq
        LEFT JOIN asmt.QuizAttemptAnswer ans ON ans.AttemptQuestionId = aq.AttemptQuestionId
        WHERE aq.QuizAttemptId = @QuizAttemptId;

        SET @Percent = CAST(100.0 * @Earned / NULLIF(@Possible, 0) AS DECIMAL(5,2));

        UPDATE asmt.QuizAttempt
        SET  [Status] = CASE WHEN @PendingManual > 0 THEN 5 ELSE 3 END
           , SubmittedAtUtc = @NowUtc
           , GradedAtUtc = CASE WHEN @PendingManual > 0 THEN NULL ELSE @NowUtc END
           , PointsEarned = @Earned
           , PointsPossible = @Possible
           , ScorePercent = CASE WHEN @PendingManual > 0 THEN NULL ELSE @Percent END
           , IsPassed = CASE WHEN @PendingManual > 0 THEN NULL
                             WHEN @Percent >= @PassingScore THEN 1 ELSE 0 END
           , TimeSpentSeconds = ISNULL(@TimeSpentSeconds, DATEDIFF(SECOND, StartedAtUtc, @NowUtc))
        WHERE QuizAttemptId = @QuizAttemptId;

        /* Evidencia de inscripcion */
        IF @EnrollmentId IS NOT NULL AND @PendingManual = 0
            INSERT INTO dlv.EnrollmentEvidence (EnrollmentId, EvidenceType, EvidenceId, IsPassing, ScorePercent)
            VALUES (@EnrollmentId, 1, @QuizAttemptId
                  , CASE WHEN @Percent >= @PassingScore THEN 1 ELSE 0 END, @Percent);

        EXEC aud.usp_Event_Log
              @EventType   = N'QuizAttempt.Submitted'
            , @EntityType  = N'QuizAttempt'
            , @EntityId    = @QuizAttemptId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Summary     = N'Intento de evaluacion enviado.';

        COMMIT TRANSACTION;

        /* Propagar el progreso del item si el quiz vive dentro de un curso. */
        IF @EnrollmentId IS NOT NULL AND @ModuleItemId IS NOT NULL AND @PendingManual = 0
           AND @Percent >= @PassingScore
        BEGIN
            BEGIN TRY
                EXEC dlv.usp_Progress_CompleteItem
                      @ActorUserId = @ActorUserId, @EnrollmentId = @EnrollmentId
                    , @ModuleItemId = @ModuleItemId, @ScorePercent = @Percent;
            END TRY
            BEGIN CATCH
                EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Attempt_Submit', @ActorUserId = @ActorUserId;
            END CATCH;
        END;

        /* Resultado. Las respuestas correctas se revelan solo si la
           configuracion del quiz lo permite (1=Nunca 2=DespuesDeEnviar
           3=DespuesDelUltimoIntento). */
        SELECT a.QuizAttemptId, a.[Status], a.PointsEarned, a.PointsPossible
             , a.ScorePercent, a.IsPassed, a.SubmittedAtUtc
             , @PendingManual AS PendingManualQuestions
        FROM asmt.QuizAttempt a WHERE a.QuizAttemptId = @QuizAttemptId;

        IF @ShowCorrect = 2
            SELECT aq.AttemptQuestionId, aq.QuestionTextSnapshot, aq.ReferenceDocumentCode
                 , ans.IsCorrect, ans.PointsEarned
                 , CorrectOptions = (SELECT o.AttemptOptionId, o.OptionTextSnapshot
                                     FROM asmt.QuizAttemptOption o
                                     WHERE o.AttemptQuestionId = aq.AttemptQuestionId AND o.IsCorrectSnapshot = 1
                                     FOR JSON PATH)
            FROM asmt.QuizAttemptQuestion aq
            LEFT JOIN asmt.QuizAttemptAnswer ans ON ans.AttemptQuestionId = aq.AttemptQuestionId
            WHERE aq.QuizAttemptId = @QuizAttemptId
            ORDER BY aq.PresentedOrder;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Attempt_Submit', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   asmt.usp_Attempt_GradeManual
   Calificacion de preguntas abiertas por un instructor.
   ===================================================================== */
CREATE OR ALTER PROCEDURE asmt.usp_Attempt_GradeManual
      @ActorUserId       INT
    , @AttemptQuestionId INT
    , @PointsEarned      DECIMAL(9,2)
    , @GraderComments    NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50408 puntaje fuera de rango */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'assessment.grade') = 0
            THROW 50002, 'El usuario no tiene permiso para calificar.', 1;

        DECLARE @QuizAttemptId INT, @PointsPossible DECIMAL(9,2);
        SELECT @QuizAttemptId = QuizAttemptId, @PointsPossible = PointsPossible
        FROM asmt.QuizAttemptQuestion WHERE AttemptQuestionId = @AttemptQuestionId;

        IF @QuizAttemptId IS NULL THROW 50001, 'Pregunta del intento no encontrada.', 1;
        IF @PointsEarned < 0 OR @PointsEarned > @PointsPossible
            THROW 50408, 'El puntaje otorgado esta fuera del rango permitido para la pregunta.', 1;

        BEGIN TRANSACTION;

        UPDATE asmt.QuizAttemptAnswer
        SET PointsEarned = @PointsEarned
          , IsCorrect = CASE WHEN @PointsEarned >= @PointsPossible THEN 1 ELSE 0 END
          , GraderComments = @GraderComments
          , GradedByUserId = @ActorUserId, GradedAtUtc = SYSUTCDATETIME()
        WHERE AttemptQuestionId = @AttemptQuestionId;

        /* Si ya no queda nada pendiente, cerrar el intento. */
        IF NOT EXISTS (
            SELECT 1 FROM asmt.QuizAttemptQuestion aq
            LEFT JOIN asmt.QuizAttemptAnswer ans ON ans.AttemptQuestionId = aq.AttemptQuestionId
            WHERE aq.QuizAttemptId = @QuizAttemptId AND ans.PointsEarned IS NULL)
        BEGIN
            DECLARE @Earned DECIMAL(9,2), @Possible DECIMAL(9,2), @Percent DECIMAL(5,2)
                  , @PassingScore DECIMAL(5,2), @EnrollmentId INT, @ModuleItemId INT, @EmployeeId INT;

            SELECT  @Earned = ISNULL(SUM(ans.PointsEarned), 0)
                  , @Possible = ISNULL(SUM(aq.PointsPossible), 0)
            FROM asmt.QuizAttemptQuestion aq
            LEFT JOIN asmt.QuizAttemptAnswer ans ON ans.AttemptQuestionId = aq.AttemptQuestionId
            WHERE aq.QuizAttemptId = @QuizAttemptId;

            SET @Percent = CAST(100.0 * @Earned / NULLIF(@Possible, 0) AS DECIMAL(5,2));

            SELECT @PassingScore = q.PassingScore, @EnrollmentId = a.EnrollmentId
                 , @ModuleItemId = a.ModuleItemId, @EmployeeId = a.EmployeeId
            FROM asmt.QuizAttempt a JOIN asmt.Quiz q ON q.QuizId = a.QuizId
            WHERE a.QuizAttemptId = @QuizAttemptId;

            UPDATE asmt.QuizAttempt
            SET [Status] = 3, PointsEarned = @Earned, PointsPossible = @Possible
              , ScorePercent = @Percent
              , IsPassed = CASE WHEN @Percent >= @PassingScore THEN 1 ELSE 0 END
              , GradedAtUtc = SYSUTCDATETIME(), GradedByUserId = @ActorUserId
            WHERE QuizAttemptId = @QuizAttemptId;

            IF @EnrollmentId IS NOT NULL
                INSERT INTO dlv.EnrollmentEvidence (EnrollmentId, EvidenceType, EvidenceId, IsPassing, ScorePercent)
                VALUES (@EnrollmentId, 1, @QuizAttemptId
                      , CASE WHEN @Percent >= @PassingScore THEN 1 ELSE 0 END, @Percent);

            COMMIT TRANSACTION;

            IF @EnrollmentId IS NOT NULL AND @ModuleItemId IS NOT NULL AND @Percent >= @PassingScore
                EXEC dlv.usp_Progress_CompleteItem
                      @ActorUserId = @ActorUserId, @EnrollmentId = @EnrollmentId
                    , @ModuleItemId = @ModuleItemId, @ScorePercent = @Percent;
        END
        ELSE
            COMMIT TRANSACTION;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Attempt_GradeManual', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   asmt.usp_Practical_Start / SetCriterionResult / Submit   (GAP-05)

   Flujo real de piso:
     1. El evaluador abre la evaluacion frente a la estacion.
     2. Marca criterio por criterio mientras observa.
     3. Al enviar, el sistema calcula. Un criterio critico fallado
        reprueba toda la evaluacion, sin importar el porcentaje.
     4. Firman evaluador y evaluado. La firma del evaluado importa:
        significa que se le comunico el resultado.
   ===================================================================== */
CREATE OR ALTER PROCEDURE asmt.usp_Practical_Start
      @ActorUserId         INT
    , @PracticalTemplateId INT
    , @EmployeeId          INT
    , @EnrollmentId        INT = NULL
    , @StationId           INT = NULL
    , @PracticalAssessmentId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50410 evaluador no calificado
                50411 el evaluador no puede evaluarse a si mismo
                50412 plantilla inactiva                                 */
    BEGIN TRY
        DECLARE @EvaluatorEmployeeId INT, @CompetencyId INT, @MinLevelId INT, @Attempt TINYINT;

        SELECT @EvaluatorEmployeeId = EmployeeId FROM sec.[User] WHERE UserId = @ActorUserId;

        IF @EvaluatorEmployeeId = @EmployeeId
            THROW 50411, 'Un evaluador no puede evaluarse a si mismo.', 1;

        SELECT @CompetencyId = CompetencyId, @MinLevelId = MinimumEvaluatorLevelId
        FROM asmt.PracticalAssessmentTemplate
        WHERE PracticalTemplateId = @PracticalTemplateId AND IsActive = 1 AND IsDeleted = 0;

        IF @CompetencyId IS NULL AND NOT EXISTS (SELECT 1 FROM asmt.PracticalAssessmentTemplate
                                                 WHERE PracticalTemplateId = @PracticalTemplateId AND IsActive = 1)
            THROW 50412, 'La plantilla de evaluacion practica no existe o esta inactiva.', 1;

        /* El evaluador tiene que estar calificado. Sin esto, la evidencia
           no vale nada frente a un auditor. */
        IF @CompetencyId IS NOT NULL
           AND NOT EXISTS (
            SELECT 1 FROM comp.EvaluatorQualification eq
            WHERE eq.EmployeeId = @EvaluatorEmployeeId
              AND eq.CompetencyId = @CompetencyId
              AND eq.IsActive = 1 AND eq.CanEvaluate = 1
              AND eq.RevokedAtUtc IS NULL
              AND (eq.ExpiresAtUtc IS NULL OR eq.ExpiresAtUtc > SYSUTCDATETIME()))
            THROW 50410, 'El evaluador no tiene calificacion vigente para evaluar esta competencia.', 1;

        SELECT @Attempt = ISNULL(MAX(AttemptNumber), 0) + 1
        FROM asmt.PracticalAssessment
        WHERE PracticalTemplateId = @PracticalTemplateId AND EmployeeId = @EmployeeId;

        BEGIN TRANSACTION;

        INSERT INTO asmt.PracticalAssessment (PracticalTemplateId, EnrollmentId, EmployeeId
                                            , EvaluatorUserId, StationId, AttemptNumber, [Status])
        VALUES (@PracticalTemplateId, @EnrollmentId, @EmployeeId
              , @ActorUserId, @StationId, @Attempt, 1);

        SET @PracticalAssessmentId = SCOPE_IDENTITY();

        /* Snapshot de criterios al abrir: si Calidad edita la plantilla
           manana, esta evaluacion conserva lo que se observo hoy. */
        INSERT INTO asmt.PracticalCriterionResult (PracticalAssessmentId, PracticalCriterionId
                                                 , CriterionTextSnapshot, IsCriticalSnapshot, ResultCode)
        SELECT @PracticalAssessmentId, c.PracticalCriterionId, c.DescriptionEs, c.IsCritical, 3
        FROM asmt.PracticalCriterion c
        WHERE c.PracticalTemplateId = @PracticalTemplateId AND c.IsDeleted = 0
        ORDER BY c.SortOrder;

        COMMIT TRANSACTION;

        SELECT r.PracticalCriterionResultId, r.PracticalCriterionId, r.CriterionTextSnapshot
             , r.IsCriticalSnapshot, r.ResultCode, c.SortOrder, c.RequiresPhoto, c.ReferenceDocumentCode
        FROM asmt.PracticalCriterionResult r
        JOIN asmt.PracticalCriterion c ON c.PracticalCriterionId = r.PracticalCriterionId
        WHERE r.PracticalAssessmentId = @PracticalAssessmentId
        ORDER BY c.SortOrder;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Practical_Start', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Practical_SetCriterionResult
      @ActorUserId           INT
    , @PracticalAssessmentId INT
    , @Results               asmt.CriterionResultType READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF EXISTS (SELECT 1 FROM asmt.PracticalAssessment
                   WHERE PracticalAssessmentId = @PracticalAssessmentId AND [Status] <> 1)
            THROW 50413, 'La evaluacion practica ya fue enviada y no admite cambios.', 1;

        UPDATE r
        SET r.ResultCode = src.ResultCode
          , r.Comments = src.Comments
          , r.RecordedAtUtc = SYSUTCDATETIME()
        FROM asmt.PracticalCriterionResult r
        JOIN @Results src ON src.PracticalCriterionId = r.PracticalCriterionId
        WHERE r.PracticalAssessmentId = @PracticalAssessmentId;

        SELECT @@ROWCOUNT AS CriteriaUpdated;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Practical_SetCriterionResult', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Practical_Submit
      @ActorUserId           INT
    , @PracticalAssessmentId INT
    , @RepetitionsObserved   TINYINT       = NULL
    , @RepetitionsPassed     TINYINT       = NULL
    , @EvaluatorComments     NVARCHAR(MAX) = NULL
    , @EmployeeComments      NVARCHAR(MAX) = NULL
    , @EvaluatorAuthMethod   TINYINT       = 1
    , @EmployeeUserId        INT           = NULL   -- firma del evaluado en el kiosko
    , @EmployeeAuthMethod    TINYINT       = 2
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50413 ya enviada
                50414 quedan criterios sin evaluar
                50415 falta la firma del evaluado (RequiresDualSignature) */
    BEGIN TRY
        DECLARE @TemplateId INT, @EmployeeId INT, @EnrollmentId INT, @Status TINYINT
              , @PassingScore DECIMAL(5,2), @RequiredReps TINYINT, @RequiresDual BIT
              , @EvaluatorUserId INT, @NowUtc DATETIME2(3) = SYSUTCDATETIME();

        SELECT @TemplateId = a.PracticalTemplateId, @EmployeeId = a.EmployeeId
             , @EnrollmentId = a.EnrollmentId, @Status = a.[Status], @EvaluatorUserId = a.EvaluatorUserId
             , @PassingScore = t.PassingScore, @RequiredReps = t.RequiredRepetitions
             , @RequiresDual = t.RequiresDualSignature
        FROM asmt.PracticalAssessment a
        JOIN asmt.PracticalAssessmentTemplate t ON t.PracticalTemplateId = a.PracticalTemplateId
        WHERE a.PracticalAssessmentId = @PracticalAssessmentId;

        IF @TemplateId IS NULL THROW 50001, 'Evaluacion practica no encontrada.', 1;
        IF @Status <> 1 THROW 50413, 'La evaluacion practica ya fue enviada.', 1;

        IF EXISTS (SELECT 1 FROM asmt.PracticalCriterionResult
                   WHERE PracticalAssessmentId = @PracticalAssessmentId AND ResultCode = 3)
            THROW 50414, 'Quedan criterios sin evaluar. Marque Cumple o No cumple en todos.', 1;

        IF @RequiresDual = 1 AND @EmployeeUserId IS NULL
            THROW 50415, 'Esta evaluacion requiere la firma del empleado evaluado.', 1;

        /* --- Calculo --------------------------------------------------
           Puntaje ponderado por Weight sobre los criterios aplicables.
           Regla dura: un solo criterio critico fallado = reprobado. */
        DECLARE @WeightTotal DECIMAL(18,4), @WeightPassed DECIMAL(18,4)
              , @CriticalFails TINYINT, @Percent DECIMAL(5,2), @IsPassed BIT;

        SELECT  @WeightTotal   = ISNULL(SUM(c.Weight), 0)
              , @WeightPassed  = ISNULL(SUM(CASE WHEN r.ResultCode = 1 THEN c.Weight ELSE 0 END), 0)
              , @CriticalFails = ISNULL(SUM(CASE WHEN r.ResultCode = 2 AND r.IsCriticalSnapshot = 1 THEN 1 ELSE 0 END), 0)
        FROM asmt.PracticalCriterionResult r
        JOIN asmt.PracticalCriterion c ON c.PracticalCriterionId = r.PracticalCriterionId
        WHERE r.PracticalAssessmentId = @PracticalAssessmentId AND r.ResultCode IN (1,2);

        SET @Percent = CAST(100.0 * @WeightPassed / NULLIF(@WeightTotal, 0) AS DECIMAL(5,2));

        SET @RepetitionsObserved = ISNULL(@RepetitionsObserved, @RequiredReps);
        SET @RepetitionsPassed   = ISNULL(@RepetitionsPassed, @RepetitionsObserved);

        SET @IsPassed = CASE
            WHEN @CriticalFails > 0 THEN 0
            WHEN @Percent < @PassingScore THEN 0
            WHEN @RepetitionsPassed < @RequiredReps THEN 0
            ELSE 1 END;

        BEGIN TRANSACTION;

        UPDATE asmt.PracticalAssessment
        SET  [Status] = CASE WHEN @IsPassed = 1 THEN 3 ELSE 4 END
           , RepetitionsObserved = @RepetitionsObserved
           , RepetitionsPassed = @RepetitionsPassed
           , ScorePercent = @Percent
           , IsPassed = @IsPassed
           , CriticalFailureCount = @CriticalFails
           , EvaluatorComments = @EvaluatorComments
           , EmployeeComments = @EmployeeComments
           , SubmittedAtUtc = @NowUtc
        WHERE PracticalAssessmentId = @PracticalAssessmentId;

        /* --- Firmas ------------------------------------------------ */
        DECLARE @Payload NVARCHAR(MAX), @EvalSigId BIGINT, @EmpSigId BIGINT;

        SET @Payload = (
            SELECT  PracticalAssessmentId = @PracticalAssessmentId
                  , EmployeeId = @EmployeeId
                  , ScorePercent = @Percent
                  , IsPassed = @IsPassed
                  , CriticalFailureCount = @CriticalFails
                  , SubmittedAtUtc = @NowUtc
                  , Criteria = (SELECT r.PracticalCriterionId, r.ResultCode, r.IsCriticalSnapshot
                                FROM asmt.PracticalCriterionResult r
                                WHERE r.PracticalAssessmentId = @PracticalAssessmentId
                                ORDER BY r.PracticalCriterionId
                                FOR JSON PATH)
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC aud.usp_Signature_Create
              @ActorUserId = @ActorUserId, @SignatureMeaning = N'Evaluated'
            , @EntityType = N'PracticalAssessment', @EntityId = @PracticalAssessmentId
            , @PayloadCanonical = @Payload, @AuthMethod = @EvaluatorAuthMethod
            , @SignatureRecordId = @EvalSigId OUTPUT;

        IF @EmployeeUserId IS NOT NULL
            EXEC aud.usp_Signature_Create
                  @ActorUserId = @EmployeeUserId, @SignatureMeaning = N'Acknowledged'
                , @EntityType = N'PracticalAssessment', @EntityId = @PracticalAssessmentId
                , @PayloadCanonical = @Payload, @AuthMethod = @EmployeeAuthMethod
                , @SignatureRecordId = @EmpSigId OUTPUT;

        UPDATE asmt.PracticalAssessment
        SET EvaluatorSignatureId = @EvalSigId, EmployeeSignatureId = @EmpSigId
        WHERE PracticalAssessmentId = @PracticalAssessmentId;

        IF @EnrollmentId IS NOT NULL
            INSERT INTO dlv.EnrollmentEvidence (EnrollmentId, EvidenceType, EvidenceId, IsPassing, ScorePercent)
            VALUES (@EnrollmentId, 2, @PracticalAssessmentId, @IsPassed, @Percent);

        EXEC aud.usp_Event_Log
              @EventType   = N'PracticalAssessment.Submitted'
            , @EntityType  = N'PracticalAssessment'
            , @EntityId    = @PracticalAssessmentId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Severity    = CASE WHEN @IsPassed = 1 THEN 2 ELSE 3 END
            , @Summary     = N'Evaluacion practica enviada y firmada.';

        COMMIT TRANSACTION;

        /* Aprobar una practica puede cerrar un requisito de competencia. */
        IF @IsPassed = 1
            EXEC comp.usp_Certification_EvaluateAndIssue
                  @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId
                , @TriggerType = 2, @TriggerId = @PracticalAssessmentId;   -- 2=PracticalAssessment

        SELECT @PracticalAssessmentId AS PracticalAssessmentId, @Percent AS ScorePercent
             , @IsPassed AS IsPassed, @CriticalFails AS CriticalFailureCount
             , @EvalSigId AS EvaluatorSignatureId, @EmpSigId AS EmployeeSignatureId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Practical_Submit', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Resto del esquema asmt
   ===================================================================== */

CREATE OR ALTER PROCEDURE asmt.usp_Attempt_Get @ActorUserId INT, @QuizAttemptId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @EmployeeId INT;
    SELECT @EmployeeId = EmployeeId FROM asmt.QuizAttempt WHERE QuizAttemptId = @QuizAttemptId;
    IF @EmployeeId IS NULL THROW 50001, 'Intento no encontrado.', 1;

    IF NOT EXISTS (SELECT 1 FROM sec.[User] WHERE UserId = @ActorUserId AND EmployeeId = @EmployeeId)
       AND sec.fn_UserHasPermission(@ActorUserId, N'assessment.read.all') = 0
        THROW 50002, 'El usuario no tiene permiso para ver este intento.', 1;

    SELECT a.*, q.TitleEs AS QuizTitle, q.PassingScore
    FROM asmt.QuizAttempt a JOIN asmt.Quiz q ON q.QuizId = a.QuizId
    WHERE a.QuizAttemptId = @QuizAttemptId;

    SELECT aq.AttemptQuestionId, aq.QuestionType, aq.QuestionTextSnapshot, aq.PointsPossible
         , aq.PresentedOrder, aq.ReferenceDocumentCode
         , ans.SelectedOptionIds, ans.TextAnswer, ans.NumericAnswer
         , ans.IsCorrect, ans.PointsEarned, ans.GraderComments
    FROM asmt.QuizAttemptQuestion aq
    LEFT JOIN asmt.QuizAttemptAnswer ans ON ans.AttemptQuestionId = aq.AttemptQuestionId
    WHERE aq.QuizAttemptId = @QuizAttemptId ORDER BY aq.PresentedOrder;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Attempt_GetCurrent
      @ActorUserId INT, @QuizId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @EmployeeId INT;
    SELECT @EmployeeId = EmployeeId FROM sec.[User] WHERE UserId = @ActorUserId;

    SELECT TOP (1) a.QuizAttemptId, a.PublicId, a.AttemptNumber, a.StartedAtUtc, a.ExpiresAtUtc
    FROM asmt.QuizAttempt a
    WHERE a.QuizId = @QuizId AND a.EmployeeId = @EmployeeId AND a.[Status] = 1
    ORDER BY a.QuizAttemptId DESC;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Attempt_ListForEnrollment
      @ActorUserId INT, @EnrollmentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.QuizAttemptId, a.QuizId, q.TitleEs AS QuizTitle, a.AttemptNumber, a.[Status]
         , a.ScorePercent, a.IsPassed, a.StartedAtUtc, a.SubmittedAtUtc, a.TimeSpentSeconds
    FROM asmt.QuizAttempt a JOIN asmt.Quiz q ON q.QuizId = a.QuizId
    WHERE a.EnrollmentId = @EnrollmentId ORDER BY a.StartedAtUtc DESC;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Attempt_GetPendingManualGrading
      @ActorUserId INT, @DepartmentId INT = NULL, @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    IF sec.fn_UserHasPermission(@ActorUserId, N'assessment.grade') = 0
        THROW 50002, 'El usuario no tiene permiso para calificar.', 1;

    SELECT a.QuizAttemptId, a.QuizId, q.TitleEs AS QuizTitle
         , e.EmployeeCode, e.FullName, d.[Name] AS DepartmentName
         , a.SubmittedAtUtc
         , (SELECT COUNT(*) FROM asmt.QuizAttemptQuestion aq
            LEFT JOIN asmt.QuizAttemptAnswer ans ON ans.AttemptQuestionId = aq.AttemptQuestionId
            WHERE aq.QuizAttemptId = a.QuizAttemptId AND ans.PointsEarned IS NULL) AS PendingQuestions
    FROM asmt.QuizAttempt a
    JOIN asmt.Quiz q ON q.QuizId = a.QuizId
    JOIN org.Employee e ON e.EmployeeId = a.EmployeeId
    LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
    WHERE a.[Status] = 5 AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
    ORDER BY a.SubmittedAtUtc
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

/* Job: cierra intentos abandonados que pasaron su ExpiresAtUtc. */
CREATE OR ALTER PROCEDURE asmt.usp_Attempt_AbandonExpired
      @ActorUserId INT = NULL, @GraceMinutes INT = 15, @BatchSize INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE TOP (@BatchSize) asmt.QuizAttempt
    SET [Status] = 4, SubmittedAtUtc = SYSUTCDATETIME()
    WHERE [Status] = 1
      AND ExpiresAtUtc IS NOT NULL
      AND DATEADD(MINUTE, @GraceMinutes, ExpiresAtUtc) < SYSUTCDATETIME();
    SELECT @@ROWCOUNT AS AttemptsAbandoned;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Bank_Create
      @ActorUserId INT, @BankCode NVARCHAR(40), @NameEs NVARCHAR(250)
    , @NameEn NVARCHAR(250) = NULL, @CompetencyId INT = NULL
    , @OwnerDepartmentId INT = NULL, @IsShared BIT = 0
    , @QuestionBankId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'question.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO asmt.QuestionBank (BankCode, NameEs, NameEn, CompetencyId, OwnerDepartmentId, IsShared, CreatedByUserId)
    VALUES (@BankCode, @NameEs, @NameEn, @CompetencyId, @OwnerDepartmentId, @IsShared, @ActorUserId);
    SET @QuestionBankId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Question_Create
      @ActorUserId INT, @QuestionBankId INT, @QuestionType TINYINT
    , @TextEs NVARCHAR(MAX), @TextEn NVARCHAR(MAX) = NULL
    , @Points DECIMAL(9,2) = 1, @Difficulty TINYINT = 2
    , @CorrectFeedbackEs NVARCHAR(1000) = NULL, @IncorrectFeedbackEs NVARCHAR(1000) = NULL
    , @ReferenceDocumentCode NVARCHAR(60) = NULL
    , @NumericAnswer DECIMAL(18,4) = NULL, @NumericTolerance DECIMAL(18,4) = NULL
    , @MediaFileAssetId INT = NULL
    , @QuestionId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    /* Errores: 50416 pregunta numerica sin respuesta esperada */
    IF sec.fn_UserHasPermission(@ActorUserId, N'question.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    IF @QuestionType = 7 AND @NumericAnswer IS NULL
        THROW 50416, 'Una pregunta numerica requiere la respuesta esperada.', 1;

    INSERT INTO asmt.Question (QuestionBankId, QuestionType, TextEs, TextEn, Points, Difficulty
                             , CorrectFeedbackEs, IncorrectFeedbackEs, ReferenceDocumentCode
                             , NumericAnswer, NumericTolerance, MediaFileAssetId, CreatedByUserId)
    VALUES (@QuestionBankId, @QuestionType, @TextEs, @TextEn, @Points, @Difficulty
          , @CorrectFeedbackEs, @IncorrectFeedbackEs, @ReferenceDocumentCode
          , @NumericAnswer, @NumericTolerance, @MediaFileAssetId, @ActorUserId);
    SET @QuestionId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Question_Update
      @ActorUserId INT, @QuestionId INT
    , @TextEs NVARCHAR(MAX) = NULL, @TextEn NVARCHAR(MAX) = NULL
    , @Points DECIMAL(9,2) = NULL, @Difficulty TINYINT = NULL
    , @ReferenceDocumentCode NVARCHAR(60) = NULL, @IsActive BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* Editar una pregunta NO afecta intentos pasados: viven del snapshot. */
    IF sec.fn_UserHasPermission(@ActorUserId, N'question.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    UPDATE asmt.Question
    SET TextEs = ISNULL(@TextEs, TextEs), TextEn = ISNULL(@TextEn, TextEn)
      , Points = ISNULL(@Points, Points), Difficulty = ISNULL(@Difficulty, Difficulty)
      , ReferenceDocumentCode = ISNULL(@ReferenceDocumentCode, ReferenceDocumentCode)
      , IsActive = ISNULL(@IsActive, IsActive)
      , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE QuestionId = @QuestionId AND IsDeleted = 0;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Question_List
      @ActorUserId INT, @QuestionBankId INT = NULL, @QuestionType TINYINT = NULL
    , @Difficulty TINYINT = NULL, @SearchText NVARCHAR(200) = NULL
    , @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    SELECT q.QuestionId, q.PublicId, q.QuestionBankId, q.QuestionType, q.TextEs
         , q.Points, q.Difficulty, q.ReferenceDocumentCode, q.IsActive
         , (SELECT COUNT(*) FROM asmt.QuestionOption o WHERE o.QuestionId = q.QuestionId AND o.IsDeleted = 0) AS OptionCount
    FROM asmt.Question q
    WHERE q.IsDeleted = 0
      AND (@QuestionBankId IS NULL OR q.QuestionBankId = @QuestionBankId)
      AND (@QuestionType   IS NULL OR q.QuestionType   = @QuestionType)
      AND (@Difficulty     IS NULL OR q.Difficulty     = @Difficulty)
      AND (@SearchText     IS NULL OR q.TextEs LIKE N'%' + @SearchText + N'%')
    ORDER BY q.QuestionId
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

/* Analisis de item: si una pregunta la falla el 90%, o la pregunta esta
   mal redactada o la WI no explica bien ese punto. Ambas cosas hay que
   arreglarlas. */
CREATE OR ALTER PROCEDURE asmt.usp_Question_GetStatistics
      @ActorUserId INT, @QuestionId INT, @SinceUtc DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @SinceUtc = ISNULL(@SinceUtc, DATEADD(MONTH, -12, SYSUTCDATETIME()));

    SELECT  COUNT(*) AS TimesPresented
          , SUM(CASE WHEN ans.IsCorrect = 1 THEN 1 ELSE 0 END) AS TimesCorrect
          , CAST(100.0 * SUM(CASE WHEN ans.IsCorrect = 1 THEN 1 ELSE 0 END)
                 / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS CorrectRate
          , AVG(CAST(ans.PointsEarned AS DECIMAL(9,2))) AS AvgPointsEarned
    FROM asmt.QuizAttemptQuestion aq
    JOIN asmt.QuizAttempt a ON a.QuizAttemptId = aq.QuizAttemptId
    LEFT JOIN asmt.QuizAttemptAnswer ans ON ans.AttemptQuestionId = aq.AttemptQuestionId
    WHERE aq.QuestionId = @QuestionId AND a.SubmittedAtUtc >= @SinceUtc;

    /* Distribucion de opciones elegidas: revela distractores rotos. */
    SELECT o.OptionTextSnapshot, o.IsCorrectSnapshot, COUNT(*) AS TimesSelected
    FROM asmt.QuizAttemptQuestion aq
    JOIN asmt.QuizAttempt a ON a.QuizAttemptId = aq.QuizAttemptId
    JOIN asmt.QuizAttemptAnswer ans ON ans.AttemptQuestionId = aq.AttemptQuestionId
    JOIN asmt.QuizAttemptOption o ON o.AttemptQuestionId = aq.AttemptQuestionId
                                 AND o.AttemptOptionId = TRY_CONVERT(INT, ans.SelectedOptionIds)
    WHERE aq.QuestionId = @QuestionId AND a.SubmittedAtUtc >= @SinceUtc
    GROUP BY o.OptionTextSnapshot, o.IsCorrectSnapshot
    ORDER BY TimesSelected DESC;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Question_ImportBulk
      @ActorUserId INT, @QuestionBankId INT, @QuestionsJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Import desde Excel/CSV convertido a JSON por la API. */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'question.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF ISJSON(@QuestionsJson) <> 1 THROW 50417, 'El payload de importacion no es JSON valido.', 1;

        BEGIN TRANSACTION;
        DECLARE @Imported TABLE (QuestionId INT, RowIndex INT);

        INSERT INTO asmt.Question (QuestionBankId, QuestionType, TextEs, TextEn, Points, Difficulty
                                 , ReferenceDocumentCode, NumericAnswer, NumericTolerance, CreatedByUserId)
        OUTPUT inserted.QuestionId, 0 INTO @Imported (QuestionId, RowIndex)
        SELECT @QuestionBankId, j.QuestionType, j.TextEs, j.TextEn
             , ISNULL(j.Points, 1), ISNULL(j.Difficulty, 2)
             , j.ReferenceDocumentCode, j.NumericAnswer, j.NumericTolerance, @ActorUserId
        FROM OPENJSON(@QuestionsJson) WITH (
              QuestionType TINYINT        N'$.questionType'
            , TextEs       NVARCHAR(MAX)  N'$.textEs'
            , TextEn       NVARCHAR(MAX)  N'$.textEn'
            , Points       DECIMAL(9,2)   N'$.points'
            , Difficulty   TINYINT        N'$.difficulty'
            , ReferenceDocumentCode NVARCHAR(60) N'$.referenceDocumentCode'
            , NumericAnswer DECIMAL(18,4) N'$.numericAnswer'
            , NumericTolerance DECIMAL(18,4) N'$.numericTolerance'
        ) j;

        COMMIT TRANSACTION;
        SELECT COUNT(*) AS QuestionsImported FROM @Imported;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Question_ImportBulk', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Quiz_Create
      @ActorUserId INT, @CourseVersionId INT = NULL, @TitleEs NVARCHAR(250)
    , @TitleEn NVARCHAR(250) = NULL, @QuizType TINYINT = 1
    , @PassingScore DECIMAL(5,2) = 80.00, @MaxAttempts TINYINT = 3
    , @TimeLimitMinutes INT = NULL, @ShuffleQuestions BIT = 1, @ShuffleOptions BIT = 1
    , @QuizId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'quiz.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO asmt.Quiz (CourseVersionId, TitleEs, TitleEn, QuizType, PassingScore, MaxAttempts
                         , TimeLimitMinutes, ShuffleQuestions, ShuffleOptions, CreatedByUserId)
    VALUES (@CourseVersionId, @TitleEs, @TitleEn, @QuizType, @PassingScore, @MaxAttempts
          , @TimeLimitMinutes, @ShuffleQuestions, @ShuffleOptions, @ActorUserId);
    SET @QuizId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Quiz_SetSections
      @ActorUserId INT, @QuizId INT, @SectionsJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Reemplaza la estructura completa de secciones. JSON:
       [{ "titleEs":"...", "sortOrder":1, "selectionMode":2,
          "sources":[{"questionBankId":3,"questionCount":10,"difficultyFilter":null}],
          "questionIds":[12,15] }]                                        */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'quiz.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF ISJSON(@SectionsJson) <> 1 THROW 50417, 'El payload de secciones no es JSON valido.', 1;

        BEGIN TRANSACTION;

        DELETE ss FROM asmt.QuizSectionSource ss
        JOIN asmt.QuizSection s ON s.QuizSectionId = ss.QuizSectionId WHERE s.QuizId = @QuizId;
        DELETE qq FROM asmt.QuizQuestion qq
        JOIN asmt.QuizSection s ON s.QuizSectionId = qq.QuizSectionId WHERE s.QuizId = @QuizId;
        DELETE FROM asmt.QuizSection WHERE QuizId = @QuizId;

        DECLARE @Sections TABLE (Idx INT, TitleEs NVARCHAR(250), SortOrder INT
                               , SelectionMode TINYINT, Sources NVARCHAR(MAX), QuestionIds NVARCHAR(MAX)
                               , NewSectionId INT NULL);

        INSERT INTO @Sections (Idx, TitleEs, SortOrder, SelectionMode, Sources, QuestionIds)
        SELECT [key], TitleEs, SortOrder, SelectionMode, Sources, QuestionIds
        FROM OPENJSON(@SectionsJson)
        CROSS APPLY OPENJSON([value]) WITH (
              TitleEs       NVARCHAR(250) N'$.titleEs'
            , SortOrder     INT           N'$.sortOrder'
            , SelectionMode TINYINT       N'$.selectionMode'
            , Sources       NVARCHAR(MAX) N'$.sources' AS JSON
            , QuestionIds   NVARCHAR(MAX) N'$.questionIds' AS JSON
        );

        DECLARE @Idx INT, @NewId INT;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT Idx FROM @Sections ORDER BY Idx;
        OPEN cur; FETCH NEXT FROM cur INTO @Idx;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            INSERT INTO asmt.QuizSection (QuizId, TitleEs, SortOrder, SelectionMode)
            SELECT @QuizId, TitleEs, ISNULL(SortOrder, Idx), ISNULL(SelectionMode, 1)
            FROM @Sections WHERE Idx = @Idx;
            SET @NewId = SCOPE_IDENTITY();

            INSERT INTO asmt.QuizSectionSource (QuizSectionId, QuestionBankId, QuestionCount, DifficultyFilter, PointsPerQuestion)
            SELECT @NewId, j.QuestionBankId, j.QuestionCount, j.DifficultyFilter, j.PointsPerQuestion
            FROM @Sections s
            CROSS APPLY OPENJSON(s.Sources) WITH (
                  QuestionBankId INT          N'$.questionBankId'
                , QuestionCount  INT          N'$.questionCount'
                , DifficultyFilter TINYINT    N'$.difficultyFilter'
                , PointsPerQuestion DECIMAL(9,2) N'$.pointsPerQuestion') j
            WHERE s.Idx = @Idx AND s.Sources IS NOT NULL;

            INSERT INTO asmt.QuizQuestion (QuizSectionId, QuestionId, SortOrder)
            SELECT @NewId, TRY_CONVERT(INT, q.[value]), ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
            FROM @Sections s CROSS APPLY OPENJSON(s.QuestionIds) q
            WHERE s.Idx = @Idx AND s.QuestionIds IS NOT NULL;

            FETCH NEXT FROM cur INTO @Idx;
        END;
        CLOSE cur; DEALLOCATE cur;

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Quiz_SetSections', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* Pre-vuelo antes de publicar: detecta quizzes que van a explotar en
   produccion (banco insuficiente, preguntas sin correcta, etc). */
CREATE OR ALTER PROCEDURE asmt.usp_Quiz_Validate @ActorUserId INT, @QuizId INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Issues TABLE (Severity NVARCHAR(10), Code NVARCHAR(40), [Message] NVARCHAR(400));

    IF NOT EXISTS (SELECT 1 FROM asmt.QuizSection WHERE QuizId = @QuizId)
        INSERT INTO @Issues VALUES (N'Error', N'NO_SECTIONS', N'El quiz no tiene secciones configuradas.');

    INSERT INTO @Issues
    SELECT N'Error', N'BANK_INSUFFICIENT'
         , N'La seccion pide mas preguntas de las que tiene el banco activo.'
    FROM asmt.QuizSection s
    JOIN asmt.QuizSectionSource ss ON ss.QuizSectionId = s.QuizSectionId
    WHERE s.QuizId = @QuizId
      AND ss.QuestionCount > (SELECT COUNT(*) FROM asmt.Question q
                              WHERE q.QuestionBankId = ss.QuestionBankId AND q.IsActive = 1 AND q.IsDeleted = 0
                                AND (ss.DifficultyFilter IS NULL OR q.Difficulty = ss.DifficultyFilter));

    INSERT INTO @Issues
    SELECT N'Error', N'NO_CORRECT_OPTION'
         , N'Pregunta de seleccion sin ninguna opcion marcada como correcta: ' + CAST(q.QuestionId AS NVARCHAR(10))
    FROM asmt.QuizQuestion qq
    JOIN asmt.QuizSection s ON s.QuizSectionId = qq.QuizSectionId AND s.QuizId = @QuizId
    JOIN asmt.Question q ON q.QuestionId = qq.QuestionId
    WHERE q.QuestionType IN (1,2,3,9)
      AND NOT EXISTS (SELECT 1 FROM asmt.QuestionOption o
                      WHERE o.QuestionId = q.QuestionId AND o.IsCorrect = 1 AND o.IsDeleted = 0);

    INSERT INTO @Issues
    SELECT N'Warning', N'NO_REFERENCE'
         , N'Pregunta sin referencia a documento controlado: ' + CAST(q.QuestionId AS NVARCHAR(10))
    FROM asmt.QuizQuestion qq
    JOIN asmt.QuizSection s ON s.QuizSectionId = qq.QuizSectionId AND s.QuizId = @QuizId
    JOIN asmt.Question q ON q.QuestionId = qq.QuestionId
    WHERE q.ReferenceDocumentCode IS NULL;

    SELECT * FROM @Issues;
    SELECT CASE WHEN EXISTS (SELECT 1 FROM @Issues WHERE Severity = N'Error')
                THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS IsValid;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Quiz_Duplicate
      @ActorUserId INT, @QuizId INT, @NewTitleEs NVARCHAR(250)
    , @CourseVersionId INT = NULL, @NewQuizId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'quiz.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        BEGIN TRANSACTION;
        INSERT INTO asmt.Quiz (CourseVersionId, TitleEs, TitleEn, InstructionsEs, InstructionsEn
                             , QuizType, PassingScore, MaxAttempts, ScorePolicy, TimeLimitMinutes
                             , ShuffleQuestions, ShuffleOptions, OneQuestionAtATime, AllowBacktrack
                             , ShowCorrectAnswers, ShowScoreImmediately, CreatedByUserId)
        SELECT ISNULL(@CourseVersionId, CourseVersionId), @NewTitleEs, TitleEn, InstructionsEs, InstructionsEn
             , QuizType, PassingScore, MaxAttempts, ScorePolicy, TimeLimitMinutes
             , ShuffleQuestions, ShuffleOptions, OneQuestionAtATime, AllowBacktrack
             , ShowCorrectAnswers, ShowScoreImmediately, @ActorUserId
        FROM asmt.Quiz WHERE QuizId = @QuizId;
        SET @NewQuizId = SCOPE_IDENTITY();

        DECLARE @SecMap TABLE (OldId INT PRIMARY KEY, NewId INT);
        MERGE asmt.QuizSection AS tgt
        USING (SELECT QuizSectionId, TitleEs, TitleEn, SortOrder, SelectionMode
               FROM asmt.QuizSection WHERE QuizId = @QuizId) AS src
        ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (QuizId, TitleEs, TitleEn, SortOrder, SelectionMode)
            VALUES (@NewQuizId, src.TitleEs, src.TitleEn, src.SortOrder, src.SelectionMode)
        OUTPUT src.QuizSectionId, inserted.QuizSectionId INTO @SecMap (OldId, NewId);

        INSERT INTO asmt.QuizSectionSource (QuizSectionId, QuestionBankId, QuestionCount, DifficultyFilter, PointsPerQuestion)
        SELECT m.NewId, ss.QuestionBankId, ss.QuestionCount, ss.DifficultyFilter, ss.PointsPerQuestion
        FROM asmt.QuizSectionSource ss JOIN @SecMap m ON m.OldId = ss.QuizSectionId;

        INSERT INTO asmt.QuizQuestion (QuizSectionId, QuestionId, SortOrder, PointsOverride)
        SELECT m.NewId, qq.QuestionId, qq.SortOrder, qq.PointsOverride
        FROM asmt.QuizQuestion qq JOIN @SecMap m ON m.OldId = qq.QuizSectionId;

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_Quiz_Duplicate', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Rubric_Create
      @ActorUserId INT, @RubricCode NVARCHAR(40), @NameEs NVARCHAR(250)
    , @NameEn NVARCHAR(250) = NULL, @RubricId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'rubric.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO asmt.Rubric (RubricCode, NameEs, NameEn, CreatedByUserId)
    VALUES (@RubricCode, @NameEs, @NameEn, @ActorUserId);
    SET @RubricId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_RubricAssessment_Submit
      @ActorUserId INT, @RubricId INT, @EmployeeId INT
    , @EnrollmentId INT = NULL, @QuizAttemptId INT = NULL
    , @RatingsJson NVARCHAR(MAX), @Comments NVARCHAR(MAX) = NULL
    , @RubricAssessmentId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* RatingsJson: [{"rubricCriterionId":1,"rubricLevelId":3,"points":4,"comments":"..."}] */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'assessment.grade') = 0
            THROW 50002, 'El usuario no tiene permiso para calificar.', 1;
        IF ISJSON(@RatingsJson) <> 1 THROW 50417, 'El payload de calificaciones no es JSON valido.', 1;

        BEGIN TRANSACTION;
        INSERT INTO asmt.RubricAssessment (RubricId, EnrollmentId, QuizAttemptId, EmployeeId
                                         , AssessorUserId, Comments)
        VALUES (@RubricId, @EnrollmentId, @QuizAttemptId, @EmployeeId, @ActorUserId, @Comments);
        SET @RubricAssessmentId = SCOPE_IDENTITY();

        INSERT INTO asmt.RubricRating (RubricAssessmentId, RubricCriterionId, RubricLevelId, Points, Comments)
        SELECT @RubricAssessmentId, j.RubricCriterionId, j.RubricLevelId, j.Points, j.Comments
        FROM OPENJSON(@RatingsJson) WITH (
              RubricCriterionId INT           N'$.rubricCriterionId'
            , RubricLevelId     INT           N'$.rubricLevelId'
            , Points            DECIMAL(9,2)  N'$.points'
            , Comments          NVARCHAR(1000) N'$.comments') j;

        DECLARE @Total DECIMAL(9,2), @Max DECIMAL(9,2);
        SELECT @Total = SUM(Points) FROM asmt.RubricRating WHERE RubricAssessmentId = @RubricAssessmentId;
        SELECT @Max = SUM(MaxPoints) FROM asmt.RubricCriterion WHERE RubricId = @RubricId;

        UPDATE asmt.RubricAssessment
        SET TotalPoints = @Total
          , ScorePercent = CAST(100.0 * @Total / NULLIF(@Max, 0) AS DECIMAL(5,2))
        WHERE RubricAssessmentId = @RubricAssessmentId;

        IF @EnrollmentId IS NOT NULL
            INSERT INTO dlv.EnrollmentEvidence (EnrollmentId, EvidenceType, EvidenceId, IsPassing, ScorePercent)
            VALUES (@EnrollmentId, 5, @RubricAssessmentId, 1
                  , CAST(100.0 * @Total / NULLIF(@Max, 0) AS DECIMAL(5,2)));

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'asmt.usp_RubricAssessment_Submit', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_PracticalTemplate_Create
      @ActorUserId INT, @TemplateCode NVARCHAR(40), @NameEs NVARCHAR(250)
    , @NameEn NVARCHAR(250) = NULL, @CompetencyId INT = NULL, @StationId INT = NULL
    , @RequiredRepetitions TINYINT = 1, @PassingScore DECIMAL(5,2) = 100.00
    , @MinimumEvaluatorLevelId INT = NULL, @RequiresDualSignature BIT = 1
    , @InstructionsEs NVARCHAR(MAX) = NULL
    , @PracticalTemplateId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'practical.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO asmt.PracticalAssessmentTemplate (TemplateCode, NameEs, NameEn, CompetencyId, StationId
                                                , RequiredRepetitions, PassingScore, MinimumEvaluatorLevelId
                                                , RequiresDualSignature, InstructionsEs, CreatedByUserId)
    VALUES (@TemplateCode, @NameEs, @NameEn, @CompetencyId, @StationId
          , @RequiredRepetitions, @PassingScore, @MinimumEvaluatorLevelId
          , @RequiresDualSignature, @InstructionsEs, @ActorUserId);
    SET @PracticalTemplateId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Practical_Get @ActorUserId INT, @PracticalAssessmentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT a.*, t.TemplateCode, t.NameEs AS TemplateName, t.RequiredRepetitions, t.PassingScore
         , e.EmployeeCode, e.FullName AS EmployeeName
         , ev.DisplayName AS EvaluatorName
         , s.StationCode, s.[Name] AS StationName
    FROM asmt.PracticalAssessment a
    JOIN asmt.PracticalAssessmentTemplate t ON t.PracticalTemplateId = a.PracticalTemplateId
    JOIN org.Employee e ON e.EmployeeId = a.EmployeeId
    JOIN sec.[User] ev ON ev.UserId = a.EvaluatorUserId
    LEFT JOIN org.Station s ON s.StationId = a.StationId
    WHERE a.PracticalAssessmentId = @PracticalAssessmentId;

    SELECT r.PracticalCriterionResultId, r.PracticalCriterionId, r.CriterionTextSnapshot
         , r.IsCriticalSnapshot, r.ResultCode, r.Comments, c.SortOrder, c.Weight, c.ReferenceDocumentCode
    FROM asmt.PracticalCriterionResult r
    JOIN asmt.PracticalCriterion c ON c.PracticalCriterionId = r.PracticalCriterionId
    WHERE r.PracticalAssessmentId = @PracticalAssessmentId ORDER BY c.SortOrder;

    SELECT at.AttachmentId, at.PracticalCriterionId, at.FileAssetId, at.[Description], at.UploadedAtUtc
    FROM asmt.PracticalAssessmentAttachment at
    WHERE at.PracticalAssessmentId = @PracticalAssessmentId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE asmt.usp_Practical_AddAttachment
      @ActorUserId INT, @PracticalAssessmentId INT, @FileAssetId INT
    , @PracticalCriterionId INT = NULL, @Description NVARCHAR(400) = NULL
    , @AttachmentId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    /* Fotos de evidencia del proceso ejecutado. Vale mas que el comentario. */
    INSERT INTO asmt.PracticalAssessmentAttachment (PracticalAssessmentId, PracticalCriterionId
                                                  , FileAssetId, [Description], UploadedByUserId)
    VALUES (@PracticalAssessmentId, @PracticalCriterionId, @FileAssetId, @Description, @ActorUserId);
    SET @AttachmentId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

PRINT '=== 14_procs_assessment.sql completado ===';
GO
