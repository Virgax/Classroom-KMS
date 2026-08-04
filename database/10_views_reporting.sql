/* =============================================================================
   Classroom LMS by Airlink
   10_views_reporting.sql  -  Esquema rpt. Unico esquema con SELECT concedido
                              (a AlLmsReportUser / Power BI).
   -----------------------------------------------------------------------------
   Regla: la reporteria NUNCA consulta tablas OLTP directamente. Todo pasa por
   estas vistas o por los SPs de rpt.
   ============================================================================= */
USE AIRLINK_KMS;
GO
SET NOCOUNT ON;
GO

/* -----------------------------------------------------------------------------
   rpt.vw_EmployeeDirectory
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_EmployeeDirectory
AS
SELECT  e.EmployeeId
      , e.PublicId               AS EmployeePublicId
      , e.EmployeeCode
      , e.FullName
      , e.Email
      , s.SiteCode
      , s.[Name]                 AS SiteName
      , d.DepartmentCode
      , d.[Name]                 AS DepartmentName
      , a.AreaCode
      , a.[Name]                 AS AreaName
      , p.PositionCode
      , p.[Name]                 AS PositionName
      , p.AffectsProductQuality
      , sup.EmployeeCode         AS SupervisorCode
      , sup.FullName             AS SupervisorName
      , e.ShiftCode
      , e.HireDateUtc
      , e.EmploymentType
      , CASE e.EmploymentType WHEN 1 THEN N'Empleado' WHEN 2 THEN N'Contratista'
                              WHEN 3 THEN N'Agencia'  ELSE N'Temporal' END AS EmploymentTypeName
      , e.IsActive
FROM org.Employee e
LEFT JOIN org.Site        s   ON s.SiteId       = e.SiteId
LEFT JOIN org.Department  d   ON d.DepartmentId = e.DepartmentId
LEFT JOIN org.Area        a   ON a.AreaId       = e.AreaId
LEFT JOIN org.[Position]  p   ON p.PositionId   = e.PrimaryPositionId
LEFT JOIN org.Employee    sup ON sup.EmployeeId = e.SupervisorEmployeeId;
GO

/* -----------------------------------------------------------------------------
   rpt.vw_CertificationStatus
   Certificaciones con el estado DERIVADO al momento de consulta, no el
   almacenado. Base de casi toda la reporteria de compliance.
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_CertificationStatus
AS
SELECT  c.CertificationId
      , c.PublicId              AS CertificationPublicId
      , c.CertificateNumber
      , c.EmployeeId
      , e.EmployeeCode
      , e.FullName              AS EmployeeName
      , e.DepartmentId
      , d.[Name]                AS DepartmentName
      , e.AreaId
      , e.SiteId
      , c.CompetencyId
      , cy.CompetencyCode
      , cy.NameEs               AS CompetencyNameEs
      , cy.NameEn               AS CompetencyNameEn
      , cy.CompetencyType
      , c.CompetencyLevelId
      , cl.LevelOrdinal
      , cl.LevelCode
      , cl.NameEs               AS LevelNameEs
      , c.RequirementId
      , r.Criticality
      , r.RegulatoryBasis
      , c.IssuedAtUtc
      , c.EvidenceCompletedAtUtc
      , c.ExpiresAtUtc
      , CASE WHEN c.ExpiresAtUtc IS NULL THEN NULL
             ELSE DATEDIFF(DAY, SYSUTCDATETIME(), c.ExpiresAtUtc) END AS DaysUntilExpiry
      , comp.fn_GetCertificationStatus(
              c.[Status]
            , c.ExpiresAtUtc
            , ops.fn_FirstAlertWindowDays(r.AlertWindowDays)
            , SYSUTCDATETIME())  AS EffectiveStatus
      , c.[Status]              AS StoredStatus
      , c.RevokedAtUtc
      , c.RevokeReason
FROM comp.Certification   c
JOIN org.Employee         e  ON e.EmployeeId       = c.EmployeeId
JOIN comp.Competency      cy ON cy.CompetencyId    = c.CompetencyId
JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = c.CompetencyLevelId
LEFT JOIN org.Department  d  ON d.DepartmentId     = e.DepartmentId
LEFT JOIN comp.CompetencyRequirement r ON r.RequirementId = c.RequirementId
WHERE c.SupersededByCertificationId IS NULL;
GO

/* -----------------------------------------------------------------------------
   rpt.vw_CompetencyMatrix
   La matriz de competencias: un renglon por Empleado x Requisito efectivo,
   con semaforo. Es el reporte #1 que pide un auditor ISO/R2.
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_CompetencyMatrix
AS
SELECT  e.EmployeeId
      , e.EmployeeCode
      , e.FullName              AS EmployeeName
      , e.DepartmentId
      , d.[Name]                AS DepartmentName
      , e.AreaId
      , a.[Name]                AS AreaName
      , e.SiteId
      , p.PositionCode
      , p.[Name]                AS PositionName
      , req.RequirementId
      , req.CompetencyId
      , cy.CompetencyCode
      , cy.NameEs               AS CompetencyNameEs
      , cy.CompetencyType
      , req.RequiredLevelOrdinal
      , reqLvl.NameEs           AS RequiredLevelName
      , cert.CertificationId
      , certLvl.LevelOrdinal    AS CurrentLevelOrdinal
      , certLvl.NameEs          AS CurrentLevelName
      , cert.ExpiresAtUtc
      , CASE WHEN cert.ExpiresAtUtc IS NULL THEN NULL
             ELSE DATEDIFF(DAY, SYSUTCDATETIME(), cert.ExpiresAtUtc) END AS DaysUntilExpiry
      , req.Criticality
      , req.RegulatoryBasis
      , comp.fn_HasActiveWaiver(e.EmployeeId, req.RequirementId) AS HasActiveWaiver
      , CASE
            WHEN cert.CertificationId IS NULL THEN 5                        -- NotCertified
            WHEN cert.[Status] = 5             THEN 6                        -- Revoked
            WHEN cert.[Status] = 4             THEN 4                        -- RetrainingRequired
            WHEN certLvl.LevelOrdinal < req.RequiredLevelOrdinal THEN 7      -- InsufficientLevel
            ELSE comp.fn_GetCertificationStatus(
                     cert.[Status], cert.ExpiresAtUtc
                   , ops.fn_FirstAlertWindowDays(req.AlertWindowDays)
                   , SYSUTCDATETIME())
        END AS MatrixStatus
        /* 1=Valid 2=ExpiringSoon 3=Expired 4=RetrainingRequired
           5=NotCertified 6=Revoked 7=InsufficientLevel */
