/* =====================================================================
   Classroom - LMS by Airlink
   15_procs_compliance.sql
   Esquema: comp (competencias, requisitos, certificaciones, documentos
            controlados, brechas, waivers, gating)

   ESTE ES EL ARCHIVO QUE JUSTIFICA EL PROYECTO.

   Canvas y cualquier LMS del mercado hacen cursos. Lo que no hacen, y
   por lo que Airlink construye en vez de comprar, es esto:

     - Un requisito de competencia obliga; un curso solo lo satisface.
       Separar ambos permite que una evaluacion practica, una firma de
       documento o una credencial externa cierren el mismo requisito.
     - Publicar WI-IP68-RXR-001 Rev.2 invalida las certificaciones que
       se apoyaban en Rev.1 y genera re-entrenamiento automatico.
     - Una certificacion vence, avisa antes de vencer, y su vencimiento
       bloquea la estacion.

   Codigos de error de este archivo: 50500-50599
   ===================================================================== */

USE AIRLINK_LMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 15_procs_compliance.sql iniciado ===';
GO

/* =====================================================================
   comp.usp_Certification_EvaluateAndIssue

   EL PROCEDIMIENTO MAS IMPORTANTE DEL SISTEMA.

   Se dispara cada vez que aparece evidencia nueva (curso completado,
   practica aprobada, sesion asistida, documento firmado). Para cada
   requisito vigente del empleado revisa si TODOS los satisfactores
   mandatorios estan cumplidos y, si si, emite la certificacion.

   Reglas que hay que respetar y que la gente suele romper:
     1. La vigencia se cuenta desde la ULTIMA pieza de evidencia, no
        desde la fecha de emision. Si el operador termino el curso el 3
        y el sistema emite el 10, la certificacion vence contando del 3.
     2. Los grupos alternativos (AlternativeGroup) se satisfacen con
        CUALQUIERA de sus miembros.
     3. Recertificar no borra: la certificacion anterior queda apuntando
        a la nueva por SupersededByCertificationId.
     4. Todo se firma. Emision automatica = firma del sistema con el
        actor que disparo el evento.
   ===================================================================== */
