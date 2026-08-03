/* =====================================================================
   Classroom - LMS by Airlink
   16_procs_reporting.sql
   Esquema: rpt (matriz de competencias, expedientes, dashboards,
            paquete de evidencia de auditoria)

   Estos SPs son de LECTURA. El principal usuario no es un gerente
   mirando graficos bonitos: es Calidad armando el paquete que se le
   entrega al auditor de ISO 9001 o al de R2v3.

   Regla: todo SP de este archivo registra el acceso en aud.DataAccessLog
   cuando devuelve datos personales. Saber quien exporto el expediente de
   quien tambien es parte del control.

   Codigos de error de este archivo: 50001-50099 (genericos)
   ===================================================================== */

USE AIRLINK_LMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 16_procs_reporting.sql iniciado ===';
GO

/* =====================================================================
   rpt.usp_CompetencyMatrix_Get     -- GAP-01

   La matriz de competencias es el entregable #1 de ISO 9001 cl.7.2.
   Filas = empleados, columnas = competencias, celda = estado.
   Devuelve formato largo (una fila por celda); el pivote lo hace el
   cliente, que sabe cuantas columnas caben en pantalla.
   ===================================================================== */
CREATE OR ALTER PROCEDURE rpt.usp_CompetencyMatrix_Get
      @ActorUserId    INT
    , @SiteId         INT = NULL
    , @DepartmentId   INT = NULL
    , @AreaId         INT = NULL
    , @PositionId     INT = NULL
    , @CompetencyId   INT = NULL
    , @CompetencyType TINYINT = NULL
    , @OnlyGaps       BIT = 0
    , @OnlyCritical   BIT = 0
    , @AsOfUtc        DATETIME2(3) = NULL
    , @PageNumber     INT = 1
    , @PageSize       INT = 200
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'report.competencymatrix') = 0
            THROW 50002, 'El usuario no tiene permiso para ver la matriz de competencias.', 1;

        IF @PageSize > 2000 SET @PageSize = 2000;   -- la matriz es grande por naturaleza

        /* La vista rpt.vw_CompetencyMatrix ya resuelve el estado por celda.
           @AsOfUtc queda documentado aqui pero se atiende por
           rpt.usp_AsOfDate_GetComplianceSnapshot, que consulta las tablas
           temporales. Mezclar ambos caminos en un solo SP hace el plan
           impredecible. */
        IF @AsOfUtc IS NOT NULL
        BEGIN
            EXEC rpt.usp_AsOfDate_GetComplianceSnapshot
                  @ActorUserId = @ActorUserId, @AsOfUtc = @AsOfUtc
                , @DepartmentId = @DepartmentId, @SiteId = @SiteId;
            RETURN 0;
        END;

        /* Resultset 1: celdas */
        SELECT  m.EmployeeId, m.EmployeeCode, m.EmployeeName
              , m.DepartmentId, m.DepartmentName, m.AreaId, m.AreaName
              , m.PositionCode, m.PositionName
              , m.RequirementId, m.CompetencyId, m.CompetencyCode, m.CompetencyNameEs
              , m.CompetencyType
              , m.RequiredLevelOrdinal, m.RequiredLevelName
              , m.CurrentLevelOrdinal, m.CurrentLevelName
              , m.CertificationId, m.ExpiresAtUtc, m.DaysUntilExpiry
              , m.Criticality, m.RegulatoryBasis, m.HasActiveWaiver
              , m.MatrixStatus
        FROM rpt.vw_CompetencyMatrix m
        WHERE (@SiteId         IS NULL OR m.SiteId         = @SiteId)
          AND (@DepartmentId   IS NULL OR m.DepartmentId   = @DepartmentId)
          AND (@AreaId         IS NULL OR m.AreaId         = @AreaId)
          AND (@CompetencyId   IS NULL OR m.CompetencyId   = @CompetencyId)
          AND (@CompetencyType IS NULL OR m.CompetencyType = @CompetencyType)
          AND (@PositionId     IS NULL OR EXISTS (SELECT 1 FROM org.EmployeePosition ep
                                                  WHERE ep.EmployeeId = m.EmployeeId
                                                    AND ep.PositionId = @PositionId
                                                    AND ep.EffectiveToUtc IS NULL))
          AND (@OnlyCritical = 0 OR m.Criticality = 1)
          AND (@OnlyGaps     = 0 OR m.MatrixStatus <> 1)
        ORDER BY m.DepartmentName, m.EmployeeName, m.CompetencyCode
        OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
        OPTION (RECOMPILE);

        /* Resultset 2: resumen para el semaforo del encabezado */
        SELECT  COUNT(*) AS TotalCells
              , COUNT(DISTINCT m.EmployeeId) AS Employees
              , COUNT(DISTINCT m.CompetencyId) AS Competencies
              , SUM(CASE WHEN m.MatrixStatus = 1 THEN 1 ELSE 0 END) AS Compliant
              , SUM(CASE WHEN m.MatrixStatus <> 1 THEN 1 ELSE 0 END) AS NonCompliant
              , SUM(CASE WHEN m.MatrixStatus <> 1 AND m.Criticality = 1 THEN 1 ELSE 0 END) AS CriticalGaps
              , CAST(100.0 * SUM(CASE WHEN m.MatrixStatus = 1 THEN 1 ELSE 0 END)
                     / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS CompliancePercent
        FROM rpt.vw_CompetencyMatrix m
        WHERE (@SiteId         IS NULL OR m.SiteId         = @SiteId)
          AND (@DepartmentId   IS NULL OR m.DepartmentId   = @DepartmentId)
          AND (@AreaId         IS NULL OR m.AreaId         = @AreaId)
          AND (@CompetencyId   IS NULL OR m.CompetencyId   = @CompetencyId)
          AND (@CompetencyType IS NULL OR m.CompetencyType = @CompetencyType)
          AND (@OnlyCritical = 0 OR m.Criticality = 1)
        OPTION (RECOMPILE);

        EXEC aud.usp_DataAccess_Log
              @ActorUserId = @ActorUserId, @AccessType = 1
            , @EntityType = N'CompetencyMatrix', @Purpose = N'MatrixReview';

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'rpt.usp_CompetencyMatrix_Get', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   rpt.usp_TrainingRecord_GetForEmployee

   El expediente de entrenamiento de una persona. Lo pide el auditor
   cuando escoge un operador al azar del piso y dice "muestrame su
   expediente". Tiene que salir completo y en un solo tiro.
   ===================================================================== */
CREATE OR ALTER PROCEDURE rpt.usp_TrainingRecord_GetForEmployee
      @ActorUserId  INT
    , @EmployeeId   INT           = NULL
    , @EmployeeCode NVARCHAR(30)  = NULL
    , @FromUtc      DATETIME2(3)  = NULL
    , @ToUtc        DATETIME2(3)  = NULL
    , @ForExport    BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        /* Sin empleado explicito, el expediente es el del propio actor. */
        IF @EmployeeId IS NULL AND @EmployeeCode IS NULL
            SELECT @EmployeeId = EmployeeId FROM sec.[User] WHERE UserId = @ActorUserId;

        SELECT @EmployeeId = COALESCE(@EmployeeId, e.EmployeeId)
        FROM org.Employee e WHERE @EmployeeCode IS NOT NULL AND e.EmployeeCode = @EmployeeCode;

        IF @EmployeeId IS NULL THROW 50501, 'Empleado no encontrado.', 1;

        /* Un empleado siempre puede ver su propio expediente. */
        IF NOT EXISTS (SELECT 1 FROM sec.[User] u WHERE u.UserId = @ActorUserId AND u.EmployeeId = @EmployeeId)
           AND sec.fn_UserHasPermission(@ActorUserId, N'report.trainingrecord') = 0
            THROW 50002, 'El usuario no tiene permiso para ver este expediente.', 1;

        SET @FromUtc = ISNULL(@FromUtc, '1900-01-01');
        SET @ToUtc   = ISNULL(@ToUtc, SYSUTCDATETIME());

        /* 1. Identificacion */
        SELECT  e.EmployeeId, e.EmployeeCode, e.FullName, e.NationalIdMasked
              , e.HireDateUtc, e.EmploymentType, e.IsActive
              , s.[Name] AS SiteName, d.[Name] AS DepartmentName, a.[Name] AS AreaName
              , p.PositionCode, p.[Name] AS PositionName, p.AffectsProductQuality
              , sup.FullName AS SupervisorName
        FROM org.Employee e
        LEFT JOIN org.Site s ON s.SiteId = e.SiteId
        LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
        LEFT JOIN org.Area a ON a.AreaId = e.AreaId
        LEFT JOIN org.[Position] p ON p.PositionId = e.PrimaryPositionId
        LEFT JOIN org.Employee sup ON sup.EmployeeId = e.SupervisorEmployeeId
        WHERE e.EmployeeId = @EmployeeId;

        /* 2. Historial de posiciones: contexto de por que se le exigio que */
        SELECT ep.PositionId, p.PositionCode, p.[Name] AS PositionName
             , ep.IsPrimary, ep.EffectiveFromUtc, ep.EffectiveToUtc
        FROM org.EmployeePosition ep
        JOIN org.[Position] p ON p.PositionId = ep.PositionId
        WHERE ep.EmployeeId = @EmployeeId ORDER BY ep.EffectiveFromUtc DESC;

        /* 3. Certificaciones */
        SELECT  c.CertificationId, c.CertificateNumber, c.CompetencyId
              , cm.CompetencyCode, cm.NameEs AS CompetencyName, cm.CompetencyType
              , cl.LevelOrdinal, cl.NameEs AS LevelName
              , c.[Status], c.IssuedAtUtc, c.EvidenceCompletedAtUtc, c.ExpiresAtUtc
              , c.RevokedAtUtc, c.RevokeReason
              , r.RegulatoryBasis, r.Criticality
              , c.SignatureId, sig.PayloadHash, sig.SignedAtUtc
        FROM comp.Certification c
        JOIN comp.Competency cm ON cm.CompetencyId = c.CompetencyId
        JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = c.CompetencyLevelId
        LEFT JOIN comp.CompetencyRequirement r ON r.RequirementId = c.RequirementId
        LEFT JOIN aud.SignatureRecord sig ON sig.SignatureId = c.SignatureId
        WHERE c.EmployeeId = @EmployeeId
          AND c.IssuedAtUtc BETWEEN @FromUtc AND @ToUtc
        ORDER BY c.IssuedAtUtc DESC;

        /* 4. Cursos e inscripciones */
        SELECT  tr.EnrollmentId, tr.CourseCode, tr.CourseNameEs, tr.DeliveryType
              , tr.VersionLabel, tr.EnrollmentSource, tr.EnrollmentStatus
              , tr.AttemptNumber, tr.AssignedAtUtc, tr.DueAtUtc
              , tr.StartedAtUtc, tr.CompletedAtUtc, tr.ScorePercent, tr.IsPassed
        FROM rpt.vw_TrainingRecord tr
        WHERE tr.EmployeeId = @EmployeeId
          AND tr.AssignedAtUtc BETWEEN @FromUtc AND @ToUtc
        ORDER BY tr.AssignedAtUtc DESC;

        /* 5. Sesiones presenciales asistidas */
        SELECT  s.TrainingSessionId, s.SessionCode, s.TitleEs
              , s.ScheduledStartUtc, s.ActualStartUtc, s.ActualEndUtc
              , i.FullName AS InstructorName
              , at.AttendanceStatus, at.MinutesAttended, at.ResultCode
              , at.ParticipantSignatureId, s.RosterSignatureId
        FROM dlv.SessionAttendance at
        JOIN dlv.TrainingSession s ON s.TrainingSessionId = at.TrainingSessionId
        JOIN org.Employee i ON i.EmployeeId = s.InstructorEmployeeId
        WHERE at.EmployeeId = @EmployeeId
          AND s.ScheduledStartUtc BETWEEN @FromUtc AND @ToUtc
        ORDER BY s.ScheduledStartUtc DESC;

        /* 6. Evaluaciones practicas (OJT) */
        SELECT  pa.PracticalAssessmentId, t.TemplateCode, t.NameEs AS TemplateName
              , pa.AttemptNumber, pa.[Status], pa.ScorePercent, pa.IsPassed
              , pa.CriticalFailureCount, pa.SubmittedAtUtc
              , ev.DisplayName AS EvaluatorName
              , pa.EvaluatorSignatureId, pa.EmployeeSignatureId
              , st.StationCode
        FROM asmt.PracticalAssessment pa
        JOIN asmt.PracticalAssessmentTemplate t ON t.PracticalTemplateId = pa.PracticalTemplateId
        LEFT JOIN sec.[User] ev ON ev.UserId = pa.EvaluatorUserId
        LEFT JOIN org.Station st ON st.StationId = pa.StationId
        WHERE pa.EmployeeId = @EmployeeId
          AND pa.StartedAtUtc BETWEEN @FromUtc AND @ToUtc
        ORDER BY pa.StartedAtUtc DESC;

        /* 7. Intentos de evaluacion escrita */
        SELECT  qa.QuizAttemptId, q.TitleEs AS QuizTitle, qa.AttemptNumber
              , qa.[Status], qa.ScorePercent, qa.IsPassed
              , qa.StartedAtUtc, qa.SubmittedAtUtc, qa.TimeSpentSeconds
        FROM asmt.QuizAttempt qa
        JOIN asmt.Quiz q ON q.QuizId = qa.QuizId
        WHERE qa.EmployeeId = @EmployeeId
          AND qa.StartedAtUtc BETWEEN @FromUtc AND @ToUtc
        ORDER BY qa.StartedAtUtc DESC;

        /* 8. Documentos controlados firmados */
        SELECT  d.DocumentCode, d.TitleEs, dr.RevisionLabel, dr.EffectiveAtUtc
              , da.AcknowledgedAtUtc, da.ReadSeconds, da.LocaleCode
              , da.IsCurrent, da.SignatureId, sig.PayloadHash
        FROM comp.DocumentAcknowledgment da
        JOIN comp.ControlledDocumentRevision dr ON dr.DocumentRevisionId = da.DocumentRevisionId
        JOIN comp.ControlledDocument d ON d.ControlledDocumentId = dr.ControlledDocumentId
        LEFT JOIN aud.SignatureRecord sig ON sig.SignatureId = da.SignatureId
        WHERE da.EmployeeId = @EmployeeId
          AND da.AcknowledgedAtUtc BETWEEN @FromUtc AND @ToUtc
        ORDER BY da.AcknowledgedAtUtc DESC;

        /* 9. Brechas abiertas */
        SELECT  g.RequirementId, r.RequirementCode, cm.CompetencyCode, cm.NameEs AS CompetencyName
              , g.GapType, g.Severity, g.CurrentLevelOrdinal, g.RequiredLevelOrdinal
              , g.ExpiresAtUtc, g.DaysUntilExpiry, g.HasActiveWaiver
              , g.RemediationEnrollmentId, g.DetectedAtUtc
        FROM comp.CompetencyGap g
        JOIN comp.CompetencyRequirement r ON r.RequirementId = g.RequirementId
        JOIN comp.Competency cm ON cm.CompetencyId = g.CompetencyId
        WHERE g.EmployeeId = @EmployeeId AND g.ResolvedAtUtc IS NULL
        ORDER BY g.Severity, cm.CompetencyCode;

        /* 10. Waivers */
        SELECT  w.WaiverId, r.RequirementCode, cm.NameEs AS CompetencyName
              , w.WaiverType, w.[Status], w.Justification, w.RequiresSupervision
              , w.ApprovedAtUtc, w.EffectiveFromUtc, w.ExpiresAtUtc
              , app.DisplayName AS ApprovedByName
        FROM comp.Waiver w
        JOIN comp.CompetencyRequirement r ON r.RequirementId = w.RequirementId
        JOIN comp.Competency cm ON cm.CompetencyId = r.CompetencyId
        LEFT JOIN sec.[User] app ON app.UserId = w.ApprovedByUserId
        WHERE w.EmployeeId = @EmployeeId
        ORDER BY w.RequestedAtUtc DESC;

        DECLARE @AccessType TINYINT = CASE WHEN @ForExport = 1 THEN 2 ELSE 1 END
              , @AccessPurpose NVARCHAR(50) = CASE WHEN @ForExport = 1 THEN N'RecordExport' ELSE N'RecordReview' END;
        EXEC aud.usp_DataAccess_Log
              @ActorUserId = @ActorUserId
            , @AccessType  = @AccessType
            , @EntityType  = N'TrainingRecord'
            , @SubjectEmployeeId = @EmployeeId
            , @RecordCount = 1
            , @Purpose = @AccessPurpose;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'rpt.usp_TrainingRecord_GetForEmployee', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   rpt.usp_AuditEvidence_GetScope / GeneratePackage    -- GAP-07

   El auditor define un alcance (sitio, departamento, periodo, norma) y
   el sistema arma el paquete completo. Lo que antes tomaba dos semanas
   de Excel manual sale en un boton.

   GetScope         -> conteos previos, para que Calidad revise el
                       alcance antes de generar (y sepa si va a tardar).
   GeneratePackage  -> los resultsets que alimentan el ZIP/PDF final.
   ===================================================================== */
CREATE OR ALTER PROCEDURE rpt.usp_AuditEvidence_GetScope
      @ActorUserId     INT
    , @SiteId          INT = NULL
    , @DepartmentId    INT = NULL
    , @FromUtc         DATETIME2(3)
    , @ToUtc           DATETIME2(3)
    , @RegulatoryBasis NVARCHAR(200) = NULL   -- 'ISO 9001', 'R2v3', NULL = todo
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'report.auditpackage') = 0
            THROW 50002, 'El usuario no tiene permiso para generar paquetes de auditoria.', 1;

        SELECT
              (SELECT COUNT(*) FROM org.Employee e
               WHERE e.IsActive = 1
                 AND (@SiteId IS NULL OR e.SiteId = @SiteId)
                 AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)) AS EmployeesInScope
            , (SELECT COUNT(*) FROM comp.Certification c
               JOIN org.Employee e ON e.EmployeeId = c.EmployeeId
               LEFT JOIN comp.CompetencyRequirement r ON r.RequirementId = c.RequirementId
               WHERE c.IssuedAtUtc BETWEEN @FromUtc AND @ToUtc
                 AND (@SiteId IS NULL OR e.SiteId = @SiteId)
                 AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
                 AND (@RegulatoryBasis IS NULL OR r.RegulatoryBasis LIKE N'%' + @RegulatoryBasis + N'%')) AS CertificationsIssued
            , (SELECT COUNT(*) FROM dlv.Enrollment en
               JOIN org.Employee e ON e.EmployeeId = en.EmployeeId
               WHERE en.CompletedAtUtc BETWEEN @FromUtc AND @ToUtc
                 AND (@SiteId IS NULL OR e.SiteId = @SiteId)
                 AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)) AS TrainingsCompleted
            , (SELECT COUNT(*) FROM dlv.TrainingSession s
               WHERE s.ScheduledStartUtc BETWEEN @FromUtc AND @ToUtc AND s.[Status] = 5
                 AND (@SiteId IS NULL OR s.SiteId = @SiteId)) AS SessionsDelivered
            , (SELECT COUNT(*) FROM comp.DocumentAcknowledgment da
               JOIN org.Employee e ON e.EmployeeId = da.EmployeeId
               WHERE da.AcknowledgedAtUtc BETWEEN @FromUtc AND @ToUtc
                 AND (@SiteId IS NULL OR e.SiteId = @SiteId)
                 AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)) AS DocumentAcknowledgments
            , (SELECT COUNT(*) FROM aud.SignatureRecord sr
               WHERE sr.SignedAtUtc BETWEEN @FromUtc AND @ToUtc) AS SignaturesInPeriod
            , (SELECT COUNT(*) FROM comp.CompetencyGap g
               JOIN org.Employee e ON e.EmployeeId = g.EmployeeId AND e.IsActive = 1
               WHERE g.ResolvedAtUtc IS NULL AND g.HasActiveWaiver = 0
                 AND (@SiteId IS NULL OR e.SiteId = @SiteId)
                 AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)) AS OpenGaps
            , (SELECT COUNT(*) FROM comp.Waiver w
               JOIN org.Employee e ON e.EmployeeId = w.EmployeeId
               WHERE w.[Status] = 2 AND w.RevokedAtUtc IS NULL
                 AND (@SiteId IS NULL OR e.SiteId = @SiteId)
                 AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)) AS ActiveWaivers;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'rpt.usp_AuditEvidence_GetScope', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE rpt.usp_AuditEvidence_GeneratePackage
      @ActorUserId     INT
    , @SiteId          INT = NULL
    , @DepartmentId    INT = NULL
    , @FromUtc         DATETIME2(3)
    , @ToUtc           DATETIME2(3)
    , @RegulatoryBasis NVARCHAR(200) = NULL
    , @IncludeSignatureVerification BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'report.auditpackage') = 0
            THROW 50002, 'El usuario no tiene permiso para generar paquetes de auditoria.', 1;

        DECLARE @GeneratedAtUtc DATETIME2(3) = SYSUTCDATETIME();

        /* 1. Portada: quien genero, cuando, con que alcance. El auditor
              lo primero que pregunta es de donde salio este documento. */
        SELECT  @GeneratedAtUtc AS GeneratedAtUtc
              , u.DisplayName   AS GeneratedByName
              , u.Email         AS GeneratedByEmail
              , @FromUtc AS PeriodFromUtc, @ToUtc AS PeriodToUtc
              , s.[Name] AS SiteName, d.[Name] AS DepartmentName
              , @RegulatoryBasis AS RegulatoryScope
              , DB_NAME() AS SourceDatabase
              , N'Classroom - LMS by Airlink' AS SourceSystem
        FROM sec.[User] u
        LEFT JOIN org.Site s ON s.SiteId = @SiteId
        LEFT JOIN org.Department d ON d.DepartmentId = @DepartmentId
        WHERE u.UserId = @ActorUserId;

        /* 2. Matriz de competencias del alcance */
        SELECT  m.EmployeeCode, m.EmployeeName, m.DepartmentName, m.AreaName
              , m.PositionCode, m.PositionName
              , m.CompetencyCode, m.CompetencyNameEs
              , m.RequiredLevelName, m.CurrentLevelName
              , m.MatrixStatus, m.ExpiresAtUtc, m.DaysUntilExpiry
              , m.Criticality, m.RegulatoryBasis, m.HasActiveWaiver
        FROM rpt.vw_CompetencyMatrix m
        WHERE (@SiteId IS NULL OR m.SiteId = @SiteId)
          AND (@DepartmentId IS NULL OR m.DepartmentId = @DepartmentId)
          AND (@RegulatoryBasis IS NULL OR m.RegulatoryBasis LIKE N'%' + @RegulatoryBasis + N'%')
        ORDER BY m.DepartmentName, m.EmployeeName, m.CompetencyCode
        OPTION (RECOMPILE);

        /* 3. Certificaciones emitidas en el periodo, con su firma */
        SELECT  c.CertificateNumber, c.EmployeeNameSnapshot, c.PositionNameSnapshot
              , e.EmployeeCode, cm.CompetencyCode, cm.NameEs AS CompetencyName
              , cl.NameEs AS LevelName
              , c.IssuedAtUtc, c.EvidenceCompletedAtUtc, c.ExpiresAtUtc, c.[Status]
              , r.RegulatoryBasis
              , iss.DisplayName AS IssuedByName
              , sig.SignatureId, sig.SequenceNumber
              , CONVERT(NVARCHAR(64), sig.PayloadHash, 2) AS PayloadHashHex
              , sig.SignedAtUtc AS SignedAtUtc
        FROM comp.Certification c
        JOIN org.Employee e ON e.EmployeeId = c.EmployeeId
        JOIN comp.Competency cm ON cm.CompetencyId = c.CompetencyId
        JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = c.CompetencyLevelId
        LEFT JOIN comp.CompetencyRequirement r ON r.RequirementId = c.RequirementId
        LEFT JOIN sec.[User] iss ON iss.UserId = c.IssuedByUserId
        LEFT JOIN aud.SignatureRecord sig ON sig.SignatureId = c.SignatureId
        WHERE c.IssuedAtUtc BETWEEN @FromUtc AND @ToUtc
          AND (@SiteId IS NULL OR e.SiteId = @SiteId)
          AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
          AND (@RegulatoryBasis IS NULL OR r.RegulatoryBasis LIKE N'%' + @RegulatoryBasis + N'%')
        ORDER BY c.IssuedAtUtc
        OPTION (RECOMPILE);

        /* 4. Sesiones presenciales con roster firmado */
        SELECT  s.SessionCode, s.TitleEs, c.CourseCode
              , i.EmployeeCode AS InstructorCode, i.FullName AS InstructorName
              , s.ScheduledStartUtc, s.ActualStartUtc, s.ActualEndUtc
              , s.LocationName, s.[Status]
              , (SELECT COUNT(*) FROM dlv.SessionAttendance a
                 WHERE a.TrainingSessionId = s.TrainingSessionId AND a.AttendanceStatus IN (1,2)) AS Attendees
              , s.RosterSignatureId
              , CONVERT(NVARCHAR(64), sig.PayloadHash, 2) AS RosterPayloadHashHex
        FROM dlv.TrainingSession s
        JOIN lms.Course c ON c.CourseId = s.CourseId
        JOIN org.Employee i ON i.EmployeeId = s.InstructorEmployeeId
        LEFT JOIN aud.SignatureRecord sig ON sig.SignatureId = s.RosterSignatureId
        WHERE s.ScheduledStartUtc BETWEEN @FromUtc AND @ToUtc
          AND s.[Status] = 5
          AND (@SiteId IS NULL OR s.SiteId = @SiteId)
        ORDER BY s.ScheduledStartUtc
        OPTION (RECOMPILE);

        /* 5. Documentos controlados y su cobertura de firma */
        SELECT  d.DocumentCode, d.TitleEs, dr.RevisionLabel, dr.EffectiveAtUtc
              , dr.[Status] AS RevisionStatus
              , (SELECT COUNT(*) FROM comp.DocumentAcknowledgment da
                 WHERE da.DocumentRevisionId = dr.DocumentRevisionId) AS AcknowledgedCount
              , (SELECT COUNT(DISTINCT ep.EmployeeId)
                 FROM comp.DocumentPositionMatrix m
                 JOIN org.EmployeePosition ep ON ep.PositionId = m.PositionId AND ep.EffectiveToUtc IS NULL
                 JOIN org.Employee e2 ON e2.EmployeeId = ep.EmployeeId AND e2.IsActive = 1
                 WHERE m.ControlledDocumentId = d.ControlledDocumentId
                   AND (@SiteId IS NULL OR e2.SiteId = @SiteId)) AS RequiredCount
        FROM comp.ControlledDocument d
        JOIN comp.ControlledDocumentRevision dr ON dr.ControlledDocumentId = d.ControlledDocumentId
        WHERE d.IsActive = 1
          AND (dr.[Status] = 3 OR dr.ActivatedAtUtc BETWEEN @FromUtc AND @ToUtc)
        ORDER BY d.DocumentCode, dr.RevisionNumber
        OPTION (RECOMPILE);

        /* 6. Brechas abiertas: la transparencia es parte de la evidencia.
              Ocultarlas es peor que tenerlas. */
        SELECT  e.EmployeeCode, e.FullName, d.[Name] AS DepartmentName
              , cm.CompetencyCode, cm.NameEs AS CompetencyName
              , g.GapType, g.Severity, g.DaysUntilExpiry
              , g.HasActiveWaiver, g.RemediationEnrollmentId
              , r.RegulatoryBasis
        FROM comp.CompetencyGap g
        JOIN org.Employee e ON e.EmployeeId = g.EmployeeId AND e.IsActive = 1
        JOIN comp.Competency cm ON cm.CompetencyId = g.CompetencyId
        JOIN comp.CompetencyRequirement r ON r.RequirementId = g.RequirementId
        LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
        WHERE g.ResolvedAtUtc IS NULL
          AND (@SiteId IS NULL OR e.SiteId = @SiteId)
          AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
          AND (@RegulatoryBasis IS NULL OR r.RegulatoryBasis LIKE N'%' + @RegulatoryBasis + N'%')
        ORDER BY g.Severity, e.FullName
        OPTION (RECOMPILE);

        /* 7. Registro de waivers: excepciones declaradas y justificadas */
        SELECT  e.EmployeeCode, e.FullName, r.RequirementCode, cm.NameEs AS CompetencyName
              , w.WaiverType, w.Justification, w.RequiresSupervision
              , req.DisplayName AS RequestedByName, app.DisplayName AS ApprovedByName
              , w.ApprovedAtUtc, w.EffectiveFromUtc, w.ExpiresAtUtc, w.[Status]
        FROM comp.Waiver w
        JOIN org.Employee e ON e.EmployeeId = w.EmployeeId
        JOIN comp.CompetencyRequirement r ON r.RequirementId = w.RequirementId
        JOIN comp.Competency cm ON cm.CompetencyId = r.CompetencyId
        LEFT JOIN sec.[User] req ON req.UserId = w.RequestedByUserId
        LEFT JOIN sec.[User] app ON app.UserId = w.ApprovedByUserId
        WHERE w.[Status] IN (2, 4, 5)
          AND (@SiteId IS NULL OR e.SiteId = @SiteId)
          AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
        ORDER BY w.ApprovedAtUtc DESC
        OPTION (RECOMPILE);

        /* 8. Integridad de la cadena de firmas del periodo.
              Esto es lo que convierte "confien en nosotros" en
              "verifiquenlo ustedes mismos". */
        IF @IncludeSignatureVerification = 1
            EXEC aud.usp_Signature_Verify @ActorUserId = @ActorUserId
               , @FromUtc = @FromUtc, @ToUtc = @ToUtc;

        EXEC aud.usp_DataAccess_Log
              @ActorUserId = @ActorUserId, @AccessType = 2
            , @EntityType = N'AuditEvidencePackage'
            , @Purpose = N'AuditPackage';

        EXEC aud.usp_Event_Log
              @EventType = N'AuditPackage.Generated', @EntityType = N'AuditPackage'
            , @ActorUserId = @ActorUserId, @Severity = 3
            , @Summary = N'Paquete de evidencia de auditoria generado.';

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'rpt.usp_AuditEvidence_GeneratePackage', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   rpt.usp_AsOfDate_GetComplianceSnapshot

   "¿Como estabamos el 12 de marzo?" Solo se puede contestar porque
   CompetencyRequirement, Certification y Enrollment son tablas
   temporales. Es la prueba de que el sistema no reescribe la historia.
   ===================================================================== */