FROM org.Employee e
CROSS APPLY comp.fn_GetEffectiveRequirements(e.EmployeeId) req
JOIN comp.Competency      cy     ON cy.CompetencyId       = req.CompetencyId
JOIN comp.CompetencyLevel reqLvl ON reqLvl.CompetencyLevelId = req.MinimumLevelId
LEFT JOIN org.Department  d      ON d.DepartmentId        = e.DepartmentId
LEFT JOIN org.Area        a      ON a.AreaId              = e.AreaId
LEFT JOIN org.[Position]  p      ON p.PositionId          = e.PrimaryPositionId
OUTER APPLY (
    SELECT TOP (1) c.*
    FROM comp.Certification c
    WHERE c.EmployeeId   = e.EmployeeId
      AND c.CompetencyId = req.CompetencyId
      AND c.SupersededByCertificationId IS NULL
    ORDER BY c.IssuedAtUtc DESC
) cert
LEFT JOIN comp.CompetencyLevel certLvl ON certLvl.CompetencyLevelId = cert.CompetencyLevelId
WHERE e.IsActive = 1;
GO

/* -----------------------------------------------------------------------------
   rpt.vw_TrainingRecord
   El expediente de entrenamiento: una fila por inscripcion completada.
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_TrainingRecord
AS
SELECT  en.EnrollmentId
      , en.PublicId              AS EnrollmentPublicId
      , en.EmployeeId
      , e.EmployeeCode
      , e.FullName               AS EmployeeName
      , e.DepartmentId
      , d.[Name]                 AS DepartmentName
      , c.CourseId
      , c.CourseCode
      , c.NameEs                 AS CourseNameEs
      , c.NameEn                 AS CourseNameEn
      , c.DeliveryType
      , cv.VersionNumber
      , cv.VersionLabel
      , en.[Source]              AS EnrollmentSource
      , en.[Status]              AS EnrollmentStatus
      , en.AttemptNumber
      , en.AssignedAtUtc
      , en.DueAtUtc
      , en.StartedAtUtc
      , en.CompletedAtUtc
      , en.ScorePercent
      , en.IsPassed
      , en.ProgressPercent
      , en.TotalTimeSpentSeconds
      , coh.CohortCode
      , inst.FullName            AS InstructorName
FROM dlv.Enrollment    en
JOIN org.Employee      e   ON e.EmployeeId       = en.EmployeeId
JOIN lms.Course        c   ON c.CourseId         = en.CourseId
JOIN lms.CourseVersion cv  ON cv.CourseVersionId = en.CourseVersionId
LEFT JOIN org.Department d ON d.DepartmentId     = e.DepartmentId
LEFT JOIN dlv.Cohort   coh ON coh.CohortId       = en.CohortId
LEFT JOIN org.Employee inst ON inst.EmployeeId   = coh.InstructorEmployeeId;
GO

/* -----------------------------------------------------------------------------
   rpt.vw_ComplianceByDepartment
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_ComplianceByDepartment
AS
SELECT  m.DepartmentId
      , m.DepartmentName
      , COUNT(*)                                                       AS TotalRequirements
      , COUNT(DISTINCT m.EmployeeId)                                   AS EmployeeCount
      , SUM(CASE WHEN m.MatrixStatus = 1 THEN 1 ELSE 0 END)            AS ValidCount
      , SUM(CASE WHEN m.MatrixStatus = 2 THEN 1 ELSE 0 END)            AS ExpiringSoonCount
      , SUM(CASE WHEN m.MatrixStatus = 3 THEN 1 ELSE 0 END)            AS ExpiredCount
      , SUM(CASE WHEN m.MatrixStatus = 4 THEN 1 ELSE 0 END)            AS RetrainingRequiredCount
      , SUM(CASE WHEN m.MatrixStatus = 5 THEN 1 ELSE 0 END)            AS NotCertifiedCount
      , SUM(CASE WHEN m.MatrixStatus = 6 THEN 1 ELSE 0 END)            AS RevokedCount
      , SUM(CASE WHEN m.MatrixStatus = 7 THEN 1 ELSE 0 END)            AS InsufficientLevelCount
      , SUM(CASE WHEN m.MatrixStatus <> 1 AND m.Criticality = 1 THEN 1 ELSE 0 END) AS CriticalGapCount
      , SUM(CASE WHEN m.HasActiveWaiver = 1 THEN 1 ELSE 0 END)         AS WaivedCount
      , CAST(100.0 * SUM(CASE WHEN m.MatrixStatus = 1 THEN 1 ELSE 0 END)
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                    AS CompliancePercent
FROM rpt.vw_CompetencyMatrix m
GROUP BY m.DepartmentId, m.DepartmentName;
GO

/* -----------------------------------------------------------------------------
   rpt.vw_ExpiringCertifications
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_ExpiringCertifications
AS
SELECT  cs.CertificationId
      , cs.CertificateNumber
      , cs.EmployeeId
      , cs.EmployeeCode
      , cs.EmployeeName
      , cs.DepartmentName
      , cs.CompetencyCode
      , cs.CompetencyNameEs
      , cs.LevelNameEs
      , cs.ExpiresAtUtc
      , cs.DaysUntilExpiry
      , cs.Criticality
      , cs.RegulatoryBasis
      , CASE WHEN cs.DaysUntilExpiry < 0  THEN N'Vencido'
             WHEN cs.DaysUntilExpiry <= 7  THEN N'7 dias'
             WHEN cs.DaysUntilExpiry <= 30 THEN N'30 dias'
             WHEN cs.DaysUntilExpiry <= 60 THEN N'60 dias'
             ELSE N'90 dias' END                       AS ExpiryBucket
FROM rpt.vw_CertificationStatus cs
WHERE cs.ExpiresAtUtc IS NOT NULL
  AND cs.DaysUntilExpiry <= 90
  AND cs.EffectiveStatus IN (1, 2, 3, 6);
GO

/* -----------------------------------------------------------------------------
   rpt.vw_DocumentAcknowledgmentStatus
   % de firma por revision de documento controlado.
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_DocumentAcknowledgmentStatus
AS
SELECT  cd.ControlledDocumentId
      , cd.DocumentCode
      , cd.TitleEs                AS DocumentTitle
      , cd.DocumentType
      , dr.DocumentRevisionId
      , dr.RevisionLabel
      , dr.[Status]               AS RevisionStatus
      , dr.EffectiveAtUtc
      , dr.RequiresReacknowledgment
      , req.PositionId
      , p.[Name]                  AS PositionName
      , COUNT(DISTINCT e.EmployeeId)                                   AS RequiredEmployeeCount
      , COUNT(DISTINCT ack.EmployeeId)                                 AS AcknowledgedCount
      , COUNT(DISTINCT e.EmployeeId) - COUNT(DISTINCT ack.EmployeeId)  AS PendingCount
      , CAST(100.0 * COUNT(DISTINCT ack.EmployeeId)
             / NULLIF(COUNT(DISTINCT e.EmployeeId), 0) AS DECIMAL(5,2)) AS AcknowledgedPercent
FROM comp.ControlledDocument            cd
JOIN comp.ControlledDocumentRevision    dr  ON dr.ControlledDocumentId = cd.ControlledDocumentId
JOIN comp.DocumentPositionMatrix        req ON req.ControlledDocumentId = cd.ControlledDocumentId
JOIN org.[Position]                     p   ON p.PositionId = req.PositionId
JOIN org.EmployeePosition               ep  ON ep.PositionId = req.PositionId
                                            AND ep.EffectiveToUtc IS NULL
JOIN org.Employee                       e   ON e.EmployeeId = ep.EmployeeId AND e.IsActive = 1
LEFT JOIN comp.DocumentAcknowledgment   ack ON ack.DocumentRevisionId = dr.DocumentRevisionId
                                            AND ack.EmployeeId = e.EmployeeId
GROUP BY cd.ControlledDocumentId, cd.DocumentCode, cd.TitleEs, cd.DocumentType
       , dr.DocumentRevisionId, dr.RevisionLabel, dr.[Status], dr.EffectiveAtUtc
       , dr.RequiresReacknowledgment, req.PositionId, p.[Name];
GO

/* -----------------------------------------------------------------------------
   rpt.vw_TrainingEffectiveness
   Evidencia para ISO 9001 cl.7.2(c): "evaluar la eficacia de las acciones
   tomadas". Tasa de aprobacion, intentos promedio, tiempo.
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_TrainingEffectiveness
AS
SELECT  c.CourseId
      , c.CourseCode
      , c.NameEs                 AS CourseName
      , c.DeliveryType
      , cv.CourseVersionId
      , cv.VersionLabel
      , COUNT(*)                                                        AS TotalEnrollments
      , SUM(CASE WHEN en.[Status] = 3 THEN 1 ELSE 0 END)                AS CompletedCount
      , SUM(CASE WHEN en.[Status] = 4 THEN 1 ELSE 0 END)                AS FailedCount
      , SUM(CASE WHEN en.[Status] = 6 THEN 1 ELSE 0 END)                AS ExpiredCount
      , CAST(100.0 * SUM(CASE WHEN en.IsPassed = 1 THEN 1 ELSE 0 END)
             / NULLIF(SUM(CASE WHEN en.[Status] IN (3,4) THEN 1 ELSE 0 END), 0)
             AS DECIMAL(5,2))                                           AS PassRatePercent
      , AVG(CAST(en.ScorePercent AS DECIMAL(9,2)))                      AS AvgScorePercent
      , AVG(CAST(en.AttemptNumber AS DECIMAL(9,2)))                     AS AvgAttempts
      , AVG(CAST(en.TotalTimeSpentSeconds AS DECIMAL(18,2)) / 60.0)     AS AvgMinutesSpent
      , AVG(CAST(DATEDIFF(DAY, en.AssignedAtUtc, en.CompletedAtUtc) AS DECIMAL(9,2)))
                                                                        AS AvgDaysToComplete
FROM dlv.Enrollment    en
JOIN lms.Course        c  ON c.CourseId         = en.CourseId
JOIN lms.CourseVersion cv ON cv.CourseVersionId = en.CourseVersionId
GROUP BY c.CourseId, c.CourseCode, c.NameEs, c.DeliveryType
       , cv.CourseVersionId, cv.VersionLabel;
GO

/* -----------------------------------------------------------------------------
   rpt.vw_WaiverRegister
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_WaiverRegister
AS
SELECT  w.WaiverId
      , w.PublicId               AS WaiverPublicId
      , e.EmployeeCode
      , e.FullName               AS EmployeeName
      , d.[Name]                 AS DepartmentName
      , cy.CompetencyCode
      , cy.NameEs                AS CompetencyName
      , r.RequirementCode
      , r.Criticality
      , r.RegulatoryBasis
      , w.WaiverType
      , w.Justification
      , w.RequiresSupervision
      , w.[Status]
      , req.DisplayName          AS RequestedBy
      , w.RequestedAtUtc
      , apr.DisplayName          AS ApprovedBy
      , w.ApprovedAtUtc
      , w.EffectiveFromUtc
      , w.ExpiresAtUtc
      , CASE WHEN w.[Status] = 2
                  AND w.RevokedAtUtc IS NULL
                  AND (w.ExpiresAtUtc IS NULL OR w.ExpiresAtUtc > SYSUTCDATETIME())
             THEN 1 ELSE 0 END   AS IsCurrentlyActive
      , w.RevokedAtUtc
      , w.RevokeReason
FROM comp.Waiver w
JOIN org.Employee                e  ON e.EmployeeId       = w.EmployeeId
JOIN comp.CompetencyRequirement  r  ON r.RequirementId    = w.RequirementId
JOIN comp.Competency             cy ON cy.CompetencyId    = r.CompetencyId
LEFT JOIN org.Department         d  ON d.DepartmentId     = e.DepartmentId
LEFT JOIN sec.[User]             req ON req.UserId        = w.RequestedByUserId
LEFT JOIN sec.[User]             apr ON apr.UserId        = w.ApprovedByUserId;
GO

/* -----------------------------------------------------------------------------
   rpt.vw_SessionRoster
   Sign-in sheet digital de sesiones presenciales.
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_SessionRoster
AS
SELECT  ts.TrainingSessionId
      , ts.SessionCode
      , ts.TitleEs               AS SessionTitle
      , c.CourseCode
      , inst.EmployeeCode        AS InstructorCode
      , inst.FullName            AS InstructorName
      , ts.ScheduledStartUtc
      , ts.ScheduledEndUtc
      , ts.ActualStartUtc
      , ts.ActualEndUtc
      , ts.LocationName
      , ts.[Status]              AS SessionStatus
      , ts.RosterSignatureId
      , e.EmployeeCode
      , e.FullName               AS ParticipantName
      , d.[Name]                 AS DepartmentName
      , att.AttendanceStatus
      , att.CheckInAtUtc
      , att.CheckOutAtUtc
      , att.MinutesAttended
      , att.ResultCode
      , att.ParticipantSignatureId
FROM dlv.TrainingSession   ts
JOIN lms.Course            c    ON c.CourseId    = ts.CourseId
JOIN org.Employee          inst ON inst.EmployeeId = ts.InstructorEmployeeId
JOIN dlv.SessionAttendance att  ON att.TrainingSessionId = ts.TrainingSessionId
JOIN org.Employee          e    ON e.EmployeeId  = att.EmployeeId
LEFT JOIN org.Department   d    ON d.DepartmentId = e.DepartmentId;
GO

/* -----------------------------------------------------------------------------
   rpt.vw_OpenCompetencyGaps
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_OpenCompetencyGaps
AS
SELECT  g.CompetencyGapId
      , g.EmployeeId
      , e.EmployeeCode
      , e.FullName               AS EmployeeName
      , e.DepartmentId
      , d.[Name]                 AS DepartmentName
      , sup.FullName             AS SupervisorName
      , g.RequirementId
      , r.RequirementCode
      , cy.CompetencyCode
      , cy.NameEs                AS CompetencyName
      , g.GapType
      , CASE g.GapType WHEN 1 THEN N'Nunca certificado'
                       WHEN 2 THEN N'Vencido'
                       WHEN 3 THEN N'Por vencer'
                       WHEN 4 THEN N'Requiere re-entrenamiento'
                       WHEN 5 THEN N'Nivel insuficiente'
                       ELSE N'Revocado' END        AS GapTypeName
      , g.Severity
      , g.CurrentLevelOrdinal
      , g.RequiredLevelOrdinal
      , g.ExpiresAtUtc
      , g.DaysUntilExpiry
      , g.HasActiveWaiver
      , g.RemediationEnrollmentId
      , g.DetectedAtUtc
      , DATEDIFF(DAY, g.DetectedAtUtc, SYSUTCDATETIME()) AS DaysOpen
      , r.RegulatoryBasis
FROM comp.CompetencyGap g
JOIN org.Employee               e  ON e.EmployeeId    = g.EmployeeId
JOIN comp.CompetencyRequirement r  ON r.RequirementId = g.RequirementId
JOIN comp.Competency            cy ON cy.CompetencyId = g.CompetencyId
LEFT JOIN org.Department        d  ON d.DepartmentId  = e.DepartmentId
LEFT JOIN org.Employee          sup ON sup.EmployeeId = e.SupervisorEmployeeId
WHERE g.ResolvedAtUtc IS NULL;
GO

/* -----------------------------------------------------------------------------
   rpt.vw_GatingShadowAnalysis
   Analisis de shadow mode: cuantos bloqueos habria habido si el gating
   estuviera en enforce. Sirve para decidir cuando activarlo.
   -------------------------------------------------------------------------- */