CREATE OR ALTER PROCEDURE comp.usp_Certification_EvaluateAndIssue
      @ActorUserId   INT
    , @EmployeeId    INT
    , @TriggerType   TINYINT = NULL   -- 1=Enrollment 2=Practical 3=Session 4=DocAck 5=Manual 6=Job
    , @TriggerId     INT     = NULL
    , @RequirementId INT     = NULL   -- NULL = evaluar todos los requisitos del empleado
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------
       Proposito : evaluar requisitos y emitir certificaciones cumplidas.
       Retorna   : resultset con las certificaciones emitidas.
       Errores   : 50501 empleado no encontrado
       --------------------------------------------------------------- */

    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM org.Employee WHERE EmployeeId = @EmployeeId)
            THROW 50501, 'Empleado no encontrado.', 1;

        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME()
              , @EmployeeName NVARCHAR(250)
              , @PositionName NVARCHAR(150);

        SELECT  @EmployeeName = e.FullName
              , @PositionName = p.[Name]
        FROM org.Employee e
        LEFT JOIN org.[Position] p ON p.PositionId = e.PrimaryPositionId
        WHERE e.EmployeeId = @EmployeeId;

        /* --- 1. Requisitos aplicables ------------------------------ */
        DECLARE @Requirements TABLE (
              RequirementId        INT PRIMARY KEY
            , CompetencyId         INT NOT NULL
            , MinimumLevelId       INT NOT NULL
            , RequiredLevelOrdinal TINYINT NOT NULL
            , ValidityMonths       INT NULL
            , Criticality          TINYINT NOT NULL
        );

        INSERT INTO @Requirements
        SELECT RequirementId, CompetencyId, MinimumLevelId, RequiredLevelOrdinal
             , ValidityMonths, Criticality
        FROM comp.fn_GetEffectiveRequirements(@EmployeeId)
        WHERE (@RequirementId IS NULL OR RequirementId = @RequirementId);

        IF NOT EXISTS (SELECT 1 FROM @Requirements) RETURN 0;

        /* --- 2. Evidencia disponible del empleado -------------------
           Se arma un mapa (SatisfierType, SatisfierId) -> fecha de
           cumplimiento. Los cuatro tipos que Airlink usa de verdad. */
        DECLARE @Evidence TABLE (
              SatisfierType TINYINT NOT NULL
            , SatisfierId   INT     NOT NULL
            , CompletedAtUtc DATETIME2(3) NOT NULL
            , EvidenceKind  TINYINT NOT NULL   -- para comp.CertificationEvidence
            , EvidenceId    INT     NOT NULL
            , ScorePercent  DECIMAL(5,2) NULL
            , PRIMARY KEY (SatisfierType, SatisfierId, EvidenceId)
        );

        /* Cursos aprobados */
        INSERT INTO @Evidence
        SELECT 1, e.CourseId, MAX(e.CompletedAtUtc), 1, MAX(e.EnrollmentId), MAX(e.ScorePercent)
        FROM dlv.Enrollment e
        WHERE e.EmployeeId = @EmployeeId AND e.[Status] = 3 AND e.IsPassed = 1
          AND e.CompletedAtUtc IS NOT NULL
        GROUP BY e.CourseId;

        /* Programas completos: todos sus cursos requeridos aprobados */
        INSERT INTO @Evidence
        SELECT 2, pc.ProgramId, MAX(ev.CompletedAtUtc), 1, MAX(ev.EvidenceId), NULL
        FROM lms.ProgramCourse pc
        JOIN @Evidence ev ON ev.SatisfierType = 1 AND ev.SatisfierId = pc.CourseId
        WHERE pc.IsRequired = 1
        GROUP BY pc.ProgramId
        HAVING COUNT(*) = (SELECT COUNT(*) FROM lms.ProgramCourse x
                           WHERE x.ProgramId = pc.ProgramId AND x.IsRequired = 1);

        /* Evaluaciones practicas aprobadas */
        INSERT INTO @Evidence
        SELECT 3, pa.PracticalTemplateId, MAX(pa.SubmittedAtUtc), 3, MAX(pa.PracticalAssessmentId), MAX(pa.ScorePercent)
        FROM asmt.PracticalAssessment pa
        WHERE pa.EmployeeId = @EmployeeId AND pa.[Status] = 3 AND pa.IsPassed = 1
          AND pa.SubmittedAtUtc IS NOT NULL
        GROUP BY pa.PracticalTemplateId;

        /* Documentos controlados firmados (revision vigente) */
        INSERT INTO @Evidence
        SELECT 4, dr.ControlledDocumentId, MAX(da.AcknowledgedAtUtc), 5, MAX(da.DocumentAcknowledgmentId), NULL
        FROM comp.DocumentAcknowledgment da
        JOIN comp.ControlledDocumentRevision dr ON dr.DocumentRevisionId = da.DocumentRevisionId
        WHERE da.EmployeeId = @EmployeeId AND da.IsCurrent = 1 AND dr.[Status] = 3
        GROUP BY dr.ControlledDocumentId;

        /* Quizzes aprobados fuera de curso */
        INSERT INTO @Evidence
        SELECT 6, qa.QuizId, MAX(qa.SubmittedAtUtc), 2, MAX(qa.QuizAttemptId), MAX(qa.ScorePercent)
        FROM asmt.QuizAttempt qa
        WHERE qa.EmployeeId = @EmployeeId AND qa.[Status] = 3 AND qa.IsPassed = 1
        GROUP BY qa.QuizId;

        /* --- 3. Requisitos cumplidos -------------------------------
           Un requisito esta cumplido cuando:
             a) todo satisfactor mandatorio SIN grupo alternativo esta
                presente en la evidencia, Y
             b) por cada AlternativeGroup existe AL MENOS uno presente.  */
        DECLARE @Satisfied TABLE (
              RequirementId INT PRIMARY KEY
            , LastEvidenceAtUtc DATETIME2(3) NOT NULL
        );

        INSERT INTO @Satisfied
        SELECT  r.RequirementId
              , MAX(ISNULL(ev.CompletedAtUtc, @NowUtc))
        FROM @Requirements r
        LEFT JOIN comp.RequirementSatisfier rs ON rs.RequirementId = r.RequirementId
        LEFT JOIN @Evidence ev ON ev.SatisfierType = rs.SatisfierType AND ev.SatisfierId = rs.SatisfierId
        GROUP BY r.RequirementId
        HAVING
            /* (a) mandatorios sin grupo: todos presentes */
            SUM(CASE WHEN rs.IsMandatory = 1 AND rs.AlternativeGroup IS NULL
                      AND ev.SatisfierId IS NULL THEN 1 ELSE 0 END) = 0
            /* (b) cada grupo alternativo con al menos uno */
        AND NOT EXISTS (
                SELECT 1
                FROM comp.RequirementSatisfier g
                WHERE g.RequirementId = r.RequirementId AND g.AlternativeGroup IS NOT NULL
                GROUP BY g.AlternativeGroup
                HAVING SUM(CASE WHEN EXISTS (SELECT 1 FROM @Evidence e2
                                             WHERE e2.SatisfierType = g.SatisfierType
                                               AND e2.SatisfierId = g.SatisfierId)
                                THEN 1 ELSE 0 END) = 0)
            /* el requisito debe tener al menos un satisfactor definido */
        AND COUNT(rs.RequirementSatisfierId) > 0;

        IF NOT EXISTS (SELECT 1 FROM @Satisfied) 
        BEGIN
            /* Aun sin emision, se recalculan las brechas: el estado pudo
               cambiar aunque no se haya completado nada. */
            EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;
            RETURN 0;
        END;

        /* --- 4. Emision -------------------------------------------- */
        DECLARE @Issued TABLE (
              CertificationId INT
            , RequirementId   INT
            , CompetencyId    INT
            , CertificateNumber NVARCHAR(40)
            , ExpiresAtUtc    DATETIME2(3));

        DECLARE @ReqId INT, @CompId INT, @LevelId INT, @Validity INT
              , @LastEvidence DATETIME2(3), @ExpiresAtUtc DATETIME2(3)
              , @CertNumber NVARCHAR(40), @CertId INT, @PrevCertId INT
              , @Payload NVARCHAR(MAX), @SigId BIGINT, @Year NVARCHAR(4);

        SET @Year = CAST(YEAR(@NowUtc) AS NVARCHAR(4));

        DECLARE issue CURSOR LOCAL FAST_FORWARD FOR
            SELECT r.RequirementId, r.CompetencyId, r.MinimumLevelId, r.ValidityMonths, s.LastEvidenceAtUtc
            FROM @Satisfied s
            JOIN @Requirements r ON r.RequirementId = s.RequirementId;

        OPEN issue;
        FETCH NEXT FROM issue INTO @ReqId, @CompId, @LevelId, @Validity, @LastEvidence;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @ExpiresAtUtc = CASE WHEN @Validity IS NULL THEN NULL
                                         ELSE DATEADD(MONTH, @Validity, @LastEvidence) END;

                /* Certificacion vigente ya cubre esta evidencia -> saltar.
                   Idempotencia: el job nocturno corre todas las noches. */
                IF EXISTS (
                    SELECT 1 FROM comp.Certification c
                    WHERE c.EmployeeId = @EmployeeId
                      AND c.CompetencyId = @CompId
                      AND c.[Status] IN (1, 2, 6)
                      AND c.EvidenceCompletedAtUtc >= @LastEvidence
                      AND c.RevokedAtUtc IS NULL)
                BEGIN
                    FETCH NEXT FROM issue INTO @ReqId, @CompId, @LevelId, @Validity, @LastEvidence;
                    CONTINUE;
                END;

                BEGIN TRANSACTION;

                /* Numero verificable por QR: CERT-2026-000123 */
                SELECT @CertNumber = N'CERT-' + @Year + N'-'
                     + RIGHT(N'000000' + CAST(ISNULL(MAX(CAST(RIGHT(CertificateNumber, 6) AS INT)), 0) + 1 AS NVARCHAR(6)), 6)
                FROM comp.Certification WITH (UPDLOCK, HOLDLOCK)
                WHERE CertificateNumber LIKE N'CERT-' + @Year + N'-%';

                INSERT INTO comp.Certification (CertificateNumber, EmployeeId, CompetencyId, CompetencyLevelId
                                              , RequirementId, [Status], IssuedAtUtc, EvidenceCompletedAtUtc
                                              , ExpiresAtUtc, IssuedByUserId
                                              , EmployeeNameSnapshot, PositionNameSnapshot)
                VALUES (@CertNumber, @EmployeeId, @CompId, @LevelId
                      , @ReqId, 1, @NowUtc, @LastEvidence
                      , @ExpiresAtUtc, CASE WHEN @TriggerType = 6 THEN NULL ELSE @ActorUserId END
                      , @EmployeeName, @PositionName);

                SET @CertId = SCOPE_IDENTITY();

                /* Trazabilidad de la evidencia que la sustenta. */
                INSERT INTO comp.CertificationEvidence (CertificationId, EvidenceType, EvidenceId
                                                      , EvidenceReference, CompletedAtUtc, ScorePercent)
                SELECT DISTINCT @CertId, ev.EvidenceKind, ev.EvidenceId
                     , CASE rs.SatisfierType
                            WHEN 1 THEN N'Curso #'    + CAST(rs.SatisfierId AS NVARCHAR(10))
                            WHEN 2 THEN N'Programa #' + CAST(rs.SatisfierId AS NVARCHAR(10))
                            WHEN 3 THEN N'Practica #' + CAST(rs.SatisfierId AS NVARCHAR(10))
                            WHEN 4 THEN N'Documento #' + CAST(rs.SatisfierId AS NVARCHAR(10))
                            WHEN 6 THEN N'Quiz #'     + CAST(rs.SatisfierId AS NVARCHAR(10))
                            ELSE rs.ExternalCredentialName END
                     , ev.CompletedAtUtc, ev.ScorePercent
                FROM comp.RequirementSatisfier rs
                JOIN @Evidence ev ON ev.SatisfierType = rs.SatisfierType AND ev.SatisfierId = rs.SatisfierId
                WHERE rs.RequirementId = @ReqId;

                /* Superseder la anterior (recertificacion). */
                SELECT TOP (1) @PrevCertId = c.CertificationId
                FROM comp.Certification c
                WHERE c.EmployeeId = @EmployeeId AND c.CompetencyId = @CompId
                  AND c.CertificationId <> @CertId AND c.SupersededByCertificationId IS NULL
                  AND c.[Status] IN (1,2,3,4,6)
                ORDER BY c.IssuedAtUtc DESC;

                IF @PrevCertId IS NOT NULL
                    UPDATE comp.Certification
                    SET SupersededByCertificationId = @CertId
                    WHERE CertificationId = @PrevCertId;

                /* Firma */
                SET @Payload = (
                    SELECT  CertificateNumber = @CertNumber
                          , EmployeeId = @EmployeeId
                          , EmployeeName = @EmployeeName
                          , CompetencyId = @CompId
                          , CompetencyLevelId = @LevelId
                          , RequirementId = @ReqId
                          , EvidenceCompletedAtUtc = @LastEvidence
                          , ExpiresAtUtc = @ExpiresAtUtc
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

                EXEC aud.usp_Signature_Create
                      @ActorUserId = @ActorUserId, @SignatureMeaning = N'Certified'
                    , @EntityType = N'Certification', @EntityId = @CertId
                    , @PayloadCanonical = @Payload, @AuthMethod = 1
                    , @SignatureRecordId = @SigId OUTPUT;

                UPDATE comp.Certification SET SignatureId = @SigId WHERE CertificationId = @CertId;

                /* Cerrar la brecha */
                UPDATE comp.CompetencyGap
                SET ResolvedAtUtc = @NowUtc, CertificationId = @CertId, LastEvaluatedAtUtc = @NowUtc
                WHERE EmployeeId = @EmployeeId AND RequirementId = @ReqId AND ResolvedAtUtc IS NULL;

                EXEC aud.usp_Event_Log
                      @EventType   = N'Certification.Issued'
                    , @EntityType  = N'Certification'
                    , @EntityId    = @CertId
                    , @EmployeeId  = @EmployeeId
                    , @ActorUserId = @ActorUserId
                    , @Severity    = 2
                    , @Summary     = N'Certificacion emitida: ' + @CertNumber;

                COMMIT TRANSACTION;

                INSERT INTO @Issued VALUES (@CertId, @ReqId, @CompId, @CertNumber, @ExpiresAtUtc);

                EXEC ops.usp_Notification_Enqueue
                      @TemplateCode = N'Certification.Issued'
                    , @RecipientEmployeeId = @EmployeeId
                    , @Priority = 2
                    , @DedupeKey = @CertNumber;
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
                /* Un requisito problematico no detiene los demas. */
                EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Certification_EvaluateAndIssue'
                                     , @ActorUserId = @ActorUserId;
            END CATCH;

            FETCH NEXT FROM issue INTO @ReqId, @CompId, @LevelId, @Validity, @LastEvidence;
        END;
        CLOSE issue; DEALLOCATE issue;

        EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;

        SELECT * FROM @Issued;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Certification_EvaluateAndIssue', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   comp.usp_DocumentRevision_Activate    -- GAP-02

   Activar WI-IP68-RXR-001 Rev.2 hace cuatro cosas de golpe:
     1. marca Rev.1 como Superseded y sus firmas como no vigentes,
     2. invalida (RetrainingRequired) las certificaciones cuyos requisitos
        declaran InvalidateOnRevision = 1 para ese documento,
     3. genera inscripciones de re-entrenamiento con fecha limite,
     4. notifica a los afectados y a sus supervisores.

   Sin esto, una WI cambia y nadie se entera hasta la auditoria. Con
   esto, el sistema se entera solo.
   ===================================================================== */
CREATE OR ALTER PROCEDURE comp.usp_DocumentRevision_Activate
      @ActorUserId       INT
    , @DocumentRevisionId INT
    , @EffectiveAtUtc    DATETIME2(3) = NULL
    , @PayloadCanonical  NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50510 revision no esta aprobada
                50511 aprobaciones incompletas
                50512 revision ya activa                                 */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'document.activate') = 0
            THROW 50002, 'El usuario no tiene permiso para activar revisiones de documentos.', 1;

        DECLARE @DocId INT, @Status TINYINT, @RevNumber INT, @RevLabel NVARCHAR(20)
              , @DocCode NVARCHAR(60), @RequiresReack BIT, @DeadlineDays INT
              , @PreviousRevisionId INT, @NowUtc DATETIME2(3) = SYSUTCDATETIME()
              , @SigId BIGINT, @Affected INT = 0, @Retrained INT = 0;

        SELECT @DocId = dr.ControlledDocumentId, @Status = dr.[Status]
             , @RevNumber = dr.RevisionNumber, @RevLabel = dr.RevisionLabel
             , @RequiresReack = dr.RequiresReacknowledgment
             , @DeadlineDays = dr.ReacknowledgmentDeadlineDays
        FROM comp.ControlledDocumentRevision dr WHERE dr.DocumentRevisionId = @DocumentRevisionId;

        IF @DocId IS NULL THROW 50001, 'Revision de documento no encontrada.', 1;
        IF @Status = 3 THROW 50512, 'La revision ya esta activa.', 1;
        IF @Status <> 2 THROW 50510, 'Solo una revision en aprobacion puede activarse.', 1;

        IF EXISTS (SELECT 1 FROM comp.DocumentApproval
                   WHERE DocumentRevisionId = @DocumentRevisionId AND (Decision IS NULL OR Decision <> 1))
            THROW 50511, 'Faltan aprobaciones de la revision.', 1;

        SET @EffectiveAtUtc = ISNULL(@EffectiveAtUtc, @NowUtc);

        SELECT @DocCode = DocumentCode, @PreviousRevisionId = CurrentRevisionId
        FROM comp.ControlledDocument WHERE ControlledDocumentId = @DocId;

        BEGIN TRANSACTION;

        /* --- 1. Activar y superseder ------------------------------- */
        UPDATE comp.ControlledDocumentRevision
        SET [Status] = 3, EffectiveAtUtc = @EffectiveAtUtc
          , ActivatedAtUtc = @NowUtc, ActivatedByUserId = @ActorUserId
        WHERE DocumentRevisionId = @DocumentRevisionId;

        IF @PreviousRevisionId IS NOT NULL AND @PreviousRevisionId <> @DocumentRevisionId
        BEGIN
            UPDATE comp.ControlledDocumentRevision
            SET [Status] = 4, SupersededAtUtc = @NowUtc, SupersededByRevisionId = @DocumentRevisionId
            WHERE DocumentRevisionId = @PreviousRevisionId;

            /* Las firmas de la revision anterior dejan de ser vigentes.
               No se borran: son evidencia de que en su momento se firmo. */
            UPDATE comp.DocumentAcknowledgment
            SET IsCurrent = 0
            WHERE DocumentRevisionId = @PreviousRevisionId;
        END;

        UPDATE comp.ControlledDocument
        SET CurrentRevisionId = @DocumentRevisionId
          , ModifiedAtUtc = @NowUtc, ModifiedByUserId = @ActorUserId
        WHERE ControlledDocumentId = @DocId;

        /* --- 2. Invalidar certificaciones -------------------------- */
        IF @RequiresReack = 1
        BEGIN
            DECLARE @ToRetrain TABLE (
                  CertificationId INT PRIMARY KEY
                , EmployeeId      INT NOT NULL
                , RequirementId   INT NULL);

            INSERT INTO @ToRetrain
            SELECT DISTINCT c.CertificationId, c.EmployeeId, c.RequirementId
            FROM comp.Certification c
            JOIN comp.RequirementDocument rd ON rd.RequirementId = c.RequirementId
            WHERE rd.ControlledDocumentId = @DocId
              AND rd.InvalidateOnRevision = 1
              AND c.[Status] IN (1, 2, 6)
              AND c.RevokedAtUtc IS NULL;

            UPDATE c
            SET c.[Status] = 4                                   -- RetrainingRequired
            FROM comp.Certification c
            JOIN @ToRetrain t ON t.CertificationId = c.CertificationId;

            SELECT @Affected = COUNT(*) FROM @ToRetrain;
        END;

        /* --- 3. Firma de la activacion ----------------------------- */
        SET @PayloadCanonical = ISNULL(@PayloadCanonical,
            (SELECT  DocumentCode = @DocCode
                   , DocumentRevisionId = @DocumentRevisionId
                   , RevisionLabel = @RevLabel
                   , EffectiveAtUtc = @EffectiveAtUtc
                   , CertificationsInvalidated = @Affected
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER));

        EXEC aud.usp_Signature_Create
              @ActorUserId = @ActorUserId, @SignatureMeaning = N'Approved'
            , @EntityType = N'ControlledDocumentRevision', @EntityId = @DocumentRevisionId
            , @PayloadCanonical = @PayloadCanonical, @AuthMethod = 1
            , @SignatureRecordId = @SigId OUTPUT;

        EXEC aud.usp_Event_Log
              @EventType   = N'DocumentRevision.Activated'
            , @EntityType  = N'ControlledDocumentRevision'
            , @EntityId    = @DocumentRevisionId
            , @ActorUserId = @ActorUserId
            , @Severity    = 4
            , @Summary     = N'Revision activada: ' + @DocCode + N' ' + ISNULL(@RevLabel, N'')
                           + N'. Certificaciones marcadas para re-entrenamiento: ' + CAST(@Affected AS NVARCHAR(10));

        COMMIT TRANSACTION;

        /* --- 4. Re-entrenamiento y avisos --------------------------
           Fuera de la transaccion: puede tocar cientos de empleados y no
           queremos sostener locks sobre el documento mientras tanto. */
        IF @RequiresReack = 1 AND @Affected > 0
        BEGIN
            DECLARE @EmpId INT, @ReqId INT, @NewEnrollmentId INT;
            DECLARE retrain CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT EmployeeId, RequirementId FROM @ToRetrain WHERE RequirementId IS NOT NULL;

            OPEN retrain;
            FETCH NEXT FROM retrain INTO @EmpId, @ReqId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                BEGIN TRY
                    SET @NewEnrollmentId = NULL;
                    EXEC dlv.usp_Enrollment_CreateFromRequirement
                          @ActorUserId = @ActorUserId, @EmployeeId = @EmpId
                        , @RequirementId = @ReqId, @DueInDays = @DeadlineDays
                        , @EnrollmentId = @NewEnrollmentId OUTPUT;

                    IF @NewEnrollmentId IS NOT NULL
                    BEGIN
                        UPDATE dlv.Enrollment SET [Source] = 5   -- DocumentRevisionRetraining
                        WHERE EnrollmentId = @NewEnrollmentId;
                        SET @Retrained = @Retrained + 1;
                    END;

                    EXEC ops.usp_Notification_Enqueue
                          @TemplateCode = N'Document.RetrainingRequired'
                        , @RecipientEmployeeId = @EmpId
                        , @Priority = 1
                        , @NotifySupervisor = 1
                        , @DedupeKey = N'DOCRETRAIN-' + CAST(@DocumentRevisionId AS NVARCHAR(12))
                                     + N'-' + CAST(@EmpId AS NVARCHAR(12));
                END TRY
                BEGIN CATCH
                    EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_DocumentRevision_Activate'
                                         , @ActorUserId = @ActorUserId;
                END CATCH;
                FETCH NEXT FROM retrain INTO @EmpId, @ReqId;
            END;
            CLOSE retrain; DEALLOCATE retrain;
        END;

        SELECT  @DocumentRevisionId AS DocumentRevisionId
              , @DocCode            AS DocumentCode
              , @RevLabel           AS RevisionLabel
              , @Affected           AS CertificationsInvalidated
              , @Retrained          AS RetrainingEnrollmentsCreated
              , @SigId              AS SignatureRecordId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_DocumentRevision_Activate', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   comp.usp_Gap_RecalculateForEmployee

   Recalcula el estado real del empleado contra sus requisitos vigentes.
   Idempotente. Lo llama todo lo que cambia el estado: cambio de puesto,
   emision de certificacion, activacion de documento, y el job nocturno.
   ===================================================================== */