CREATE OR ALTER PROCEDURE rpt.usp_AsOfDate_GetComplianceSnapshot
      @ActorUserId  INT
    , @AsOfUtc      DATETIME2(3)
    , @SiteId       INT = NULL
    , @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'report.competencymatrix') = 0
            THROW 50002, 'El usuario no tiene permiso para esta consulta.', 1;

        IF @AsOfUtc > SYSUTCDATETIME()
            THROW 50010, 'La fecha de corte no puede ser futura.', 1;

        /* Requisitos vigentes en esa fecha */
        SELECT  r.RequirementId, r.RequirementCode, r.CompetencyId
              , cm.CompetencyCode, cm.NameEs AS CompetencyName
              , r.ScopeType, r.ScopeId, r.Criticality, r.RegulatoryBasis, r.[Status]
        FROM comp.CompetencyRequirement FOR SYSTEM_TIME AS OF @AsOfUtc r
        JOIN comp.Competency cm ON cm.CompetencyId = r.CompetencyId
        WHERE r.[Status] = 1
        ORDER BY r.Criticality, cm.CompetencyCode;

        /* Certificaciones vigentes en esa fecha */
        SELECT  c.CertificationId, c.CertificateNumber, c.EmployeeId
              , e.EmployeeCode, c.EmployeeNameSnapshot
              , cm.CompetencyCode, c.[Status], c.IssuedAtUtc, c.ExpiresAtUtc
              , CASE WHEN c.ExpiresAtUtc IS NULL OR c.ExpiresAtUtc > @AsOfUtc
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS WasValidAtDate
        FROM comp.Certification FOR SYSTEM_TIME AS OF @AsOfUtc c
        JOIN org.Employee e ON e.EmployeeId = c.EmployeeId
        JOIN comp.Competency cm ON cm.CompetencyId = c.CompetencyId
        WHERE (@SiteId IS NULL OR e.SiteId = @SiteId)
          AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
        ORDER BY e.EmployeeCode, cm.CompetencyCode
        OPTION (RECOMPILE);

        /* Resumen */
        SELECT  @AsOfUtc AS AsOfUtc
              , COUNT(*) AS CertificationsOnRecord
              , SUM(CASE WHEN c.[Status] IN (1,2,6)
                          AND (c.ExpiresAtUtc IS NULL OR c.ExpiresAtUtc > @AsOfUtc)
                         THEN 1 ELSE 0 END) AS ValidAtDate
        FROM comp.Certification FOR SYSTEM_TIME AS OF @AsOfUtc c
        JOIN org.Employee e ON e.EmployeeId = c.EmployeeId
        WHERE (@SiteId IS NULL OR e.SiteId = @SiteId)
          AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
        OPTION (RECOMPILE);

        EXEC aud.usp_DataAccess_Log
              @ActorUserId = @ActorUserId, @AccessType = 1
            , @EntityType = N'ComplianceSnapshot', @Purpose = N'HistoricalQuery';
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'rpt.usp_AsOfDate_GetComplianceSnapshot', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Dashboards
   ===================================================================== */