CREATE OR ALTER VIEW rpt.vw_GatingShadowAnalysis
AS
SELECT  CAST(g.EvaluatedAtUtc AS DATE)                                  AS EvaluationDate
      , st.StationCode
      , st.[Name]                                                       AS StationName
      , a.[Name]                                                        AS AreaName
      , g.GatingMode
      , COUNT(*)                                                        AS TotalEvaluations
      , SUM(CASE WHEN g.Decision = 1 THEN 1 ELSE 0 END)                 AS AllowedCount
      , SUM(CASE WHEN g.Decision = 2 THEN 1 ELSE 0 END)                 AS SupervisedCount
      , SUM(CASE WHEN g.Decision = 3 THEN 1 ELSE 0 END)                 AS BlockedCount
      , CAST(100.0 * SUM(CASE WHEN g.Decision = 3 THEN 1 ELSE 0 END)
             / NULLIF(COUNT(*), 0) AS DECIMAL(5,2))                     AS BlockRatePercent
      , COUNT(DISTINCT g.EmployeeId)                                    AS DistinctEmployees
FROM comp.GatingDecisionLog g
LEFT JOIN org.Station st ON st.StationId = g.StationId
LEFT JOIN org.Area    a  ON a.AreaId     = st.AreaId
GROUP BY CAST(g.EvaluatedAtUtc AS DATE), st.StationCode, st.[Name], a.[Name], g.GatingMode;
GO

PRINT '=== 10_views_reporting.sql completado ===';
GO