CREATE OR ALTER PROCEDURE comp.usp_Gap_RecalculateForEmployee
      @ActorUserId INT = NULL
    , @EmployeeId  INT
    , @AutoEnroll  BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();

        /* Estado actual por requisito, cruzando con la mejor certificacion
           vigente que tenga el empleado en esa competencia. */
        DECLARE @State TABLE (
              RequirementId        INT PRIMARY KEY
            , CompetencyId         INT NOT NULL
            , RequiredLevelOrdinal TINYINT NOT NULL
            , CurrentLevelOrdinal  TINYINT NULL
            , CertificationId      INT NULL
            , CertStatus           TINYINT NULL
            , ExpiresAtUtc         DATETIME2(3) NULL
            , AlertWindowDays      INT NOT NULL
            , GracePeriodDays      INT NOT NULL
            , Criticality          TINYINT NOT NULL
            , HasWaiver            BIT NOT NULL
        );

        INSERT INTO @State
        SELECT  r.RequirementId
              , r.CompetencyId
              , r.RequiredLevelOrdinal
              , cl.LevelOrdinal
              , c.CertificationId
              , c.[Status]
              , c.ExpiresAtUtc
              , ops.fn_FirstAlertWindowDays(r.AlertWindowDays)
              , r.GracePeriodDays
              , r.Criticality
              , comp.fn_HasActiveWaiver(@EmployeeId, r.RequirementId)
        FROM comp.fn_GetEffectiveRequirements(@EmployeeId) r
        OUTER APPLY (
            SELECT TOP (1) c2.CertificationId, c2.[Status], c2.ExpiresAtUtc, c2.CompetencyLevelId
            FROM comp.Certification c2
            WHERE c2.EmployeeId = @EmployeeId
              AND c2.CompetencyId = r.CompetencyId
              AND c2.RevokedAtUtc IS NULL
            ORDER BY CASE c2.[Status] WHEN 1 THEN 1 WHEN 2 THEN 2 WHEN 6 THEN 3
                                      WHEN 4 THEN 4 WHEN 3 THEN 5 ELSE 6 END
                   , c2.IssuedAtUtc DESC) c
        LEFT JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = c.CompetencyLevelId;

        /* Clasificacion de la brecha. El orden de los CASE importa:
           revocada y vencida pesan mas que "nivel insuficiente". */
        DECLARE @Gaps TABLE (
              RequirementId INT PRIMARY KEY
            , CompetencyId  INT
            , GapType       TINYINT
            , Severity      TINYINT
            , CurrentLevelOrdinal TINYINT NULL
            , RequiredLevelOrdinal TINYINT
            , CertificationId INT NULL
            , ExpiresAtUtc  DATETIME2(3) NULL
            , DaysUntilExpiry INT NULL
            , HasWaiver     BIT
        );

        INSERT INTO @Gaps
        SELECT  s.RequirementId
              , s.CompetencyId
              , CASE
                    WHEN s.CertificationId IS NULL                       THEN 1   -- NeverCertified
                    WHEN s.CertStatus = 5                                THEN 6   -- Revoked
                    WHEN s.CertStatus = 4                                THEN 4   -- RetrainingRequired
                    WHEN s.ExpiresAtUtc IS NOT NULL
                     AND DATEADD(DAY, s.GracePeriodDays, s.ExpiresAtUtc) < @NowUtc THEN 2  -- Expired
                    WHEN s.ExpiresAtUtc IS NOT NULL
                     AND s.ExpiresAtUtc <= DATEADD(DAY, s.AlertWindowDays, @NowUtc) THEN 3 -- ExpiringSoon
                    WHEN ISNULL(s.CurrentLevelOrdinal, 0) < s.RequiredLevelOrdinal THEN 5  -- InsufficientLevel
                    ELSE NULL
                END
              , s.Criticality
              , s.CurrentLevelOrdinal
              , s.RequiredLevelOrdinal
              , s.CertificationId
              , s.ExpiresAtUtc
              , CASE WHEN s.ExpiresAtUtc IS NULL THEN NULL
                     ELSE DATEDIFF(DAY, @NowUtc, s.ExpiresAtUtc) END
              , s.HasWaiver
        FROM @State s;

        DELETE FROM @Gaps WHERE GapType IS NULL;

        BEGIN TRANSACTION;

        /* Upsert de brechas abiertas */
        MERGE comp.CompetencyGap AS tgt
        USING (SELECT * FROM @Gaps) AS src
        ON tgt.EmployeeId = @EmployeeId AND tgt.RequirementId = src.RequirementId
        WHEN MATCHED THEN UPDATE SET
              GapType = src.GapType
            , Severity = src.Severity
            , CurrentLevelOrdinal = src.CurrentLevelOrdinal
            , RequiredLevelOrdinal = src.RequiredLevelOrdinal
            , CertificationId = src.CertificationId
            , ExpiresAtUtc = src.ExpiresAtUtc
            , DaysUntilExpiry = src.DaysUntilExpiry
            , HasActiveWaiver = src.HasWaiver
            , LastEvaluatedAtUtc = @NowUtc
            , ResolvedAtUtc = NULL
        WHEN NOT MATCHED BY TARGET THEN INSERT
              (EmployeeId, RequirementId, CompetencyId, GapType, Severity
             , CurrentLevelOrdinal, RequiredLevelOrdinal, CertificationId
             , ExpiresAtUtc, DaysUntilExpiry, HasActiveWaiver)
            VALUES (@EmployeeId, src.RequirementId, src.CompetencyId, src.GapType, src.Severity
                  , src.CurrentLevelOrdinal, src.RequiredLevelOrdinal, src.CertificationId
                  , src.ExpiresAtUtc, src.DaysUntilExpiry, src.HasWaiver);

        /* Cerrar las brechas que ya no aplican (requisito cumplido o el
           requisito dejo de aplicarle al empleado). */
        UPDATE g
        SET g.ResolvedAtUtc = @NowUtc, g.LastEvaluatedAtUtc = @NowUtc
        FROM comp.CompetencyGap g
        WHERE g.EmployeeId = @EmployeeId
          AND g.ResolvedAtUtc IS NULL
          AND NOT EXISTS (SELECT 1 FROM @Gaps x WHERE x.RequirementId = g.RequirementId);

        COMMIT TRANSACTION;

        /* Auto-inscripcion remediadora para las brechas criticas que no
           tienen ya una inscripcion abierta. */
        IF @AutoEnroll = 1
        BEGIN
            DECLARE @ReqId INT, @NewEnrollmentId INT;
            DECLARE gapcur CURSOR LOCAL FAST_FORWARD FOR
                SELECT g.RequirementId
                FROM comp.CompetencyGap g
                WHERE g.EmployeeId = @EmployeeId AND g.ResolvedAtUtc IS NULL
                  AND g.HasActiveWaiver = 0
                  AND g.GapType IN (1, 2, 4, 5)
                  AND g.RemediationEnrollmentId IS NULL;

            OPEN gapcur;
            FETCH NEXT FROM gapcur INTO @ReqId;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                BEGIN TRY
                    SET @NewEnrollmentId = NULL;
                    EXEC dlv.usp_Enrollment_CreateFromRequirement
                          @ActorUserId = ISNULL(@ActorUserId, 1), @EmployeeId = @EmployeeId
                        , @RequirementId = @ReqId, @EnrollmentId = @NewEnrollmentId OUTPUT;

                    IF @NewEnrollmentId IS NOT NULL
                        UPDATE comp.CompetencyGap SET RemediationEnrollmentId = @NewEnrollmentId
                        WHERE EmployeeId = @EmployeeId AND RequirementId = @ReqId AND ResolvedAtUtc IS NULL;
                END TRY
                BEGIN CATCH
                    EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Gap_RecalculateForEmployee'
                                         , @ActorUserId = @ActorUserId;
                END CATCH;
                FETCH NEXT FROM gapcur INTO @ReqId;
            END;
            CLOSE gapcur; DEALLOCATE gapcur;
        END;

        SELECT  COUNT(*) AS OpenGaps
              , SUM(CASE WHEN Severity = 1 THEN 1 ELSE 0 END) AS CriticalGaps
        FROM comp.CompetencyGap
        WHERE EmployeeId = @EmployeeId AND ResolvedAtUtc IS NULL;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Gap_RecalculateForEmployee', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   comp.usp_Eligibility_CheckEmployeeForStation    -- GAP-08

   La pregunta operacional: "¿puede Fulano trabajar la estacion RXR-01
   ahora mismo?". La responde Nexus/Movement por API antes de asignar.

   Rollout por etapas (ver doc 07):
     Shadow  -> siempre permite, registra lo que habria bloqueado.
     Warn    -> permite con advertencia visible.
     Enforce -> bloquea de verdad.
   Nunca se arranca en Enforce. Se arranca en Shadow, se mide la tasa de
   falsos bloqueos, se limpia la data, y despues se aprieta.
   ===================================================================== */