CREATE OR ALTER PROCEDURE rpt.usp_Dashboard_GetLearner
      @ActorUserId INT, @EmployeeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @EmployeeId = COALESCE(@EmployeeId, EmployeeId) FROM sec.[User] WHERE UserId = @ActorUserId;
    IF @EmployeeId IS NULL THROW 50501, 'Empleado no encontrado.', 1;

    /* Tarjetas */
    SELECT
          (SELECT COUNT(*) FROM dlv.Enrollment WHERE EmployeeId = @EmployeeId AND [Status] IN (1,2)) AS ActiveEnrollments
        , (SELECT COUNT(*) FROM dlv.Enrollment WHERE EmployeeId = @EmployeeId AND [Status] IN (1,2)
             AND DueAtUtc IS NOT NULL AND DueAtUtc < SYSUTCDATETIME()) AS OverdueEnrollments
        , (SELECT COUNT(*) FROM comp.Certification WHERE EmployeeId = @EmployeeId
             AND [Status] IN (1,2) AND RevokedAtUtc IS NULL) AS ValidCertifications
        , (SELECT COUNT(*) FROM comp.Certification WHERE EmployeeId = @EmployeeId AND [Status] = 2) AS ExpiringSoon
        , (SELECT COUNT(*) FROM comp.CompetencyGap WHERE EmployeeId = @EmployeeId
             AND ResolvedAtUtc IS NULL AND HasActiveWaiver = 0) AS OpenGaps
        , (SELECT COUNT(*) FROM comp.DocumentPositionMatrix m
           JOIN org.EmployeePosition ep ON ep.PositionId = m.PositionId
                                       AND ep.EmployeeId = @EmployeeId AND ep.EffectiveToUtc IS NULL
           JOIN comp.ControlledDocument d ON d.ControlledDocumentId = m.ControlledDocumentId AND d.IsActive = 1
           WHERE NOT EXISTS (SELECT 1 FROM comp.DocumentAcknowledgment da
                             WHERE da.DocumentRevisionId = d.CurrentRevisionId
                               AND da.EmployeeId = @EmployeeId)) AS PendingAcknowledgments;

    /* Continuar donde quedo */
    SELECT TOP (5) e.EnrollmentId, c.CourseCode, c.NameEs AS CourseName
         , e.ProgressPercent, e.DueAtUtc, e.LastAccessedAtUtc, e.LastAccessedItemId
    FROM dlv.Enrollment e JOIN lms.Course c ON c.CourseId = e.CourseId
    WHERE e.EmployeeId = @EmployeeId AND e.[Status] = 2
    ORDER BY e.LastAccessedAtUtc DESC;

    /* Proximas sesiones presenciales */
    SELECT TOP (5) s.TrainingSessionId, s.SessionCode, s.TitleEs
         , s.ScheduledStartUtc, s.LocationName, r.[Status] AS RegistrationStatus
    FROM dlv.SessionRegistration r
    JOIN dlv.TrainingSession s ON s.TrainingSessionId = r.TrainingSessionId
    WHERE r.EmployeeId = @EmployeeId AND r.[Status] IN (1,2,3)
      AND s.ScheduledStartUtc > SYSUTCDATETIME()
    ORDER BY s.ScheduledStartUtc;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE rpt.usp_Dashboard_GetSupervisor
      @ActorUserId INT, @SupervisorEmployeeId INT = NULL, @IncludeIndirect BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @SupervisorEmployeeId = COALESCE(@SupervisorEmployeeId, EmployeeId)
    FROM sec.[User] WHERE UserId = @ActorUserId;

    DECLARE @Team TABLE (EmployeeId INT PRIMARY KEY);
    INSERT INTO @Team SELECT EmployeeId FROM org.fn_GetTeamEmployeeIds(@SupervisorEmployeeId, @IncludeIndirect);

    SELECT
          (SELECT COUNT(*) FROM @Team) AS TeamSize
        , (SELECT COUNT(*) FROM comp.CompetencyGap g JOIN @Team t ON t.EmployeeId = g.EmployeeId
             WHERE g.ResolvedAtUtc IS NULL AND g.HasActiveWaiver = 0) AS TeamOpenGaps
        , (SELECT COUNT(*) FROM comp.CompetencyGap g JOIN @Team t ON t.EmployeeId = g.EmployeeId
             WHERE g.ResolvedAtUtc IS NULL AND g.Severity = 1 AND g.HasActiveWaiver = 0) AS TeamCriticalGaps
        , (SELECT COUNT(*) FROM dlv.Enrollment e JOIN @Team t ON t.EmployeeId = e.EmployeeId
             WHERE e.[Status] IN (1,2) AND e.DueAtUtc < SYSUTCDATETIME()) AS TeamOverdue
        , (SELECT COUNT(*) FROM comp.Certification c JOIN @Team t ON t.EmployeeId = c.EmployeeId
             WHERE c.[Status] = 2) AS TeamExpiringSoon;

    /* Lista accionable ordenada por urgencia real */
    SELECT  e.EmployeeId, e.EmployeeCode, e.FullName
          , SUM(CASE WHEN g.Severity = 1 THEN 1 ELSE 0 END) AS CriticalGaps
          , COUNT(g.CompetencyGapId) AS TotalGaps
          , MIN(g.DaysUntilExpiry) AS SoonestExpiryDays
    FROM @Team t
    JOIN org.Employee e ON e.EmployeeId = t.EmployeeId AND e.IsActive = 1
    LEFT JOIN comp.CompetencyGap g ON g.EmployeeId = e.EmployeeId
                                  AND g.ResolvedAtUtc IS NULL AND g.HasActiveWaiver = 0
    GROUP BY e.EmployeeId, e.EmployeeCode, e.FullName
    ORDER BY CriticalGaps DESC, TotalGaps DESC, e.FullName;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE rpt.usp_Dashboard_GetExecutive
      @ActorUserId INT, @SiteId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'report.executive') = 0
        THROW 50002, 'El usuario no tiene permiso para el tablero ejecutivo.', 1;

    /* Cumplimiento global */
    SELECT  COUNT(*) AS TotalCells
          , CAST(100.0 * SUM(CASE WHEN MatrixStatus = 1 THEN 1 ELSE 0 END)
                 / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS OverallCompliancePercent
          , SUM(CASE WHEN MatrixStatus <> 1 AND Criticality = 1 THEN 1 ELSE 0 END) AS CriticalGaps
    FROM rpt.vw_CompetencyMatrix
    WHERE (@SiteId IS NULL OR SiteId = @SiteId)
    OPTION (RECOMPILE);

    /* Por departamento */
    SELECT  DepartmentId, DepartmentName
          , COUNT(DISTINCT EmployeeId) AS Employees
          , CAST(100.0 * SUM(CASE WHEN MatrixStatus = 1 THEN 1 ELSE 0 END)
                 / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS CompliancePercent
          , SUM(CASE WHEN MatrixStatus <> 1 AND Criticality = 1 THEN 1 ELSE 0 END) AS CriticalGaps
    FROM rpt.vw_CompetencyMatrix
    WHERE (@SiteId IS NULL OR SiteId = @SiteId)
    GROUP BY DepartmentId, DepartmentName
    ORDER BY CompliancePercent
    OPTION (RECOMPILE);

    /* Vencimientos proximos por ventana */
    SELECT  CASE WHEN DaysUntilExpiry <= 7  THEN N'0-7 dias'
                 WHEN DaysUntilExpiry <= 30 THEN N'8-30 dias'
                 WHEN DaysUntilExpiry <= 60 THEN N'31-60 dias'
                 ELSE N'61-90 dias' END AS Bucket
          , COUNT(*) AS Certifications
    FROM comp.Certification c
    JOIN org.Employee e ON e.EmployeeId = c.EmployeeId AND e.IsActive = 1
    CROSS APPLY (SELECT DATEDIFF(DAY, SYSUTCDATETIME(), c.ExpiresAtUtc) AS DaysUntilExpiry) x
    WHERE c.[Status] IN (1,2) AND c.ExpiresAtUtc IS NOT NULL
      AND x.DaysUntilExpiry BETWEEN 0 AND 90
      AND (@SiteId IS NULL OR e.SiteId = @SiteId)
    GROUP BY CASE WHEN DaysUntilExpiry <= 7  THEN N'0-7 dias'
                  WHEN DaysUntilExpiry <= 30 THEN N'8-30 dias'
                  WHEN DaysUntilExpiry <= 60 THEN N'31-60 dias'
                  ELSE N'61-90 dias' END
    OPTION (RECOMPILE);

    /* Salud operativa del gating: si el shadow mode esta bloqueando mucho,
       o los datos estan malos o el piso esta trabajando sin certificar. */
    SELECT  GatingMode
          , COUNT(*) AS Decisions
          , SUM(CASE WHEN Decision = 3 THEN 1 ELSE 0 END) AS WouldBlock
          , SUM(CASE WHEN WasEnforced = 1 THEN 1 ELSE 0 END) AS ActuallyBlocked
          , CAST(100.0 * SUM(CASE WHEN Decision = 3 THEN 1 ELSE 0 END)
                 / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS BlockRatePercent
    FROM comp.GatingDecisionLog
    WHERE EvaluatedAtUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
    GROUP BY GatingMode
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

/* =====================================================================
   Reportes de apoyo
   ===================================================================== */
CREATE OR ALTER PROCEDURE rpt.usp_ComplianceByDepartment_Get
      @ActorUserId INT, @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* La vista ya viene agregada por departamento. Ordenada de peor a
       mejor a proposito: lo primero que se ve es donde duele. */
    SELECT * FROM rpt.vw_ComplianceByDepartment
    WHERE (@DepartmentId IS NULL OR DepartmentId = @DepartmentId)
    ORDER BY CompliancePercent, CriticalGapCount DESC
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE rpt.usp_ExpiringCertifications_Get
      @ActorUserId INT, @WithinDays INT = 60, @SiteId INT = NULL, @DepartmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC comp.usp_Certification_GetExpiring
          @ActorUserId = @ActorUserId, @WithinDays = @WithinDays
        , @DepartmentId = @DepartmentId, @SiteId = @SiteId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE rpt.usp_DocumentAcknowledgment_Get
      @ActorUserId INT, @ControlledDocumentId INT = NULL
    , @DocumentRevisionId INT = NULL, @OnlyIncomplete BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    /* Cobertura agregada por documento x posicion. Para ver nombre por
       nombre, usar comp.usp_Acknowledgment_GetStatus. */
    SELECT * FROM rpt.vw_DocumentAcknowledgmentStatus
    WHERE (@ControlledDocumentId IS NULL OR ControlledDocumentId = @ControlledDocumentId)
      AND (@DocumentRevisionId   IS NULL OR DocumentRevisionId   = @DocumentRevisionId)
      AND (@OnlyIncomplete = 0 OR PendingCount > 0)
    ORDER BY DocumentCode, PositionName
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

/* Efectividad del entrenamiento: ISO 9001 cl.7.2(c) pide evaluar que las
   acciones tomadas fueron eficaces. No basta con "se dio el curso". */
CREATE OR ALTER PROCEDURE rpt.usp_TrainingEffectiveness_Get
      @ActorUserId INT, @CourseId INT = NULL
    , @FromUtc DATETIME2(3) = NULL, @ToUtc DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @FromUtc = ISNULL(@FromUtc, DATEADD(MONTH, -12, SYSUTCDATETIME()));
    SET @ToUtc   = ISNULL(@ToUtc, SYSUTCDATETIME());

    SELECT  c.CourseId, c.CourseCode, c.NameEs AS CourseName, c.DeliveryType
          , COUNT(e.EnrollmentId) AS TotalEnrollments
          , SUM(CASE WHEN e.[Status] = 3 THEN 1 ELSE 0 END) AS Completed
          , SUM(CASE WHEN e.[Status] = 4 THEN 1 ELSE 0 END) AS Failed
          , SUM(CASE WHEN e.[Status] = 6 THEN 1 ELSE 0 END) AS Expired
          , CAST(100.0 * SUM(CASE WHEN e.[Status] = 3 THEN 1 ELSE 0 END)
                 / NULLIF(COUNT(e.EnrollmentId), 0) AS DECIMAL(5,2)) AS CompletionRatePercent
          , CAST(AVG(CASE WHEN e.[Status] = 3 THEN e.ScorePercent END) AS DECIMAL(5,2)) AS AvgScore
          , CAST(AVG(CASE WHEN e.[Status] = 3
                          THEN CAST(DATEDIFF(HOUR, e.StartedAtUtc, e.CompletedAtUtc) AS DECIMAL(9,2)) END)
                 AS DECIMAL(9,2)) AS AvgHoursToComplete
          , CAST(AVG(CAST(e.AttemptNumber AS DECIMAL(5,2))) AS DECIMAL(5,2)) AS AvgAttempts
          /* Senal de efectividad real: cuantos de los que aprobaron
             terminaron con la certificacion emitida. */
          , (SELECT COUNT(DISTINCT ce.CertificationId)
             FROM comp.CertificationEvidence ce
             JOIN dlv.Enrollment e2 ON e2.EnrollmentId = ce.EvidenceId AND ce.EvidenceType = 1
             WHERE e2.CourseId = c.CourseId AND e2.CompletedAtUtc BETWEEN @FromUtc AND @ToUtc) AS CertificationsResulting
    FROM lms.Course c
    LEFT JOIN dlv.Enrollment e ON e.CourseId = c.CourseId
                              AND e.AssignedAtUtc BETWEEN @FromUtc AND @ToUtc
    WHERE c.IsDeleted = 0 AND (@CourseId IS NULL OR c.CourseId = @CourseId)
    GROUP BY c.CourseId, c.CourseCode, c.NameEs, c.DeliveryType
    HAVING COUNT(e.EnrollmentId) > 0
    ORDER BY CompletionRatePercent
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE rpt.usp_InstructorActivity_Get
      @ActorUserId INT, @InstructorEmployeeId INT = NULL
    , @FromUtc DATETIME2(3) = NULL, @ToUtc DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @FromUtc = ISNULL(@FromUtc, DATEADD(MONTH, -6, SYSUTCDATETIME()));
    SET @ToUtc   = ISNULL(@ToUtc, SYSUTCDATETIME());

    SELECT  i.EmployeeId, i.EmployeeCode, i.FullName
          , COUNT(DISTINCT s.TrainingSessionId) AS SessionsDelivered
          , SUM(DATEDIFF(MINUTE, s.ActualStartUtc, s.ActualEndUtc)) / 60.0 AS HoursDelivered
          , COUNT(DISTINCT a.EmployeeId) AS UniqueParticipants
          , SUM(CASE WHEN a.ResultCode = 1 THEN 1 ELSE 0 END) AS ParticipantsPassed
          , COUNT(DISTINCT pa.PracticalAssessmentId) AS PracticalEvaluations
    FROM org.Employee i
    LEFT JOIN dlv.TrainingSession s ON s.InstructorEmployeeId = i.EmployeeId
                                   AND s.[Status] = 5
                                   AND s.ScheduledStartUtc BETWEEN @FromUtc AND @ToUtc
    LEFT JOIN dlv.SessionAttendance a ON a.TrainingSessionId = s.TrainingSessionId
    LEFT JOIN sec.[User] u ON u.EmployeeId = i.EmployeeId
    LEFT JOIN asmt.PracticalAssessment pa ON pa.EvaluatorUserId = u.UserId
                                         AND pa.SubmittedAtUtc BETWEEN @FromUtc AND @ToUtc
    WHERE (@InstructorEmployeeId IS NULL OR i.EmployeeId = @InstructorEmployeeId)
      AND EXISTS (SELECT 1 FROM comp.EvaluatorQualification eq
                  WHERE eq.EmployeeId = i.EmployeeId AND eq.IsActive = 1)
    GROUP BY i.EmployeeId, i.EmployeeCode, i.FullName
    ORDER BY SessionsDelivered DESC
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE rpt.usp_WaiverRegister_Get
      @ActorUserId INT, @DepartmentName NVARCHAR(150) = NULL, @OnlyActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    /* El registro de waivers es lo primero que un auditor pide cuando ve
       una matriz demasiado verde. */
    IF sec.fn_UserHasPermission(@ActorUserId, N'report.waiverregister') = 0
        THROW 50002, 'El usuario no tiene permiso para ver el registro de waivers.', 1;

    SELECT * FROM rpt.vw_WaiverRegister
    WHERE (@DepartmentName IS NULL OR DepartmentName = @DepartmentName)
      AND (@OnlyActive = 0 OR IsCurrentlyActive = 1)
    ORDER BY ExpiresAtUtc
    OPTION (RECOMPILE);

    EXEC aud.usp_DataAccess_Log
          @ActorUserId = @ActorUserId, @AccessType = 1
        , @EntityType = N'WaiverRegister', @Purpose = N'ComplianceReview';
    RETURN 0;
END;
GO

PRINT '=== 16_procs_reporting.sql completado ===';
GO