CREATE OR ALTER PROCEDURE comp.usp_Eligibility_CheckEmployeeForStation
      @ActorUserId   INT           = NULL
    , @EmployeeId    INT           = NULL
    , @EmployeeCode  NVARCHAR(30)  = NULL
    , @StationId     INT           = NULL
    , @StationCode   NVARCHAR(40)  = NULL
    , @RequestSource NVARCHAR(50)  = N'Manual'
    , @Decision      TINYINT       = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    /* Decision: 1=Allowed 2=AllowedWithSupervision 3=Blocked
       Errores : 50520 estacion no encontrada                            */
    BEGIN TRY
        SELECT @EmployeeId = COALESCE(@EmployeeId, e.EmployeeId)
        FROM org.Employee e WHERE @EmployeeCode IS NOT NULL AND e.EmployeeCode = @EmployeeCode;

        SELECT @StationId = COALESCE(@StationId, s.StationId)
        FROM org.Station s WHERE @StationCode IS NOT NULL AND s.StationCode = @StationCode;

        IF @EmployeeId IS NULL THROW 50501, 'Empleado no encontrado.', 1;
        IF @StationId  IS NULL THROW 50520, 'Estacion no encontrada.', 1;

        DECLARE @RequiresGating BIT, @GatingMode TINYINT, @NowUtc DATETIME2(3) = SYSUTCDATETIME();

        SELECT @RequiresGating = RequiresGating, @GatingMode = GatingMode
        FROM org.Station WHERE StationId = @StationId;

        /* Requisitos bloqueantes de la estacion vs estado del empleado. */
        DECLARE @Missing TABLE (
              RequirementId INT
            , CompetencyId  INT
            , CompetencyCode NVARCHAR(40)
            , CompetencyName NVARCHAR(250)
            , GapType       TINYINT
            , Severity      TINYINT
            , IsBlocking    BIT
            , HasWaiver     BIT
            , WaiverRequiresSupervision BIT
            , ExpiresAtUtc  DATETIME2(3)
        );

        INSERT INTO @Missing
        SELECT  sc.RequirementId
              , r.CompetencyId
              , cm.CompetencyCode
              , cm.NameEs
              , g.GapType
              , g.Severity
              , sc.IsBlocking
              , ISNULL(g.HasActiveWaiver, 0)
              , ISNULL(w.RequiresSupervision, 0)
              , g.ExpiresAtUtc
        FROM comp.StationCompetency sc
        JOIN comp.CompetencyRequirement r ON r.RequirementId = sc.RequirementId AND r.[Status] = 1
        JOIN comp.Competency cm ON cm.CompetencyId = r.CompetencyId
        LEFT JOIN comp.CompetencyGap g ON g.RequirementId = sc.RequirementId
                                      AND g.EmployeeId = @EmployeeId
                                      AND g.ResolvedAtUtc IS NULL
        OUTER APPLY (SELECT TOP (1) w2.RequiresSupervision FROM comp.Waiver w2
                     WHERE w2.EmployeeId = @EmployeeId AND w2.RequirementId = sc.RequirementId
                       AND w2.[Status] = 2 AND w2.RevokedAtUtc IS NULL
                       AND (w2.ExpiresAtUtc IS NULL OR w2.ExpiresAtUtc > @NowUtc)) w
        WHERE sc.StationId = @StationId
          AND g.CompetencyGapId IS NOT NULL;

        /* Decision */
        DECLARE @BlockingCount INT, @WaivedCount INT, @WarnCount INT;

        SELECT  @BlockingCount = SUM(CASE WHEN IsBlocking = 1 AND HasWaiver = 0 THEN 1 ELSE 0 END)
              , @WaivedCount   = SUM(CASE WHEN IsBlocking = 1 AND HasWaiver = 1 THEN 1 ELSE 0 END)
              , @WarnCount     = SUM(CASE WHEN IsBlocking = 0 THEN 1 ELSE 0 END)
        FROM @Missing;

        SET @Decision = CASE
            WHEN ISNULL(@BlockingCount, 0) > 0 THEN 3
            WHEN ISNULL(@WaivedCount, 0) > 0   THEN 2
            ELSE 1 END;

        /* En Shadow y Warn no se bloquea aunque la decision sea Blocked.
           WasEnforced deja claro que se hizo de verdad. */
        DECLARE @WasEnforced BIT =
            CASE WHEN @RequiresGating = 1 AND @GatingMode = 3 AND @Decision = 3 THEN 1 ELSE 0 END;

        INSERT INTO comp.GatingDecisionLog (EmployeeId, StationId, Decision, GatingMode
                                          , WasEnforced, MissingRequirementsJson, RequestSource)
        SELECT @EmployeeId, @StationId, @Decision, ISNULL(@GatingMode, 1), @WasEnforced
             , (SELECT RequirementId, CompetencyCode, GapType, IsBlocking, HasWaiver
                FROM @Missing FOR JSON PATH)
             , @RequestSource;

        /* Resultset 1: veredicto */
        SELECT  @EmployeeId AS EmployeeId
              , @StationId  AS StationId
              , @Decision   AS Decision
              , @WasEnforced AS WasEnforced
              , ISNULL(@GatingMode, 1) AS GatingMode
              , ISNULL(@BlockingCount, 0) AS BlockingGaps
              , ISNULL(@WaivedCount, 0)   AS WaivedGaps
              , ISNULL(@WarnCount, 0)     AS AdvisoryGaps
              , CASE @Decision
                    WHEN 1 THEN N'Autorizado'
                    WHEN 2 THEN N'Autorizado bajo supervision directa'
                    ELSE N'No autorizado: competencias requeridas no vigentes' END AS DecisionText;

        /* Resultset 2: el detalle, para que el supervisor sepa que falta */
        SELECT * FROM @Missing ORDER BY IsBlocking DESC, Severity, CompetencyCode;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Eligibility_CheckEmployeeForStation', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   comp.usp_Acknowledgment_Record   -- firma de lectura de documento
   ===================================================================== */
CREATE OR ALTER PROCEDURE comp.usp_Acknowledgment_Record
      @ActorUserId       INT
    , @DocumentRevisionId INT
    , @EmployeeId        INT           = NULL
    , @ReadSeconds       INT           = 0
    , @LocaleCode        NVARCHAR(10)  = N'es-DO'
    , @DeviceId          INT           = NULL
    , @IpAddress         NVARCHAR(45)  = NULL
    , @AuthMethod        TINYINT       = 2
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50513 revision no activa
                50514 tiempo minimo de lectura no cumplido
                50515 ya firmada                                          */
    BEGIN TRY
        SELECT @EmployeeId = COALESCE(@EmployeeId, EmployeeId) FROM sec.[User] WHERE UserId = @ActorUserId;
        IF @EmployeeId IS NULL THROW 50501, 'Empleado no encontrado.', 1;

        DECLARE @Status TINYINT, @MinSeconds INT, @DocId INT, @DocCode NVARCHAR(60), @SigId BIGINT;

        SELECT @Status = dr.[Status], @MinSeconds = dr.MinimumReadSeconds
             , @DocId = dr.ControlledDocumentId, @DocCode = d.DocumentCode
        FROM comp.ControlledDocumentRevision dr
        JOIN comp.ControlledDocument d ON d.ControlledDocumentId = dr.ControlledDocumentId
        WHERE dr.DocumentRevisionId = @DocumentRevisionId;

        IF @Status IS NULL THROW 50001, 'Revision de documento no encontrada.', 1;
        IF @Status <> 3 THROW 50513, 'Solo se puede firmar la revision vigente del documento.', 1;

        IF @MinSeconds IS NOT NULL AND @ReadSeconds < @MinSeconds
            THROW 50514, 'No se cumplio el tiempo minimo de lectura del documento.', 1;

        IF EXISTS (SELECT 1 FROM comp.DocumentAcknowledgment
                   WHERE DocumentRevisionId = @DocumentRevisionId AND EmployeeId = @EmployeeId)
            THROW 50515, 'El empleado ya firmo esta revision.', 1;

        DECLARE @Payload NVARCHAR(MAX) = (
            SELECT  DocumentCode = @DocCode
                  , DocumentRevisionId = @DocumentRevisionId
                  , EmployeeId = @EmployeeId
                  , ReadSeconds = @ReadSeconds
                  , LocaleCode = @LocaleCode
                  , AcknowledgedAtUtc = SYSUTCDATETIME()
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;

        EXEC aud.usp_Signature_Create
              @ActorUserId = @ActorUserId, @SignatureMeaning = N'Acknowledged'
            , @EntityType = N'ControlledDocumentRevision', @EntityId = @DocumentRevisionId
            , @PayloadCanonical = @Payload, @AuthMethod = @AuthMethod
            , @DeviceId = @DeviceId, @IpAddress = @IpAddress
            , @SignatureRecordId = @SigId OUTPUT;

        INSERT INTO comp.DocumentAcknowledgment (DocumentRevisionId, EmployeeId, LocaleCode
                                               , ReadSeconds, SignatureId, DeviceId, IpAddress, IsCurrent)
        VALUES (@DocumentRevisionId, @EmployeeId, @LocaleCode, @ReadSeconds, @SigId, @DeviceId, @IpAddress, 1);

        COMMIT TRANSACTION;

        /* Firmar un documento puede cerrar un requisito por si solo. */
        EXEC comp.usp_Certification_EvaluateAndIssue
              @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId
            , @TriggerType = 4, @TriggerId = @DocumentRevisionId;

        SELECT SCOPE_IDENTITY() AS DocumentAcknowledgmentId, @SigId AS SignatureRecordId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Acknowledgment_Record', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   comp.usp_Certification_RefreshStatuses   -- job diario 3:30am
   Mueve Valid -> ExpiringSoon -> Expired y encola avisos escalonados.
   ===================================================================== */
CREATE OR ALTER PROCEDURE comp.usp_Certification_RefreshStatuses
      @ActorUserId INT = NULL
    , @BatchSize   INT = 5000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME()
              , @ToExpiring INT = 0, @ToExpired INT = 0;

        BEGIN TRANSACTION;

        /* Valid -> ExpiringSoon */
        UPDATE TOP (@BatchSize) c
        SET c.[Status] = 2
        FROM comp.Certification c
        JOIN comp.CompetencyRequirement r ON r.RequirementId = c.RequirementId
        WHERE c.[Status] = 1
          AND c.ExpiresAtUtc IS NOT NULL
          AND c.RevokedAtUtc IS NULL
          AND c.ExpiresAtUtc <= DATEADD(DAY, ops.fn_FirstAlertWindowDays(r.AlertWindowDays), @NowUtc)
          AND c.ExpiresAtUtc > @NowUtc;
        SET @ToExpiring = @@ROWCOUNT;

        /* ExpiringSoon/Valid -> Expired (respetando el periodo de gracia) */
        UPDATE TOP (@BatchSize) c
        SET c.[Status] = 3
        FROM comp.Certification c
        JOIN comp.CompetencyRequirement r ON r.RequirementId = c.RequirementId
        WHERE c.[Status] IN (1, 2, 6)
          AND c.ExpiresAtUtc IS NOT NULL
          AND c.RevokedAtUtc IS NULL
          AND DATEADD(DAY, r.GracePeriodDays, c.ExpiresAtUtc) < @NowUtc;
        SET @ToExpired = @@ROWCOUNT;

        COMMIT TRANSACTION;

        /* Avisos escalonados a 60/30/14/7/1 dias. El DedupeKey que arma
           ops.usp_Notification_Enqueue evita mandar el mismo aviso todas
           las noches durante dos meses. A 7 dias o menos se escala al
           supervisor: es quien puede liberar al operador para hacerlo. */
        DECLARE @NotifEmployeeId INT, @NotifCertNumber NVARCHAR(40)
              , @NotifDays INT, @NotifCertId INT, @NotifModel NVARCHAR(MAX);

        DECLARE expiring CURSOR LOCAL FAST_FORWARD FOR
            SELECT c.CertificationId, c.EmployeeId, c.CertificateNumber
                 , DATEDIFF(DAY, @NowUtc, c.ExpiresAtUtc)
                 , (SELECT CertificateNumber = c.CertificateNumber
                         , CompetencyName = cm.NameEs
                         , ExpiresAtUtc = c.ExpiresAtUtc
                         , DaysRemaining = DATEDIFF(DAY, @NowUtc, c.ExpiresAtUtc)
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
            FROM comp.Certification c
            JOIN comp.Competency cm ON cm.CompetencyId = c.CompetencyId
            WHERE c.[Status] = 2
              AND c.ExpiresAtUtc IS NOT NULL
              AND c.RevokedAtUtc IS NULL
              AND DATEDIFF(DAY, @NowUtc, c.ExpiresAtUtc) IN (60, 30, 14, 7, 1);

        OPEN expiring;
        FETCH NEXT FROM expiring INTO @NotifCertId, @NotifEmployeeId, @NotifCertNumber, @NotifDays, @NotifModel;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC ops.usp_Notification_Enqueue
                  @TemplateCode = N'Certification.ExpiringSoon'
                , @RecipientEmployeeId = @NotifEmployeeId
                , @ModelJson = @NotifModel
                , @Priority = CASE WHEN @NotifDays <= 7 THEN 1 ELSE 2 END
                , @NotifySupervisor = CASE WHEN @NotifDays <= 7 THEN 1 ELSE 0 END
                , @DedupeKey = N'CERT-EXP-' + CAST(@NotifCertId AS NVARCHAR(12))
                             + N'-' + CAST(@NotifDays AS NVARCHAR(6));

            FETCH NEXT FROM expiring INTO @NotifCertId, @NotifEmployeeId, @NotifCertNumber, @NotifDays, @NotifModel;
        END;
        CLOSE expiring; DEALLOCATE expiring;

        SELECT @ToExpiring AS MovedToExpiringSoon, @ToExpired AS MovedToExpired;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Certification_RefreshStatuses', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Requisitos de competencia
   ===================================================================== */
CREATE OR ALTER PROCEDURE comp.usp_Requirement_Create
      @ActorUserId INT, @RequirementCode NVARCHAR(40), @CompetencyId INT
    , @MinimumLevelId INT, @ScopeType TINYINT, @ScopeId INT = NULL
    , @ValidityMonths INT = NULL, @AlertWindowDays NVARCHAR(50) = N'60,30,7'
    , @Criticality TINYINT = 2, @RegulatoryBasis NVARCHAR(200) = NULL
    , @GracePeriodDays INT = 0, @AllowProvisional BIT = 0
    , @AppliesFromHireDays INT = 0, @Status TINYINT = 2
    , @EffectiveFromUtc DATETIME2(3) = NULL
    , @RequirementId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* Errores: 50530 codigo duplicado
                50531 el nivel no pertenece a la competencia
                50532 alcance invalido                                    */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'requirement.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para definir requisitos de competencia.', 1;

        IF EXISTS (SELECT 1 FROM comp.CompetencyRequirement WHERE RequirementCode = @RequirementCode)
            THROW 50530, 'Ya existe un requisito con ese codigo.', 1;

        IF NOT EXISTS (SELECT 1 FROM comp.CompetencyLevel
                       WHERE CompetencyLevelId = @MinimumLevelId AND CompetencyId = @CompetencyId)
            THROW 50531, 'El nivel minimo no pertenece a la competencia indicada.', 1;

        IF (@ScopeType = 7 AND @ScopeId IS NOT NULL) OR (@ScopeType <> 7 AND @ScopeId IS NULL)
            THROW 50532, 'Alcance invalido: ScopeId solo es nulo cuando el alcance es Global.', 1;

        INSERT INTO comp.CompetencyRequirement (RequirementCode, CompetencyId, MinimumLevelId
                                              , ScopeType, ScopeId, ValidityMonths, AlertWindowDays
                                              , Criticality, RegulatoryBasis, GracePeriodDays
                                              , AllowProvisional, AppliesFromHireDays, [Status]
                                              , EffectiveFromUtc, CreatedByUserId)
        VALUES (@RequirementCode, @CompetencyId, @MinimumLevelId
              , @ScopeType, @ScopeId, @ValidityMonths, @AlertWindowDays
              , @Criticality, @RegulatoryBasis, @GracePeriodDays
              , @AllowProvisional, @AppliesFromHireDays, @Status
              , ISNULL(@EffectiveFromUtc, SYSUTCDATETIME()), @ActorUserId);

        SET @RequirementId = SCOPE_IDENTITY();

        EXEC aud.usp_Event_Log @EventType = N'Requirement.Created', @EntityType = N'CompetencyRequirement'
           , @EntityId = @RequirementId, @ActorUserId = @ActorUserId, @Severity = 3
           , @Summary = N'Requisito de competencia creado.';
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Requirement_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Requirement_SetSatisfiers
      @ActorUserId INT, @RequirementId INT, @SatisfiersJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* JSON: [{"satisfierType":1,"satisfierId":12,"isMandatory":true,
               "alternativeGroup":null,"sortOrder":1}]                    */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'requirement.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF ISJSON(@SatisfiersJson) <> 1 THROW 50533, 'El payload de satisfactores no es JSON valido.', 1;

        BEGIN TRANSACTION;
        DELETE FROM comp.RequirementSatisfier WHERE RequirementId = @RequirementId;

        INSERT INTO comp.RequirementSatisfier (RequirementId, SatisfierType, SatisfierId
                                             , ExternalCredentialName, IsMandatory, AlternativeGroup, SortOrder)
        SELECT @RequirementId, j.SatisfierType, j.SatisfierId, j.ExternalCredentialName
             , ISNULL(j.IsMandatory, 1), j.AlternativeGroup, ISNULL(j.SortOrder, 0)
        FROM OPENJSON(@SatisfiersJson) WITH (
              SatisfierType TINYINT        N'$.satisfierType'
            , SatisfierId   INT            N'$.satisfierId'
            , ExternalCredentialName NVARCHAR(250) N'$.externalCredentialName'
            , IsMandatory   BIT            N'$.isMandatory'
            , AlternativeGroup TINYINT     N'$.alternativeGroup'
            , SortOrder     INT            N'$.sortOrder') j;

        COMMIT TRANSACTION;
        SELECT COUNT(*) AS SatisfiersSet FROM comp.RequirementSatisfier WHERE RequirementId = @RequirementId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Requirement_SetSatisfiers', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Requirement_SetDocuments
      @ActorUserId INT, @RequirementId INT, @DocumentIds ops.IntListType READONLY
    , @InvalidateOnRevision BIT = 1
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Este vinculo es el que hace funcionar GAP-02. Si esta vacio, una
       revision de WI no invalida nada. */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'requirement.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        BEGIN TRANSACTION;
        DELETE FROM comp.RequirementDocument
        WHERE RequirementId = @RequirementId
          AND ControlledDocumentId NOT IN (SELECT [Value] FROM @DocumentIds);

        INSERT INTO comp.RequirementDocument (RequirementId, ControlledDocumentId, InvalidateOnRevision)
        SELECT @RequirementId, d.[Value], @InvalidateOnRevision
        FROM @DocumentIds d
        WHERE NOT EXISTS (SELECT 1 FROM comp.RequirementDocument rd
                          WHERE rd.RequirementId = @RequirementId AND rd.ControlledDocumentId = d.[Value]);
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Requirement_SetDocuments', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Requirement_Get @ActorUserId INT, @RequirementId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.*, c.CompetencyCode, c.NameEs AS CompetencyName
         , cl.LevelCode, cl.NameEs AS LevelName, cl.LevelOrdinal
    FROM comp.CompetencyRequirement r
    JOIN comp.Competency c ON c.CompetencyId = r.CompetencyId
    JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = r.MinimumLevelId
    WHERE r.RequirementId = @RequirementId;

    SELECT rs.* FROM comp.RequirementSatisfier rs WHERE rs.RequirementId = @RequirementId ORDER BY rs.SortOrder;

    SELECT rd.ControlledDocumentId, d.DocumentCode, d.TitleEs, rd.InvalidateOnRevision
         , dr.RevisionLabel AS CurrentRevision
    FROM comp.RequirementDocument rd
    JOIN comp.ControlledDocument d ON d.ControlledDocumentId = rd.ControlledDocumentId
    LEFT JOIN comp.ControlledDocumentRevision dr ON dr.DocumentRevisionId = d.CurrentRevisionId
    WHERE rd.RequirementId = @RequirementId;
    RETURN 0;
END;
GO

/* Consulta temporal: "que exigia este requisito el 12 de marzo".
   Posible solo porque la tabla es temporal (SYSTEM_VERSIONING). */
CREATE OR ALTER PROCEDURE comp.usp_Requirement_GetAsOf
      @ActorUserId INT, @RequirementId INT, @AsOfUtc DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.RequirementId, r.RequirementCode, r.CompetencyId, r.MinimumLevelId
         , r.ScopeType, r.ScopeId, r.ValidityMonths, r.Criticality
         , r.RegulatoryBasis, r.[Status], r.ValidFromUtc, r.ValidToUtc
    FROM comp.CompetencyRequirement FOR SYSTEM_TIME AS OF @AsOfUtc r
    WHERE r.RequirementId = @RequirementId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Requirement_GetForEmployee @ActorUserId INT, @EmployeeId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT r.RequirementId, r.CompetencyId, c.CompetencyCode, c.NameEs AS CompetencyName
         , r.RequiredLevelOrdinal, r.ValidityMonths, r.Criticality, r.RegulatoryBasis
         , cert.CertificationId, cert.CertificateNumber, cert.[Status] AS CertificationStatus
         , cert.ExpiresAtUtc
    FROM comp.fn_GetEffectiveRequirements(@EmployeeId) r
    JOIN comp.Competency c ON c.CompetencyId = r.CompetencyId
    OUTER APPLY (SELECT TOP (1) c2.CertificationId, c2.CertificateNumber, c2.[Status], c2.ExpiresAtUtc
                 FROM comp.Certification c2
                 WHERE c2.EmployeeId = @EmployeeId AND c2.CompetencyId = r.CompetencyId
                   AND c2.RevokedAtUtc IS NULL
                 ORDER BY c2.IssuedAtUtc DESC) cert
    ORDER BY r.Criticality, c.CompetencyCode;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Requirement_Update
      @ActorUserId INT, @RequirementId INT
    , @MinimumLevelId INT = NULL, @ValidityMonths INT = NULL
    , @AlertWindowDays NVARCHAR(50) = NULL, @Criticality TINYINT = NULL
    , @RegulatoryBasis NVARCHAR(200) = NULL, @GracePeriodDays INT = NULL
    , @AllowProvisional BIT = NULL, @Status TINYINT = NULL, @Notes NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'requirement.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    UPDATE comp.CompetencyRequirement
    SET MinimumLevelId = ISNULL(@MinimumLevelId, MinimumLevelId)
      , ValidityMonths = ISNULL(@ValidityMonths, ValidityMonths)
      , AlertWindowDays = ISNULL(@AlertWindowDays, AlertWindowDays)
      , Criticality = ISNULL(@Criticality, Criticality)
      , RegulatoryBasis = ISNULL(@RegulatoryBasis, RegulatoryBasis)
      , GracePeriodDays = ISNULL(@GracePeriodDays, GracePeriodDays)
      , AllowProvisional = ISNULL(@AllowProvisional, AllowProvisional)
      , [Status] = ISNULL(@Status, [Status])
      , Notes = ISNULL(@Notes, Notes)
      , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE RequirementId = @RequirementId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Requirement_Deactivate
      @ActorUserId INT, @RequirementId INT, @Reason NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* No se borra jamas: hay certificaciones apuntando a el. Se cierra
       con EffectiveToUtc para que la consulta temporal siga funcionando. */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'requirement.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF @Reason IS NULL OR LEN(LTRIM(@Reason)) < 10
            THROW 50534, 'Debe indicar la justificacion de la desactivacion.', 1;

        UPDATE comp.CompetencyRequirement
        SET [Status] = 3, EffectiveToUtc = SYSUTCDATETIME()
          , Notes = ISNULL(Notes + NCHAR(13) + NCHAR(10), N'') + N'[Desactivado] ' + @Reason
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE RequirementId = @RequirementId;

        EXEC aud.usp_Event_Log @EventType = N'Requirement.Deactivated', @EntityType = N'CompetencyRequirement'
           , @EntityId = @RequirementId, @ActorUserId = @ActorUserId, @Severity = 4
           , @Summary = N'Requisito de competencia desactivado.';
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Requirement_Deactivate', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Competencias, certificaciones, waivers, evaluadores, documentos
   ===================================================================== */
CREATE OR ALTER PROCEDURE comp.usp_Competency_Create
      @ActorUserId INT, @CompetencyCode NVARCHAR(40), @NameEs NVARCHAR(250)
    , @NameEn NVARCHAR(250) = NULL, @CompetencyType TINYINT = 1
    , @OwnerDepartmentId INT = NULL, @DescriptionEs NVARCHAR(MAX) = NULL
    , @CompetencyId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'competency.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO comp.Competency (CompetencyCode, NameEs, NameEn, DescriptionEs
                               , CompetencyType, OwnerDepartmentId, CreatedByUserId)
    VALUES (@CompetencyCode, @NameEs, @NameEn, @DescriptionEs
          , @CompetencyType, @OwnerDepartmentId, @ActorUserId);
    SET @CompetencyId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Competency_SetLevels
      @ActorUserId INT, @CompetencyId INT, @LevelsJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* JSON: [{"levelOrdinal":1,"levelCode":"AWARENESS","nameEs":"Conoce",
               "canEvaluate":false}]                                      */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'competency.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF ISJSON(@LevelsJson) <> 1 THROW 50533, 'El payload de niveles no es JSON valido.', 1;

        BEGIN TRANSACTION;
        MERGE comp.CompetencyLevel AS tgt
        USING (SELECT @CompetencyId AS CompetencyId, j.LevelOrdinal, j.LevelCode
                    , j.NameEs, j.NameEn, j.DescriptionEs, ISNULL(j.CanEvaluate, 0) AS CanEvaluate
               FROM OPENJSON(@LevelsJson) WITH (
                     LevelOrdinal TINYINT       N'$.levelOrdinal'
                   , LevelCode    NVARCHAR(30)  N'$.levelCode'
                   , NameEs       NVARCHAR(100) N'$.nameEs'
                   , NameEn       NVARCHAR(100) N'$.nameEn'
                   , DescriptionEs NVARCHAR(1000) N'$.descriptionEs'
                   , CanEvaluate  BIT           N'$.canEvaluate') j) AS src
        ON tgt.CompetencyId = src.CompetencyId AND tgt.LevelOrdinal = src.LevelOrdinal
        WHEN MATCHED THEN UPDATE SET
              LevelCode = src.LevelCode, NameEs = src.NameEs, NameEn = src.NameEn
            , DescriptionEs = src.DescriptionEs, CanEvaluate = src.CanEvaluate
        WHEN NOT MATCHED THEN INSERT
              (CompetencyId, LevelOrdinal, LevelCode, NameEs, NameEn, DescriptionEs, CanEvaluate)
            VALUES (src.CompetencyId, src.LevelOrdinal, src.LevelCode, src.NameEs
                  , src.NameEn, src.DescriptionEs, src.CanEvaluate);
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Competency_SetLevels', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Certification_Get @ActorUserId INT, @CertificationId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT c.*, cm.CompetencyCode, cm.NameEs AS CompetencyName
         , cl.LevelCode, cl.NameEs AS LevelName
         , e.EmployeeCode
    FROM comp.Certification c
    JOIN comp.Competency cm ON cm.CompetencyId = c.CompetencyId
    JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = c.CompetencyLevelId
    JOIN org.Employee e ON e.EmployeeId = c.EmployeeId
    WHERE c.CertificationId = @CertificationId;

    SELECT ce.* FROM comp.CertificationEvidence ce
    WHERE ce.CertificationId = @CertificationId ORDER BY ce.CompletedAtUtc;
    RETURN 0;
END;
GO

/* Verificacion publica por QR. Devuelve lo minimo: valido / no valido,
   sin exponer datos personales de mas. */
CREATE OR ALTER PROCEDURE comp.usp_Certification_VerifyByNumber
      @CertificateNumber NVARCHAR(40)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT  c.CertificateNumber
          , c.EmployeeNameSnapshot AS EmployeeName
          , cm.NameEs AS CompetencyName
          , cl.NameEs AS LevelName
          , c.IssuedAtUtc
          , c.ExpiresAtUtc
          , comp.fn_GetCertificationStatus(c.[Status], c.ExpiresAtUtc, 0, SYSUTCDATETIME()) AS CurrentStatus
          , CASE WHEN c.RevokedAtUtc IS NOT NULL THEN CAST(0 AS BIT)
                 WHEN c.ExpiresAtUtc IS NOT NULL AND c.ExpiresAtUtc < SYSUTCDATETIME() THEN CAST(0 AS BIT)
                 WHEN c.[Status] IN (1, 2, 6) THEN CAST(1 AS BIT)
                 ELSE CAST(0 AS BIT) END AS IsValid
    FROM comp.Certification c
    JOIN comp.Competency cm ON cm.CompetencyId = c.CompetencyId
    JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = c.CompetencyLevelId
    WHERE c.CertificateNumber = @CertificateNumber;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Certification_Revoke
      @ActorUserId INT, @CertificationId INT, @Reason NVARCHAR(1000)
    , @AuthMethod TINYINT = 1
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50540 justificacion insuficiente */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'certification.revoke') = 0
            THROW 50002, 'El usuario no tiene permiso para revocar certificaciones.', 1;
        IF @Reason IS NULL OR LEN(LTRIM(@Reason)) < 15
            THROW 50540, 'La justificacion de revocacion es obligatoria y debe ser explicita.', 1;

        DECLARE @EmployeeId INT, @SigId BIGINT, @CertNumber NVARCHAR(40);
        SELECT @EmployeeId = EmployeeId, @CertNumber = CertificateNumber
        FROM comp.Certification WHERE CertificationId = @CertificationId;
        IF @EmployeeId IS NULL THROW 50001, 'Certificacion no encontrada.', 1;

        BEGIN TRANSACTION;
        UPDATE comp.Certification
        SET [Status] = 5, RevokedAtUtc = SYSUTCDATETIME(), RevokedByUserId = @ActorUserId
          , RevokeReason = @Reason
        WHERE CertificationId = @CertificationId;

        DECLARE @Payload NVARCHAR(MAX) = (
            SELECT CertificationId = @CertificationId, CertificateNumber = @CertNumber
                 , RevokedAtUtc = SYSUTCDATETIME(), Reason = @Reason
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC aud.usp_Signature_Create
              @ActorUserId = @ActorUserId, @SignatureMeaning = N'Approved'
            , @EntityType = N'Certification', @EntityId = @CertificationId
            , @PayloadCanonical = @Payload, @AuthMethod = @AuthMethod
            , @SignatureRecordId = @SigId OUTPUT;

        EXEC aud.usp_Event_Log @EventType = N'Certification.Revoked', @EntityType = N'Certification'
           , @EntityId = @CertificationId, @EmployeeId = @EmployeeId, @ActorUserId = @ActorUserId
           , @Severity = 4, @Summary = N'Certificacion revocada: ' + @CertNumber;
        COMMIT TRANSACTION;

        /* Revocar abre brechas y puede bloquear estaciones de inmediato. */
        EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Certification_Revoke', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Certification_Reinstate
      @ActorUserId INT, @CertificationId INT, @Justification NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'certification.reinstate') = 0
            THROW 50002, 'El usuario no tiene permiso para reinstalar certificaciones.', 1;
        IF @Justification IS NULL OR LEN(LTRIM(@Justification)) < 15
            THROW 50540, 'La justificacion de reinstalacion es obligatoria.', 1;

        DECLARE @EmployeeId INT;
        SELECT @EmployeeId = EmployeeId FROM comp.Certification WHERE CertificationId = @CertificationId;

        UPDATE comp.Certification
        SET [Status] = 1, RevokedAtUtc = NULL
          , ReinstatedAtUtc = SYSUTCDATETIME(), ReinstatedByUserId = @ActorUserId
          , ReinstateJustification = @Justification
        WHERE CertificationId = @CertificationId AND [Status] = 5;

        EXEC aud.usp_Event_Log @EventType = N'Certification.Reinstated', @EntityType = N'Certification'
           , @EntityId = @CertificationId, @EmployeeId = @EmployeeId, @ActorUserId = @ActorUserId
           , @Severity = 4, @Summary = N'Certificacion reinstalada.';

        EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Certification_Reinstate', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Certification_GetExpiring
      @ActorUserId INT, @WithinDays INT = 60, @DepartmentId INT = NULL
    , @SiteId INT = NULL, @OnlyCritical BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT  c.CertificationId, c.CertificateNumber, c.EmployeeId
          , e.EmployeeCode, e.FullName, d.[Name] AS DepartmentName
          , cm.CompetencyCode, cm.NameEs AS CompetencyName
          , c.ExpiresAtUtc, DATEDIFF(DAY, SYSUTCDATETIME(), c.ExpiresAtUtc) AS DaysRemaining
          , r.Criticality, r.RegulatoryBasis
    FROM comp.Certification c
    JOIN org.Employee e ON e.EmployeeId = c.EmployeeId AND e.IsActive = 1
    JOIN comp.Competency cm ON cm.CompetencyId = c.CompetencyId
    LEFT JOIN comp.CompetencyRequirement r ON r.RequirementId = c.RequirementId
    LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
    WHERE c.[Status] IN (1, 2, 6)
      AND c.RevokedAtUtc IS NULL
      AND c.ExpiresAtUtc IS NOT NULL
      AND c.ExpiresAtUtc <= DATEADD(DAY, @WithinDays, SYSUTCDATETIME())
      AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
      AND (@SiteId       IS NULL OR e.SiteId       = @SiteId)
      AND (@OnlyCritical = 0 OR r.Criticality = 1)
    ORDER BY c.ExpiresAtUtc
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Certification_GetCertificateData
      @ActorUserId INT, @CertificationId INT, @LocaleCode NVARCHAR(10) = N'es-DO'
AS
BEGIN
    SET NOCOUNT ON;
    /* Alimenta la generacion del PDF/HTML del certificado. */
    SELECT  c.CertificateNumber, c.PublicId
          , c.EmployeeNameSnapshot, c.PositionNameSnapshot
          , e.EmployeeCode
          , CASE WHEN @LocaleCode = N'en-US' THEN ISNULL(cm.NameEn, cm.NameEs) ELSE cm.NameEs END AS CompetencyName
          , CASE WHEN @LocaleCode = N'en-US' THEN ISNULL(cl.NameEn, cl.NameEs) ELSE cl.NameEs END AS LevelName
          , c.IssuedAtUtc, c.EvidenceCompletedAtUtc, c.ExpiresAtUtc
          , r.RegulatoryBasis
          , s.[Name] AS SiteName
          , iss.DisplayName AS IssuedByName
          , CONVERT(NVARCHAR(64), sig.PayloadHash, 2) AS SignatureHashHex
    FROM comp.Certification c
    JOIN org.Employee e ON e.EmployeeId = c.EmployeeId
    JOIN comp.Competency cm ON cm.CompetencyId = c.CompetencyId
    JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = c.CompetencyLevelId
    LEFT JOIN comp.CompetencyRequirement r ON r.RequirementId = c.RequirementId
    LEFT JOIN org.Site s ON s.SiteId = e.SiteId
    LEFT JOIN sec.[User] iss ON iss.UserId = c.IssuedByUserId
    LEFT JOIN aud.SignatureRecord sig ON sig.SignatureId = c.SignatureId
    WHERE c.CertificationId = @CertificationId;

    SELECT ct.HtmlTemplate FROM comp.CertificationTemplate ct
    WHERE ct.IsActive = 1 AND ct.LocaleCode = @LocaleCode
      AND (ct.CompetencyId = (SELECT CompetencyId FROM comp.Certification WHERE CertificationId = @CertificationId)
           OR ct.IsDefault = 1)
    ORDER BY CASE WHEN ct.CompetencyId IS NULL THEN 1 ELSE 0 END;
    RETURN 0;
END;
GO

/* Marca para re-entrenamiento por republicacion de curso (lo llama
   lms.usp_CourseVersion_Publish cuando RequiresRetraining = 1). */
CREATE OR ALTER PROCEDURE comp.usp_Certification_FlagRetrainingForCourseVersion
      @ActorUserId INT, @PreviousVersionId INT, @NewVersionId INT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @CourseId INT, @Affected INT = 0;
        SELECT @CourseId = CourseId FROM lms.CourseVersion WHERE CourseVersionId = @NewVersionId;

        DECLARE @Targets TABLE (CertificationId INT PRIMARY KEY, EmployeeId INT, RequirementId INT);

        INSERT INTO @Targets
        SELECT DISTINCT c.CertificationId, c.EmployeeId, c.RequirementId
        FROM comp.Certification c
        JOIN comp.RequirementSatisfier rs ON rs.RequirementId = c.RequirementId
                                         AND rs.SatisfierType = 1 AND rs.SatisfierId = @CourseId
        JOIN comp.CertificationEvidence ce ON ce.CertificationId = c.CertificationId AND ce.EvidenceType = 1
        JOIN dlv.Enrollment e ON e.EnrollmentId = ce.EvidenceId AND e.CourseVersionId = @PreviousVersionId
        WHERE c.[Status] IN (1, 2, 6) AND c.RevokedAtUtc IS NULL;

        UPDATE c SET c.[Status] = 4
        FROM comp.Certification c JOIN @Targets t ON t.CertificationId = c.CertificationId;
        SET @Affected = @@ROWCOUNT;

        DECLARE @EmpId INT, @ReqId INT, @NewEnrollId INT;
        DECLARE rt CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT EmployeeId, RequirementId FROM @Targets WHERE RequirementId IS NOT NULL;
        OPEN rt; FETCH NEXT FROM rt INTO @EmpId, @ReqId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                EXEC dlv.usp_Enrollment_CreateFromRequirement
                      @ActorUserId = @ActorUserId, @EmployeeId = @EmpId
                    , @RequirementId = @ReqId, @EnrollmentId = @NewEnrollId OUTPUT;
            END TRY
            BEGIN CATCH
                EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Certification_FlagRetrainingForCourseVersion'
                                     , @ActorUserId = @ActorUserId;
            END CATCH;
            FETCH NEXT FROM rt INTO @EmpId, @ReqId;
        END;
        CLOSE rt; DEALLOCATE rt;

        SELECT @Affected AS CertificationsFlagged;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Certification_FlagRetrainingForCourseVersion', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Gap_RecalculateAll
      @ActorUserId INT = NULL, @SiteId INT = NULL, @DepartmentId INT = NULL
    , @AutoEnroll BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    /* Job nocturno 3:00am. Procesa empleado por empleado para que una
       fila mala no tumbe la corrida completa. */
    DECLARE @EmployeeId INT, @Processed INT = 0, @Errors INT = 0;

    DECLARE emp CURSOR LOCAL FAST_FORWARD FOR
        SELECT EmployeeId FROM org.Employee
        WHERE IsActive = 1
          AND (@SiteId IS NULL OR SiteId = @SiteId)
          AND (@DepartmentId IS NULL OR DepartmentId = @DepartmentId);

    OPEN emp; FETCH NEXT FROM emp INTO @EmployeeId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC comp.usp_Gap_RecalculateForEmployee
                  @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId, @AutoEnroll = @AutoEnroll;
            SET @Processed = @Processed + 1;
        END TRY
        BEGIN CATCH
            SET @Errors = @Errors + 1;
            EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Gap_RecalculateAll', @ActorUserId = @ActorUserId;
        END CATCH;
        FETCH NEXT FROM emp INTO @EmployeeId;
    END;
    CLOSE emp; DEALLOCATE emp;

    SELECT @Processed AS EmployeesProcessed, @Errors AS Errors;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Gap_List
      @ActorUserId INT, @EmployeeId INT = NULL, @DepartmentId INT = NULL
    , @AreaId INT = NULL, @SiteId INT = NULL, @Severity TINYINT = NULL
    , @GapType TINYINT = NULL, @IncludeWaived BIT = 0
    , @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    SELECT  g.CompetencyGapId, g.EmployeeId, e.EmployeeCode, e.FullName
          , d.[Name] AS DepartmentName, a.[Name] AS AreaName
          , g.RequirementId, r.RequirementCode, r.RegulatoryBasis
          , g.CompetencyId, cm.CompetencyCode, cm.NameEs AS CompetencyName
          , g.GapType, g.Severity, g.CurrentLevelOrdinal, g.RequiredLevelOrdinal
          , g.ExpiresAtUtc, g.DaysUntilExpiry, g.HasActiveWaiver
          , g.RemediationEnrollmentId, g.DetectedAtUtc
    FROM comp.CompetencyGap g
    JOIN org.Employee e ON e.EmployeeId = g.EmployeeId AND e.IsActive = 1
    JOIN comp.Competency cm ON cm.CompetencyId = g.CompetencyId
    JOIN comp.CompetencyRequirement r ON r.RequirementId = g.RequirementId
    LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
    LEFT JOIN org.Area a ON a.AreaId = e.AreaId
    WHERE g.ResolvedAtUtc IS NULL
      AND (@EmployeeId   IS NULL OR g.EmployeeId  = @EmployeeId)
      AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
      AND (@AreaId       IS NULL OR e.AreaId       = @AreaId)
      AND (@SiteId       IS NULL OR e.SiteId       = @SiteId)
      AND (@Severity     IS NULL OR g.Severity     = @Severity)
      AND (@GapType      IS NULL OR g.GapType      = @GapType)
      AND (@IncludeWaived = 1 OR g.HasActiveWaiver = 0)
    ORDER BY g.Severity, g.DaysUntilExpiry, e.FullName
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Gap_GetSummary
      @ActorUserId INT, @SiteId INT = NULL, @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT  g.Severity
          , g.GapType
          , COUNT(*) AS GapCount
          , COUNT(DISTINCT g.EmployeeId) AS EmployeesAffected
    FROM comp.CompetencyGap g
    JOIN org.Employee e ON e.EmployeeId = g.EmployeeId AND e.IsActive = 1
    WHERE g.ResolvedAtUtc IS NULL AND g.HasActiveWaiver = 0
      AND (@SiteId       IS NULL OR e.SiteId       = @SiteId)
      AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
    GROUP BY g.Severity, g.GapType
    ORDER BY g.Severity, g.GapType
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Waiver_Request
      @ActorUserId INT, @EmployeeId INT, @RequirementId INT
    , @WaiverType TINYINT, @Justification NVARCHAR(MAX)
    , @RequiresSupervision BIT = 1, @ExpiresAtUtc DATETIME2(3) = NULL
    , @WaiverId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    /* Errores: 50550 justificacion insuficiente
                50551 todo waiver debe tener fecha de vencimiento
       Un waiver sin fecha de fin es una excepcion permanente disfrazada.
       El auditor los detecta a la primera. */
    IF @Justification IS NULL OR LEN(LTRIM(@Justification)) < 20
        THROW 50550, 'La justificacion del waiver es obligatoria y debe ser detallada.', 1;
    IF @ExpiresAtUtc IS NULL
        THROW 50551, 'Todo waiver debe tener fecha de vencimiento.', 1;

    INSERT INTO comp.Waiver (EmployeeId, RequirementId, WaiverType, Justification
                           , RequiresSupervision, [Status], RequestedByUserId, ExpiresAtUtc)
    VALUES (@EmployeeId, @RequirementId, @WaiverType, @Justification
          , @RequiresSupervision, 1, @ActorUserId, @ExpiresAtUtc);
    SET @WaiverId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Waiver_Approve
      @ActorUserId INT, @WaiverId INT, @ApproverComments NVARCHAR(1000) = NULL
    , @EffectiveFromUtc DATETIME2(3) = NULL, @AuthMethod TINYINT = 1
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* SoD: quien solicita no aprueba. Errores: 50552 */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'waiver.approve') = 0
            THROW 50002, 'El usuario no tiene permiso para aprobar waivers.', 1;

        DECLARE @RequestedBy INT, @EmployeeId INT, @SigId BIGINT;
        SELECT @RequestedBy = RequestedByUserId, @EmployeeId = EmployeeId
        FROM comp.Waiver WHERE WaiverId = @WaiverId AND [Status] = 1;

        IF @EmployeeId IS NULL THROW 50001, 'Waiver no encontrado o ya decidido.', 1;
        IF @RequestedBy = @ActorUserId
            THROW 50552, 'Segregacion de funciones: quien solicita el waiver no puede aprobarlo.', 1;

        BEGIN TRANSACTION;
        UPDATE comp.Waiver
        SET [Status] = 2, ApprovedByUserId = @ActorUserId, ApprovedAtUtc = SYSUTCDATETIME()
          , ApproverComments = @ApproverComments
          , EffectiveFromUtc = ISNULL(@EffectiveFromUtc, SYSUTCDATETIME())
        WHERE WaiverId = @WaiverId;

        DECLARE @Payload NVARCHAR(MAX) = (
            SELECT WaiverId = @WaiverId, EmployeeId = @EmployeeId
                 , ApprovedAtUtc = SYSUTCDATETIME()
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC aud.usp_Signature_Create
              @ActorUserId = @ActorUserId, @SignatureMeaning = N'Approved'
            , @EntityType = N'Waiver', @EntityId = @WaiverId
            , @PayloadCanonical = @Payload, @AuthMethod = @AuthMethod
            , @SignatureRecordId = @SigId OUTPUT;

        UPDATE comp.Waiver SET SignatureId = @SigId WHERE WaiverId = @WaiverId;

        EXEC aud.usp_Event_Log @EventType = N'Waiver.Approved', @EntityType = N'Waiver'
           , @EntityId = @WaiverId, @EmployeeId = @EmployeeId, @ActorUserId = @ActorUserId
           , @Severity = 4, @Summary = N'Waiver de competencia aprobado.';
        COMMIT TRANSACTION;

        EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Waiver_Approve', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Waiver_List
      @ActorUserId INT, @Status TINYINT = NULL, @EmployeeId INT = NULL
    , @DepartmentId INT = NULL, @OnlyActive BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT  w.WaiverId, w.PublicId, w.EmployeeId, e.EmployeeCode, e.FullName
          , d.[Name] AS DepartmentName
          , w.RequirementId, r.RequirementCode, cm.NameEs AS CompetencyName
          , w.WaiverType, w.[Status], w.RequiresSupervision, w.Justification
          , req.DisplayName AS RequestedByName, w.RequestedAtUtc
          , app.DisplayName AS ApprovedByName, w.ApprovedAtUtc
          , w.EffectiveFromUtc, w.ExpiresAtUtc
          , CASE WHEN w.[Status] = 2 AND w.RevokedAtUtc IS NULL
                  AND (w.ExpiresAtUtc IS NULL OR w.ExpiresAtUtc > SYSUTCDATETIME())
                 THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsCurrentlyActive
    FROM comp.Waiver w
    JOIN org.Employee e ON e.EmployeeId = w.EmployeeId
    JOIN comp.CompetencyRequirement r ON r.RequirementId = w.RequirementId
    JOIN comp.Competency cm ON cm.CompetencyId = r.CompetencyId
    LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
    LEFT JOIN sec.[User] req ON req.UserId = w.RequestedByUserId
    LEFT JOIN sec.[User] app ON app.UserId = w.ApprovedByUserId
    WHERE (@Status       IS NULL OR w.[Status]    = @Status)
      AND (@EmployeeId   IS NULL OR w.EmployeeId  = @EmployeeId)
      AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
      AND (@OnlyActive = 0 OR (w.[Status] = 2 AND w.RevokedAtUtc IS NULL
                               AND (w.ExpiresAtUtc IS NULL OR w.ExpiresAtUtc > SYSUTCDATETIME())))
    ORDER BY w.RequestedAtUtc DESC
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_EvaluatorQualification_Grant
      @ActorUserId INT, @EmployeeId INT, @CompetencyId INT
    , @MaxLevelOrdinal TINYINT, @CanTrain BIT = 1, @CanEvaluate BIT = 1
    , @ExpiresAtUtc DATETIME2(3) = NULL
    , @EvaluatorQualificationId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    /* Errores: 50560 el candidato no esta certificado en la competencia
       Quien evalua tiene que estar certificado al menos al nivel que va
       a certificar. Es la regla que sostiene toda la cadena de OJT. */
    IF sec.fn_UserHasPermission(@ActorUserId, N'evaluator.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para otorgar calificacion de evaluador.', 1;

    IF NOT EXISTS (
        SELECT 1 FROM comp.Certification c
        JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = c.CompetencyLevelId
        WHERE c.EmployeeId = @EmployeeId AND c.CompetencyId = @CompetencyId
          AND c.[Status] IN (1, 2) AND c.RevokedAtUtc IS NULL
          AND cl.LevelOrdinal >= @MaxLevelOrdinal)
        THROW 50560, 'El candidato no tiene certificacion vigente al nivel requerido para evaluar.', 1;

    INSERT INTO comp.EvaluatorQualification (EmployeeId, CompetencyId, MaxLevelOrdinal
                                           , CanTrain, CanEvaluate, GrantedByUserId, ExpiresAtUtc)
    VALUES (@EmployeeId, @CompetencyId, @MaxLevelOrdinal
          , @CanTrain, @CanEvaluate, @ActorUserId, @ExpiresAtUtc);
    SET @EvaluatorQualificationId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Document_Create
      @ActorUserId INT, @DocumentCode NVARCHAR(60), @TitleEs NVARCHAR(300)
    , @TitleEn NVARCHAR(300) = NULL, @DocumentType TINYINT = 1
    , @OwnerDepartmentId INT = NULL, @ProcessCode NVARCHAR(40) = NULL
    , @Classification TINYINT = 2
    , @ControlledDocumentId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'document.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO comp.ControlledDocument (DocumentCode, TitleEs, TitleEn, DocumentType
                                       , OwnerDepartmentId, OwnerUserId, ProcessCode
                                       , Classification, CreatedByUserId)
    VALUES (@DocumentCode, @TitleEs, @TitleEn, @DocumentType
          , @OwnerDepartmentId, @ActorUserId, @ProcessCode, @Classification, @ActorUserId);
    SET @ControlledDocumentId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_DocumentRevision_Create
      @ActorUserId INT, @ControlledDocumentId INT
    , @RevisionLabel NVARCHAR(20) = NULL
    , @FileAssetIdEs INT = NULL, @FileAssetIdEn INT = NULL
    , @ChangeSummaryEs NVARCHAR(MAX) = NULL
    , @RequiresReacknowledgment BIT = 1
    , @ReacknowledgmentDeadlineDays INT = 30
    , @MinimumReadSeconds INT = NULL
    , @DocumentRevisionId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Next INT;
    SELECT @Next = ISNULL(MAX(RevisionNumber), -1) + 1
    FROM comp.ControlledDocumentRevision WHERE ControlledDocumentId = @ControlledDocumentId;

    INSERT INTO comp.ControlledDocumentRevision (ControlledDocumentId, RevisionNumber, RevisionLabel
                                               , [Status], FileAssetIdEs, FileAssetIdEn, ChangeSummaryEs
                                               , RequiresReacknowledgment, ReacknowledgmentDeadlineDays
                                               , MinimumReadSeconds, CreatedByUserId)
    VALUES (@ControlledDocumentId, @Next, ISNULL(@RevisionLabel, N'Rev.' + CAST(@Next AS NVARCHAR(10)))
          , 1, @FileAssetIdEs, @FileAssetIdEn, @ChangeSummaryEs
          , @RequiresReacknowledgment, @ReacknowledgmentDeadlineDays
          , @MinimumReadSeconds, @ActorUserId);
    SET @DocumentRevisionId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_DocumentRevision_AddApproval
      @ActorUserId INT, @DocumentRevisionId INT, @ApprovalRole TINYINT
    , @ApproverUserId INT = NULL, @Decision TINYINT = NULL
    , @Comments NVARCHAR(1000) = NULL, @AuthMethod TINYINT = 1
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        /* Sin @Decision se crea la solicitud; con @Decision se resuelve. */
        IF @Decision IS NULL
        BEGIN
            INSERT INTO comp.DocumentApproval (DocumentRevisionId, ApprovalRole, ApproverUserId)
            VALUES (@DocumentRevisionId, @ApprovalRole, ISNULL(@ApproverUserId, @ActorUserId));

            UPDATE comp.ControlledDocumentRevision SET [Status] = 2
            WHERE DocumentRevisionId = @DocumentRevisionId AND [Status] = 1;
            RETURN 0;
        END;

        DECLARE @SigId BIGINT;
        DECLARE @Payload NVARCHAR(MAX) = (
            SELECT DocumentRevisionId = @DocumentRevisionId, ApprovalRole = @ApprovalRole
                 , Decision = @Decision, DecidedAtUtc = SYSUTCDATETIME()
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        BEGIN TRANSACTION;
        EXEC aud.usp_Signature_Create
              @ActorUserId = @ActorUserId, @SignatureMeaning = N'Reviewed'
            , @EntityType = N'ControlledDocumentRevision', @EntityId = @DocumentRevisionId
            , @PayloadCanonical = @Payload, @AuthMethod = @AuthMethod
            , @SignatureRecordId = @SigId OUTPUT;

        UPDATE comp.DocumentApproval
        SET Decision = @Decision, Comments = @Comments
          , DecidedAtUtc = SYSUTCDATETIME(), SignatureId = @SigId
        WHERE DocumentRevisionId = @DocumentRevisionId AND ApproverUserId = @ActorUserId
          AND ApprovalRole = @ApprovalRole AND DecidedAtUtc IS NULL;

        IF @Decision = 2
            UPDATE comp.ControlledDocumentRevision SET [Status] = 1
            WHERE DocumentRevisionId = @DocumentRevisionId;
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_DocumentRevision_AddApproval', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_DocumentRevision_Get
      @ActorUserId INT, @DocumentRevisionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT dr.*, d.DocumentCode, d.TitleEs, d.TitleEn, d.DocumentType, d.Classification
    FROM comp.ControlledDocumentRevision dr
    JOIN comp.ControlledDocument d ON d.ControlledDocumentId = dr.ControlledDocumentId
    WHERE dr.DocumentRevisionId = @DocumentRevisionId;

    SELECT da.DocumentApprovalId, da.ApprovalRole, da.ApproverUserId, u.DisplayName
         , da.Decision, da.Comments, da.RequestedAtUtc, da.DecidedAtUtc, da.SignatureId
    FROM comp.DocumentApproval da
    LEFT JOIN sec.[User] u ON u.UserId = da.ApproverUserId
    WHERE da.DocumentRevisionId = @DocumentRevisionId ORDER BY da.ApprovalRole;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Document_GetPositionMatrix
      @ActorUserId INT, @ControlledDocumentId INT = NULL, @PositionId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT  m.DocumentPositionMatrixId, m.ControlledDocumentId, d.DocumentCode, d.TitleEs
          , m.PositionId, p.PositionCode, p.[Name] AS PositionName, m.IsMandatory
          , dr.RevisionLabel AS CurrentRevision, dr.DocumentRevisionId
          , (SELECT COUNT(*) FROM org.EmployeePosition ep
             WHERE ep.PositionId = m.PositionId AND ep.EffectiveToUtc IS NULL) AS EmployeesInPosition
          , (SELECT COUNT(*) FROM comp.DocumentAcknowledgment da
             JOIN org.EmployeePosition ep2 ON ep2.EmployeeId = da.EmployeeId AND ep2.EffectiveToUtc IS NULL
             WHERE da.DocumentRevisionId = d.CurrentRevisionId AND da.IsCurrent = 1
               AND ep2.PositionId = m.PositionId) AS AcknowledgedCount
    FROM comp.DocumentPositionMatrix m
    JOIN comp.ControlledDocument d ON d.ControlledDocumentId = m.ControlledDocumentId
    JOIN org.[Position] p ON p.PositionId = m.PositionId
    LEFT JOIN comp.ControlledDocumentRevision dr ON dr.DocumentRevisionId = d.CurrentRevisionId
    WHERE (@ControlledDocumentId IS NULL OR m.ControlledDocumentId = @ControlledDocumentId)
      AND (@PositionId           IS NULL OR m.PositionId           = @PositionId)
    ORDER BY d.DocumentCode, p.[Name]
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Acknowledgment_GetPendingForEmployee
      @ActorUserId INT, @EmployeeId INT
AS
BEGIN
    SET NOCOUNT ON;
    /* Documentos vigentes exigidos por la posicion del empleado que el
       empleado aun no ha firmado. */
    SELECT  d.ControlledDocumentId, d.DocumentCode, d.TitleEs, d.TitleEn
          , dr.DocumentRevisionId, dr.RevisionLabel, dr.EffectiveAtUtc
          , dr.MinimumReadSeconds, dr.FileAssetIdEs, dr.FileAssetIdEn
          , dr.ChangeSummaryEs, m.IsMandatory
          , DATEADD(DAY, dr.ReacknowledgmentDeadlineDays, dr.EffectiveAtUtc) AS DueAtUtc
    FROM comp.DocumentPositionMatrix m
    JOIN org.EmployeePosition ep ON ep.PositionId = m.PositionId
                                AND ep.EmployeeId = @EmployeeId AND ep.EffectiveToUtc IS NULL
    JOIN comp.ControlledDocument d ON d.ControlledDocumentId = m.ControlledDocumentId AND d.IsActive = 1
    JOIN comp.ControlledDocumentRevision dr ON dr.DocumentRevisionId = d.CurrentRevisionId AND dr.[Status] = 3
    WHERE NOT EXISTS (SELECT 1 FROM comp.DocumentAcknowledgment da
                      WHERE da.DocumentRevisionId = dr.DocumentRevisionId AND da.EmployeeId = @EmployeeId)
    ORDER BY m.IsMandatory DESC, dr.EffectiveAtUtc
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Acknowledgment_GetStatus
      @ActorUserId INT, @DocumentRevisionId INT, @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* Quien firmo y quien no. Esta es la pantalla que Calidad abre el dia
       de la auditoria. */
    SELECT  e.EmployeeId, e.EmployeeCode, e.FullName, d.[Name] AS DepartmentName
          , p.[Name] AS PositionName
          , CASE WHEN da.DocumentAcknowledgmentId IS NULL THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS HasAcknowledged
          , da.AcknowledgedAtUtc, da.ReadSeconds, da.SignatureId
    FROM comp.ControlledDocumentRevision dr
    JOIN comp.DocumentPositionMatrix m ON m.ControlledDocumentId = dr.ControlledDocumentId
    JOIN org.EmployeePosition ep ON ep.PositionId = m.PositionId AND ep.EffectiveToUtc IS NULL
    JOIN org.Employee e ON e.EmployeeId = ep.EmployeeId AND e.IsActive = 1
    JOIN org.[Position] p ON p.PositionId = ep.PositionId
    LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
    LEFT JOIN comp.DocumentAcknowledgment da ON da.DocumentRevisionId = dr.DocumentRevisionId
                                            AND da.EmployeeId = e.EmployeeId
    WHERE dr.DocumentRevisionId = @DocumentRevisionId
      AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
    ORDER BY HasAcknowledged, e.FullName
    OPTION (RECOMPILE);

    SELECT  COUNT(*) AS TotalRequired
          , SUM(CASE WHEN da.DocumentAcknowledgmentId IS NOT NULL THEN 1 ELSE 0 END) AS TotalAcknowledged
    FROM comp.ControlledDocumentRevision dr
    JOIN comp.DocumentPositionMatrix m ON m.ControlledDocumentId = dr.ControlledDocumentId
    JOIN org.EmployeePosition ep ON ep.PositionId = m.PositionId AND ep.EffectiveToUtc IS NULL
    JOIN org.Employee e ON e.EmployeeId = ep.EmployeeId AND e.IsActive = 1
    LEFT JOIN comp.DocumentAcknowledgment da ON da.DocumentRevisionId = dr.DocumentRevisionId
                                            AND da.EmployeeId = e.EmployeeId
    WHERE dr.DocumentRevisionId = @DocumentRevisionId
      AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE comp.usp_Eligibility_CheckEmployeeForCompetency
      @ActorUserId INT = NULL, @EmployeeId INT, @CompetencyId INT
    , @MinimumLevelOrdinal TINYINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1)
            c.CertificationId, c.CertificateNumber, c.[Status]
          , cl.LevelOrdinal, cl.NameEs AS LevelName, c.ExpiresAtUtc
          , CASE WHEN c.[Status] IN (1, 2, 6) AND c.RevokedAtUtc IS NULL
                  AND (c.ExpiresAtUtc IS NULL OR c.ExpiresAtUtc > SYSUTCDATETIME())
                  AND (@MinimumLevelOrdinal IS NULL OR cl.LevelOrdinal >= @MinimumLevelOrdinal)
                 THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsEligible
    FROM comp.Certification c
    JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = c.CompetencyLevelId
    WHERE c.EmployeeId = @EmployeeId AND c.CompetencyId = @CompetencyId
    ORDER BY CASE c.[Status] WHEN 1 THEN 1 WHEN 2 THEN 2 WHEN 6 THEN 3 ELSE 9 END
           , cl.LevelOrdinal DESC, c.IssuedAtUtc DESC;
    RETURN 0;
END;
GO

/* "Quien puede cubrir esta estacion ahora mismo" - la pregunta que hace
   el supervisor a las 6am cuando falta gente. */
CREATE OR ALTER PROCEDURE comp.usp_Eligibility_GetQualifiedEmployees
      @ActorUserId INT, @StationId INT = NULL, @CompetencyId INT = NULL
    , @MinimumLevelOrdinal TINYINT = NULL, @SiteId INT = NULL
    , @ShiftCode NVARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @StationId IS NULL AND @CompetencyId IS NULL
        THROW 50010, 'Debe indicar StationId o CompetencyId.', 1;

    SELECT  e.EmployeeId, e.EmployeeCode, e.FullName, e.ShiftCode
          , d.[Name] AS DepartmentName, a.[Name] AS AreaName
          , MIN(cl.LevelOrdinal) AS LowestLevelHeld
          , MIN(c.ExpiresAtUtc)  AS EarliestExpiry
    FROM org.Employee e
    LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
    LEFT JOIN org.Area a ON a.AreaId = e.AreaId
    JOIN comp.Certification c ON c.EmployeeId = e.EmployeeId
                             AND c.[Status] IN (1, 2) AND c.RevokedAtUtc IS NULL
                             AND (c.ExpiresAtUtc IS NULL OR c.ExpiresAtUtc > SYSUTCDATETIME())
    JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = c.CompetencyLevelId
    WHERE e.IsActive = 1
      AND (@SiteId    IS NULL OR e.SiteId    = @SiteId)
      AND (@ShiftCode IS NULL OR e.ShiftCode = @ShiftCode)
      AND (@CompetencyId IS NULL OR c.CompetencyId = @CompetencyId)
      AND (@MinimumLevelOrdinal IS NULL OR cl.LevelOrdinal >= @MinimumLevelOrdinal)
      AND (@StationId IS NULL OR c.CompetencyId IN (
                SELECT r.CompetencyId FROM comp.StationCompetency sc
                JOIN comp.CompetencyRequirement r ON r.RequirementId = sc.RequirementId
                WHERE sc.StationId = @StationId AND sc.IsBlocking = 1))
    GROUP BY e.EmployeeId, e.EmployeeCode, e.FullName, e.ShiftCode, d.[Name], a.[Name]
    HAVING @StationId IS NULL
        OR COUNT(DISTINCT c.CompetencyId) = (
                SELECT COUNT(DISTINCT r.CompetencyId) FROM comp.StationCompetency sc
                JOIN comp.CompetencyRequirement r ON r.RequirementId = sc.RequirementId
                WHERE sc.StationId = @StationId AND sc.IsBlocking = 1)
    ORDER BY e.FullName
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

PRINT '=== 15_procs_compliance.sql completado ===';
GO
