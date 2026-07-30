/* =============================================================================
   Classroom LMS by Airlink
   07_tables_compliance.sql  -  comp: competencias, requisitos, certificaciones,
                                documentos controlados, waivers
   -----------------------------------------------------------------------------
   Este es el nucleo de valor del sistema. Todo lo demas es infraestructura para
   que estas tablas tengan data confiable.

   Base regulatoria:
     - ISO 9001:2015 cl.7.2 (Competencia) y cl.7.3 (Toma de conciencia)
     - R2v3 Core Requirements + FA4 (competencia tecnica de trabajadores)
   ============================================================================= */
USE AIRLINK_LMS;
GO
SET NOCOUNT ON;
GO

/* --- comp.Competency ---------------------------------------------------- */
IF OBJECT_ID(N'comp.Competency', N'U') IS NULL
CREATE TABLE comp.Competency (
      CompetencyId      INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Competency_PublicId DEFAULT NEWID()
    , CompetencyCode    NVARCHAR(40)     NOT NULL   -- 'DATA-SAN-NIST', 'IP68-ROXER-OP'
    , NameEs            NVARCHAR(250)    NOT NULL
    , NameEn            NVARCHAR(250)    NULL
    , DescriptionEs     NVARCHAR(MAX)    NULL
    , DescriptionEn     NVARCHAR(MAX)    NULL
    , CompetencyType    TINYINT          NOT NULL CONSTRAINT DF_Competency_Type DEFAULT 1
        /* 1=Technical 2=Safety 3=Quality 4=Regulatory 5=Behavioral 6=Leadership */
    , OwnerDepartmentId INT              NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Competency_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Competency_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Competency_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Competency PRIMARY KEY CLUSTERED (CompetencyId)
    , CONSTRAINT UQ_Competency_Code UNIQUE (CompetencyCode)
    , CONSTRAINT UQ_Competency_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT CK_Competency_Type CHECK (CompetencyType BETWEEN 1 AND 6)
);
GO

/* --- comp.CompetencyLevel ---------------------------------------------- */
IF OBJECT_ID(N'comp.CompetencyLevel', N'U') IS NULL
CREATE TABLE comp.CompetencyLevel (
      CompetencyLevelId INT              NOT NULL IDENTITY(1,1)
    , CompetencyId      INT              NOT NULL
    , LevelOrdinal      TINYINT          NOT NULL   -- 1..5, comparable
    , LevelCode         NVARCHAR(30)     NOT NULL   -- Awareness/Basic/Competent/Advanced/Trainer
    , NameEs            NVARCHAR(100)    NOT NULL
    , NameEn            NVARCHAR(100)    NULL
    , DescriptionEs     NVARCHAR(1000)   NULL
    , DescriptionEn     NVARCHAR(1000)   NULL
    , CanEvaluate       BIT              NOT NULL CONSTRAINT DF_CompetencyLevel_CanEvaluate DEFAULT 0
        /* 1 = quien tiene este nivel puede evaluar a otros en esta competencia */
    , CONSTRAINT PK_CompetencyLevel PRIMARY KEY CLUSTERED (CompetencyLevelId)
    , CONSTRAINT UQ_CompetencyLevel UNIQUE (CompetencyId, LevelOrdinal)
    , CONSTRAINT FK_CompetencyLevel_Competency FOREIGN KEY (CompetencyId) REFERENCES comp.Competency (CompetencyId)
    , CONSTRAINT CK_CompetencyLevel_Ordinal CHECK (LevelOrdinal BETWEEN 1 AND 9)
);
GO

/* --- comp.ControlledDocument ------------------------------------------- */
IF OBJECT_ID(N'comp.ControlledDocument', N'U') IS NULL
CREATE TABLE comp.ControlledDocument (
      ControlledDocumentId INT           NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_ControlledDocument_PublicId DEFAULT NEWID()
    , DocumentCode      NVARCHAR(60)     NOT NULL   -- 'WI-IP68-RXR-001'
    , TitleEs           NVARCHAR(300)    NOT NULL
    , TitleEn           NVARCHAR(300)    NULL
    , DocumentType      TINYINT          NOT NULL CONSTRAINT DF_ControlledDocument_Type DEFAULT 1
        /* 1=WorkInstruction 2=SOP 3=Policy 4=Form 5=Specification
           6=SafetyDataSheet 7=Manual 8=Plan */
    , OwnerDepartmentId INT              NULL
    , OwnerUserId       INT              NULL
    , ProcessCode       NVARCHAR(40)     NULL
    , CurrentRevisionId INT              NULL
    , Classification    TINYINT          NOT NULL CONSTRAINT DF_ControlledDocument_Classification DEFAULT 2
                                         -- 1=Public 2=Internal 3=Confidential 4=Restricted
    , IsActive          BIT              NOT NULL CONSTRAINT DF_ControlledDocument_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_ControlledDocument_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_ControlledDocument_IsDeleted DEFAULT 0
    , CONSTRAINT PK_ControlledDocument PRIMARY KEY CLUSTERED (ControlledDocumentId)
    , CONSTRAINT UQ_ControlledDocument_Code UNIQUE (DocumentCode)
    , CONSTRAINT CK_ControlledDocument_Type CHECK (DocumentType BETWEEN 1 AND 8)
);
GO

/* --- comp.ControlledDocumentRevision ------------------------------------ */
IF OBJECT_ID(N'comp.ControlledDocumentRevision', N'U') IS NULL
CREATE TABLE comp.ControlledDocumentRevision (
      DocumentRevisionId INT             NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_DocumentRevision_PublicId DEFAULT NEWID()
    , ControlledDocumentId INT           NOT NULL
    , RevisionNumber    INT              NOT NULL   -- 0,1,2...
    , RevisionLabel     NVARCHAR(20)     NOT NULL   -- 'Rev.1'
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_DocumentRevision_Status DEFAULT 1
        /* 1=Draft 2=InApproval 3=Active 4=Superseded 5=Obsolete */
    , FileAssetIdEs     INT              NULL       -- PDF en espanol
    , FileAssetIdEn     INT              NULL       -- PDF en ingles
    , ChangeSummaryEs   NVARCHAR(MAX)    NULL
    , ChangeSummaryEn   NVARCHAR(MAX)    NULL
    , EffectiveAtUtc    DATETIME2(3)     NULL
    , RequiresReacknowledgment BIT       NOT NULL CONSTRAINT DF_DocumentRevision_RequiresReack DEFAULT 1
        /* 1 = al activar, invalida certificaciones y genera re-entrenamiento */
    , ReacknowledgmentDeadlineDays INT   NOT NULL CONSTRAINT DF_DocumentRevision_DeadlineDays DEFAULT 30
    , MinimumReadSeconds INT             NULL       -- anti-skip de lectura
    , ActivatedAtUtc    DATETIME2(3)     NULL
    , ActivatedByUserId INT              NULL
    , SupersededAtUtc   DATETIME2(3)     NULL
    , SupersededByRevisionId INT         NULL
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_DocumentRevision_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_ControlledDocumentRevision PRIMARY KEY CLUSTERED (DocumentRevisionId)
    , CONSTRAINT UQ_DocumentRevision UNIQUE (ControlledDocumentId, RevisionNumber)
    , CONSTRAINT UQ_DocumentRevision_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT FK_DocumentRevision_Document FOREIGN KEY (ControlledDocumentId) REFERENCES comp.ControlledDocument (ControlledDocumentId)
    , CONSTRAINT FK_DocumentRevision_Superseded FOREIGN KEY (SupersededByRevisionId) REFERENCES comp.ControlledDocumentRevision (DocumentRevisionId)
    , CONSTRAINT CK_DocumentRevision_Status CHECK ([Status] BETWEEN 1 AND 5)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_ControlledDocument_CurrentRevision')
    ALTER TABLE comp.ControlledDocument ADD CONSTRAINT FK_ControlledDocument_CurrentRevision
        FOREIGN KEY (CurrentRevisionId) REFERENCES comp.ControlledDocumentRevision (DocumentRevisionId);
GO

IF OBJECT_ID(N'comp.DocumentApproval', N'U') IS NULL
CREATE TABLE comp.DocumentApproval (
      DocumentApprovalId INT             NOT NULL IDENTITY(1,1)
    , DocumentRevisionId INT             NOT NULL
    , ApprovalRole      TINYINT          NOT NULL   -- 1=Author 2=Reviewer 3=Approver 4=QualityApprover
    , ApproverUserId    INT              NOT NULL
    , Decision          TINYINT          NULL       -- 1=Approved 2=Rejected
    , Comments          NVARCHAR(1000)   NULL
    , SignatureId       BIGINT           NULL
    , RequestedAtUtc    DATETIME2(3)     NOT NULL CONSTRAINT DF_DocumentApproval_Requested DEFAULT SYSUTCDATETIME()
    , DecidedAtUtc      DATETIME2(3)     NULL
    , CONSTRAINT PK_DocumentApproval PRIMARY KEY CLUSTERED (DocumentApprovalId)
    , CONSTRAINT UQ_DocumentApproval UNIQUE (DocumentRevisionId, ApprovalRole, ApproverUserId)
    , CONSTRAINT FK_DocumentApproval_Revision FOREIGN KEY (DocumentRevisionId) REFERENCES comp.ControlledDocumentRevision (DocumentRevisionId)
);
GO

IF OBJECT_ID(N'comp.DocumentAcknowledgment', N'U') IS NULL
CREATE TABLE comp.DocumentAcknowledgment (
      DocumentAcknowledgmentId INT       NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_DocumentAck_PublicId DEFAULT NEWID()
    , DocumentRevisionId INT             NOT NULL
    , EmployeeId        INT              NOT NULL
    , EnrollmentId      INT              NULL
    , LocaleCode        NVARCHAR(10)     NOT NULL CONSTRAINT DF_DocumentAck_Locale DEFAULT N'es-DO'
    , ReadSeconds       INT              NOT NULL CONSTRAINT DF_DocumentAck_ReadSeconds DEFAULT 0
    , AcknowledgedAtUtc DATETIME2(3)     NOT NULL CONSTRAINT DF_DocumentAck_AtUtc DEFAULT SYSUTCDATETIME()
    , SignatureId       BIGINT           NULL
    , DeviceId          INT              NULL
    , IpAddress         NVARCHAR(45)     NULL
    , IsCurrent         BIT              NOT NULL CONSTRAINT DF_DocumentAck_IsCurrent DEFAULT 1
        /* 0 cuando la revision queda superseded */
    , CONSTRAINT PK_DocumentAcknowledgment PRIMARY KEY CLUSTERED (DocumentAcknowledgmentId)
    , CONSTRAINT UQ_DocumentAcknowledgment UNIQUE (DocumentRevisionId, EmployeeId)
    , CONSTRAINT FK_DocumentAck_Revision FOREIGN KEY (DocumentRevisionId) REFERENCES comp.ControlledDocumentRevision (DocumentRevisionId)
    , CONSTRAINT FK_DocumentAck_Employee FOREIGN KEY (EmployeeId)         REFERENCES org.Employee (EmployeeId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DocumentAck_Employee_Current' AND object_id = OBJECT_ID(N'comp.DocumentAcknowledgment'))
    CREATE NONCLUSTERED INDEX IX_DocumentAck_Employee_Current ON comp.DocumentAcknowledgment (EmployeeId, IsCurrent)
        INCLUDE (DocumentRevisionId, AcknowledgedAtUtc);
GO

/* --- comp.DocumentPositionMatrix : que posicion debe conocer que doc ---- */
IF OBJECT_ID(N'comp.DocumentPositionMatrix', N'U') IS NULL
CREATE TABLE comp.DocumentPositionMatrix (
      DocumentPositionMatrixId INT       NOT NULL IDENTITY(1,1)
    , ControlledDocumentId INT           NOT NULL
    , PositionId        INT              NOT NULL
    , IsMandatory       BIT              NOT NULL CONSTRAINT DF_DocPosMatrix_IsMandatory DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_DocPosMatrix_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , CONSTRAINT PK_DocumentPositionMatrix PRIMARY KEY CLUSTERED (DocumentPositionMatrixId)
    , CONSTRAINT UQ_DocumentPositionMatrix UNIQUE (ControlledDocumentId, PositionId)
    , CONSTRAINT FK_DocPosMatrix_Document FOREIGN KEY (ControlledDocumentId) REFERENCES comp.ControlledDocument (ControlledDocumentId)
    , CONSTRAINT FK_DocPosMatrix_Position FOREIGN KEY (PositionId)           REFERENCES org.[Position] (PositionId)
);
GO

/* =============================================================================
   comp.CompetencyRequirement  ***  LA TABLA MAS IMPORTANTE DEL SISTEMA  ***
   TEMPORAL: un auditor puede preguntar que requisito estaba vigente en X fecha.
   ============================================================================= */
IF OBJECT_ID(N'comp.CompetencyRequirement', N'U') IS NULL
BEGIN
    CREATE TABLE comp.CompetencyRequirement (
          RequirementId     INT              NOT NULL IDENTITY(1,1)
        , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Requirement_PublicId DEFAULT NEWID()
        , RequirementCode   NVARCHAR(40)     NOT NULL
        , CompetencyId      INT              NOT NULL
        , MinimumLevelId    INT              NOT NULL
        , ScopeType         TINYINT          NOT NULL
            /* 1=Position 2=Department 3=Area 4=Station 5=Employee 6=Site 7=Global */
        , ScopeId           INT              NULL       -- NULL solo si ScopeType=7
        , ValidityMonths    INT              NULL       -- NULL = no vence
        , AlertWindowDays   NVARCHAR(50)     NOT NULL CONSTRAINT DF_Requirement_AlertWindow DEFAULT N'60,30,7'
        , Criticality       TINYINT          NOT NULL CONSTRAINT DF_Requirement_Criticality DEFAULT 2
            /* 1=Critical (bloquea operacion) 2=Major 3=Minor */
        , RegulatoryBasis   NVARCHAR(200)    NULL
            /* 'ISO 9001:2015 cl.7.2', 'R2v3 Core 4', 'R2v3 FA4', 'OSHA 1910.147' */
        , GracePeriodDays   INT              NOT NULL CONSTRAINT DF_Requirement_GracePeriod DEFAULT 0
        , AllowProvisional  BIT              NOT NULL CONSTRAINT DF_Requirement_AllowProvisional DEFAULT 0
            /* 1 = puede operar bajo supervision directa mientras se certifica */
        , AppliesFromHireDays INT            NOT NULL CONSTRAINT DF_Requirement_FromHire DEFAULT 0
            /* dias desde ingreso para que aplique (induccion progresiva) */
        , [Status]          TINYINT          NOT NULL CONSTRAINT DF_Requirement_Status DEFAULT 1
                                             -- 1=Active 2=Draft 3=Inactive
        , EffectiveFromUtc  DATETIME2(3)     NOT NULL CONSTRAINT DF_Requirement_EffectiveFrom DEFAULT SYSUTCDATETIME()
        , EffectiveToUtc    DATETIME2(3)     NULL
        , Notes             NVARCHAR(MAX)    NULL
        , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Requirement_CreatedAtUtc DEFAULT SYSUTCDATETIME()
        , CreatedByUserId   INT              NOT NULL
        , ModifiedAtUtc     DATETIME2(3)     NULL
        , ModifiedByUserId  INT              NULL
        , ValidFromUtc      DATETIME2(3)     GENERATED ALWAYS AS ROW START NOT NULL
        , ValidToUtc        DATETIME2(3)     GENERATED ALWAYS AS ROW END   NOT NULL
        , PERIOD FOR SYSTEM_TIME (ValidFromUtc, ValidToUtc)
        , CONSTRAINT PK_CompetencyRequirement PRIMARY KEY CLUSTERED (RequirementId)
        , CONSTRAINT UQ_Requirement_Code UNIQUE (RequirementCode)
        , CONSTRAINT UQ_Requirement_PublicId UNIQUE NONCLUSTERED (PublicId)
        , CONSTRAINT CK_Requirement_ScopeType CHECK (ScopeType BETWEEN 1 AND 7)
        , CONSTRAINT CK_Requirement_ScopeId CHECK ((ScopeType = 7 AND ScopeId IS NULL)
                                                OR (ScopeType <> 7 AND ScopeId IS NOT NULL))
        , CONSTRAINT CK_Requirement_Criticality CHECK (Criticality IN (1,2,3))
        , CONSTRAINT CK_Requirement_Validity CHECK (ValidityMonths IS NULL OR ValidityMonths > 0)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = comp.CompetencyRequirementHistory));

    ALTER TABLE comp.CompetencyRequirement ADD CONSTRAINT FK_Requirement_Competency
        FOREIGN KEY (CompetencyId) REFERENCES comp.Competency (CompetencyId);
    ALTER TABLE comp.CompetencyRequirement ADD CONSTRAINT FK_Requirement_Level
        FOREIGN KEY (MinimumLevelId) REFERENCES comp.CompetencyLevel (CompetencyLevelId);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Requirement_Scope' AND object_id = OBJECT_ID(N'comp.CompetencyRequirement'))
    CREATE NONCLUSTERED INDEX IX_Requirement_Scope ON comp.CompetencyRequirement (ScopeType, ScopeId, [Status])
        INCLUDE (CompetencyId, MinimumLevelId, ValidityMonths, Criticality);
GO

/* --- comp.RequirementSatisfier : QUE satisface el requisito ------------- */
/* Separacion clave vs Canvas: el requisito obliga, el curso es solo un medio. */
IF OBJECT_ID(N'comp.RequirementSatisfier', N'U') IS NULL
CREATE TABLE comp.RequirementSatisfier (
      RequirementSatisfierId INT         NOT NULL IDENTITY(1,1)
    , RequirementId     INT              NOT NULL
    , SatisfierType     TINYINT          NOT NULL
        /* 1=Course 2=Program 3=PracticalAssessmentTemplate
           4=DocumentAcknowledgment 5=ExternalCredential 6=Quiz */
    , SatisfierId       INT              NULL       -- NULL para ExternalCredential libre
    , ExternalCredentialName NVARCHAR(250) NULL
    , IsMandatory       BIT              NOT NULL CONSTRAINT DF_RequirementSatisfier_IsMandatory DEFAULT 1
        /* 0 = alternativa (cualquiera de los no-mandatorios satisface) */
    , AlternativeGroup  TINYINT          NULL       -- satisfactores intercambiables
    , SortOrder         INT              NOT NULL CONSTRAINT DF_RequirementSatisfier_SortOrder DEFAULT 0
    , CONSTRAINT PK_RequirementSatisfier PRIMARY KEY CLUSTERED (RequirementSatisfierId)
    , CONSTRAINT FK_RequirementSatisfier_Requirement FOREIGN KEY (RequirementId) REFERENCES comp.CompetencyRequirement (RequirementId)
    , CONSTRAINT CK_RequirementSatisfier_Type CHECK (SatisfierType BETWEEN 1 AND 6)
);
GO

IF OBJECT_ID(N'comp.RequirementDocument', N'U') IS NULL
CREATE TABLE comp.RequirementDocument (
      RequirementDocumentId INT          NOT NULL IDENTITY(1,1)
    , RequirementId     INT              NOT NULL
    , ControlledDocumentId INT           NOT NULL
    , InvalidateOnRevision BIT           NOT NULL CONSTRAINT DF_RequirementDocument_Invalidate DEFAULT 1
        /* GAP-02: nueva revision de esta WI invalida la certificacion */
    , CONSTRAINT PK_RequirementDocument PRIMARY KEY CLUSTERED (RequirementDocumentId)
    , CONSTRAINT UQ_RequirementDocument UNIQUE (RequirementId, ControlledDocumentId)
    , CONSTRAINT FK_RequirementDocument_Requirement FOREIGN KEY (RequirementId)        REFERENCES comp.CompetencyRequirement (RequirementId)
    , CONSTRAINT FK_RequirementDocument_Document    FOREIGN KEY (ControlledDocumentId) REFERENCES comp.ControlledDocument (ControlledDocumentId)
);
GO

/* --- comp.Certification : TEMPORAL ------------------------------------- */
IF OBJECT_ID(N'comp.Certification', N'U') IS NULL
BEGIN
    CREATE TABLE comp.Certification (
          CertificationId   INT              NOT NULL IDENTITY(1,1)
        , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Certification_PublicId DEFAULT NEWID()
        , CertificateNumber NVARCHAR(40)     NOT NULL   -- verificable por QR
        , EmployeeId        INT              NOT NULL
        , CompetencyId      INT              NOT NULL
        , CompetencyLevelId INT              NOT NULL
        , RequirementId     INT              NULL
        , [Status]          TINYINT          NOT NULL CONSTRAINT DF_Certification_Status DEFAULT 1
            /* 1=Valid 2=ExpiringSoon 3=Expired 4=RetrainingRequired
               5=Revoked 6=Provisional */
        , IssuedAtUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_Certification_IssuedAtUtc DEFAULT SYSUTCDATETIME()
        , EvidenceCompletedAtUtc DATETIME2(3) NOT NULL
            /* la vigencia se cuenta desde la ULTIMA pieza de evidencia, no desde
               la inscripcion ni desde la emision */
        , ExpiresAtUtc      DATETIME2(3)     NULL       -- NULL = no vence
        , IssuedByUserId    INT              NULL       -- NULL = emision automatica
        , EmployeeNameSnapshot NVARCHAR(250) NOT NULL
            /* el nombre al momento de emitir: la evidencia no cambia si RH
               corrige el nombre despues */
        , PositionNameSnapshot NVARCHAR(150) NULL
        , SignatureId       BIGINT           NULL
        , RevokedAtUtc      DATETIME2(3)     NULL
        , RevokedByUserId   INT              NULL
        , RevokeReason      NVARCHAR(1000)   NULL
        , ReinstatedAtUtc   DATETIME2(3)     NULL
        , ReinstatedByUserId INT             NULL
        , ReinstateJustification NVARCHAR(1000) NULL
        , SupersededByCertificationId INT    NULL       -- recertificacion
        , ValidFromUtc      DATETIME2(3)     GENERATED ALWAYS AS ROW START NOT NULL
        , ValidToUtc        DATETIME2(3)     GENERATED ALWAYS AS ROW END   NOT NULL
        , PERIOD FOR SYSTEM_TIME (ValidFromUtc, ValidToUtc)
        , CONSTRAINT PK_Certification PRIMARY KEY CLUSTERED (CertificationId)
        , CONSTRAINT UQ_Certification_Number UNIQUE (CertificateNumber)
        , CONSTRAINT UQ_Certification_PublicId UNIQUE NONCLUSTERED (PublicId)
        , CONSTRAINT CK_Certification_Status CHECK ([Status] BETWEEN 1 AND 6)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = comp.CertificationHistory));

    ALTER TABLE comp.Certification ADD CONSTRAINT FK_Certification_Employee
        FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId);
    ALTER TABLE comp.Certification ADD CONSTRAINT FK_Certification_Competency
        FOREIGN KEY (CompetencyId) REFERENCES comp.Competency (CompetencyId);
    ALTER TABLE comp.Certification ADD CONSTRAINT FK_Certification_Level
        FOREIGN KEY (CompetencyLevelId) REFERENCES comp.CompetencyLevel (CompetencyLevelId);
    ALTER TABLE comp.Certification ADD CONSTRAINT FK_Certification_Superseded
        FOREIGN KEY (SupersededByCertificationId) REFERENCES comp.Certification (CertificationId);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Certification_Employee_Competency' AND object_id = OBJECT_ID(N'comp.Certification'))
    CREATE NONCLUSTERED INDEX IX_Certification_Employee_Competency
        ON comp.Certification (EmployeeId, CompetencyId, [Status])
        INCLUDE (CompetencyLevelId, ExpiresAtUtc, IssuedAtUtc);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Certification_Expiry' AND object_id = OBJECT_ID(N'comp.Certification'))
    CREATE NONCLUSTERED INDEX IX_Certification_Expiry ON comp.Certification (ExpiresAtUtc)
        INCLUDE (EmployeeId, CompetencyId, [Status]) WHERE [Status] IN (1,2,6);
GO

IF OBJECT_ID(N'comp.CertificationEvidence', N'U') IS NULL
CREATE TABLE comp.CertificationEvidence (
      CertificationEvidenceId INT        NOT NULL IDENTITY(1,1)
    , CertificationId   INT              NOT NULL
    , EvidenceType      TINYINT          NOT NULL
        /* 1=Enrollment 2=QuizAttempt 3=PracticalAssessment 4=SessionAttendance
           5=DocumentAcknowledgment 6=ExternalCredential */
    , EvidenceId        INT              NULL
    , EvidenceReference NVARCHAR(250)    NULL       -- descripcion legible
    , CompletedAtUtc    DATETIME2(3)     NOT NULL
    , ScorePercent      DECIMAL(5,2)     NULL
    , CONSTRAINT PK_CertificationEvidence PRIMARY KEY CLUSTERED (CertificationEvidenceId)
    , CONSTRAINT FK_CertificationEvidence_Certification FOREIGN KEY (CertificationId) REFERENCES comp.Certification (CertificationId)
);
GO

/* --- comp.CompetencyGap : materializada por el motor ------------------- */
IF OBJECT_ID(N'comp.CompetencyGap', N'U') IS NULL
CREATE TABLE comp.CompetencyGap (
      CompetencyGapId   INT              NOT NULL IDENTITY(1,1)
    , EmployeeId        INT              NOT NULL
    , RequirementId     INT              NOT NULL
    , CompetencyId      INT              NOT NULL
    , GapType           TINYINT          NOT NULL
        /* 1=NeverCertified 2=Expired 3=ExpiringSoon 4=RetrainingRequired
           5=InsufficientLevel 6=Revoked */
    , Severity          TINYINT          NOT NULL   -- 1=Critical 2=Major 3=Minor
    , CurrentLevelOrdinal TINYINT        NULL
    , RequiredLevelOrdinal TINYINT       NOT NULL
    , CertificationId   INT              NULL
    , ExpiresAtUtc      DATETIME2(3)     NULL
    , DaysUntilExpiry   INT              NULL
    , RemediationEnrollmentId INT        NULL       -- inscripcion generada
    , HasActiveWaiver   BIT              NOT NULL CONSTRAINT DF_CompetencyGap_HasWaiver DEFAULT 0
    , DetectedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_CompetencyGap_DetectedAtUtc DEFAULT SYSUTCDATETIME()
    , LastEvaluatedAtUtc DATETIME2(3)    NOT NULL CONSTRAINT DF_CompetencyGap_LastEvalAtUtc DEFAULT SYSUTCDATETIME()
    , ResolvedAtUtc     DATETIME2(3)     NULL
    , CONSTRAINT PK_CompetencyGap PRIMARY KEY CLUSTERED (CompetencyGapId)
    , CONSTRAINT UQ_CompetencyGap UNIQUE (EmployeeId, RequirementId)
    , CONSTRAINT FK_CompetencyGap_Employee    FOREIGN KEY (EmployeeId)    REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT FK_CompetencyGap_Requirement FOREIGN KEY (RequirementId) REFERENCES comp.CompetencyRequirement (RequirementId)
    , CONSTRAINT CK_CompetencyGap_Type CHECK (GapType BETWEEN 1 AND 6)
    , CONSTRAINT CK_CompetencyGap_Severity CHECK (Severity IN (1,2,3))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_CompetencyGap_Open' AND object_id = OBJECT_ID(N'comp.CompetencyGap'))
    CREATE NONCLUSTERED INDEX IX_CompetencyGap_Open ON comp.CompetencyGap (EmployeeId, Severity)
        INCLUDE (RequirementId, CompetencyId, GapType, ExpiresAtUtc)
        WHERE ResolvedAtUtc IS NULL;
GO

/* --- comp.Waiver : excepcion documentada ------------------------------- */
/* Todo waiver es visible en el reporte de auditoria. Esconderlos es peor que
   tenerlos: un auditor prefiere una excepcion justificada a un hueco oculto. */
IF OBJECT_ID(N'comp.Waiver', N'U') IS NULL
CREATE TABLE comp.Waiver (
      WaiverId          INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Waiver_PublicId DEFAULT NEWID()
    , EmployeeId        INT              NOT NULL
    , RequirementId     INT              NOT NULL
    , WaiverType        TINYINT          NOT NULL CONSTRAINT DF_Waiver_Type DEFAULT 1
        /* 1=TemporaryException 2=EquivalentExperience 3=PriorCredential
           4=Emergency 5=RoleTransition */
    , Justification     NVARCHAR(MAX)    NOT NULL   -- obligatoria
    , RequiresSupervision BIT            NOT NULL CONSTRAINT DF_Waiver_RequiresSupervision DEFAULT 1
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_Waiver_Status DEFAULT 1
        /* 1=Requested 2=Approved 3=Rejected 4=Expired 5=Revoked */
    , RequestedByUserId INT              NOT NULL
    , RequestedAtUtc    DATETIME2(3)     NOT NULL CONSTRAINT DF_Waiver_RequestedAtUtc DEFAULT SYSUTCDATETIME()
    , ApprovedByUserId  INT              NULL
    , ApprovedAtUtc     DATETIME2(3)     NULL
    , ApproverComments  NVARCHAR(1000)   NULL
    , EffectiveFromUtc  DATETIME2(3)     NULL
    , ExpiresAtUtc      DATETIME2(3)     NULL       -- todo waiver vence
    , RevokedAtUtc      DATETIME2(3)     NULL
    , RevokedByUserId   INT              NULL
    , RevokeReason      NVARCHAR(1000)   NULL
    , SignatureId       BIGINT           NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_Waiver PRIMARY KEY CLUSTERED (WaiverId)
    , CONSTRAINT UQ_Waiver_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT FK_Waiver_Employee    FOREIGN KEY (EmployeeId)    REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT FK_Waiver_Requirement FOREIGN KEY (RequirementId) REFERENCES comp.CompetencyRequirement (RequirementId)
    , CONSTRAINT CK_Waiver_Status CHECK ([Status] BETWEEN 1 AND 5)
    , CONSTRAINT CK_Waiver_Approver CHECK (ApprovedByUserId IS NULL OR ApprovedByUserId <> RequestedByUserId)
        /* SoD: quien solicita no aprueba */
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Waiver_Active' AND object_id = OBJECT_ID(N'comp.Waiver'))
    CREATE NONCLUSTERED INDEX IX_Waiver_Active ON comp.Waiver (EmployeeId, RequirementId, [Status])
        INCLUDE (ExpiresAtUtc, RequiresSupervision);
GO

/* --- comp.EvaluatorQualification : quien puede evaluar que ------------- */
IF OBJECT_ID(N'comp.EvaluatorQualification', N'U') IS NULL
CREATE TABLE comp.EvaluatorQualification (
      EvaluatorQualificationId INT       NOT NULL IDENTITY(1,1)
    , EmployeeId        INT              NOT NULL
    , CompetencyId      INT              NOT NULL
    , MaxLevelOrdinal   TINYINT          NOT NULL   -- hasta que nivel puede certificar
    , CanTrain          BIT              NOT NULL CONSTRAINT DF_EvaluatorQual_CanTrain DEFAULT 1
    , CanEvaluate       BIT              NOT NULL CONSTRAINT DF_EvaluatorQual_CanEvaluate DEFAULT 1
    , GrantedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_EvaluatorQual_GrantedAtUtc DEFAULT SYSUTCDATETIME()
    , GrantedByUserId   INT              NOT NULL
    , ExpiresAtUtc      DATETIME2(3)     NULL
    , RevokedAtUtc      DATETIME2(3)     NULL
    , RevokedByUserId   INT              NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_EvaluatorQual_IsActive DEFAULT 1
    , CONSTRAINT PK_EvaluatorQualification PRIMARY KEY CLUSTERED (EvaluatorQualificationId)
    , CONSTRAINT UQ_EvaluatorQualification UNIQUE (EmployeeId, CompetencyId)
    , CONSTRAINT FK_EvaluatorQual_Employee   FOREIGN KEY (EmployeeId)   REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT FK_EvaluatorQual_Competency FOREIGN KEY (CompetencyId) REFERENCES comp.Competency (CompetencyId)
);
GO

/* --- comp.StationCompetency : que competencias exige una estacion ------ */
IF OBJECT_ID(N'comp.StationCompetency', N'U') IS NULL
CREATE TABLE comp.StationCompetency (
      StationCompetencyId INT            NOT NULL IDENTITY(1,1)
    , StationId         INT              NOT NULL
    , RequirementId     INT              NOT NULL
    , IsBlocking        BIT              NOT NULL CONSTRAINT DF_StationCompetency_IsBlocking DEFAULT 0
    , CONSTRAINT PK_StationCompetency PRIMARY KEY CLUSTERED (StationCompetencyId)
    , CONSTRAINT UQ_StationCompetency UNIQUE (StationId, RequirementId)
    , CONSTRAINT FK_StationCompetency_Station     FOREIGN KEY (StationId)     REFERENCES org.Station (StationId)
    , CONSTRAINT FK_StationCompetency_Requirement FOREIGN KEY (RequirementId) REFERENCES comp.CompetencyRequirement (RequirementId)
);
GO

/* --- comp.CertificationTemplate : plantilla del PDF ------------------- */
IF OBJECT_ID(N'comp.CertificationTemplate', N'U') IS NULL
CREATE TABLE comp.CertificationTemplate (
      CertificationTemplateId INT        NOT NULL IDENTITY(1,1)
    , TemplateCode      NVARCHAR(40)     NOT NULL
    , [Name]            NVARCHAR(200)    NOT NULL
    , CompetencyId      INT              NULL       -- NULL = plantilla por defecto
    , LocaleCode        NVARCHAR(10)     NOT NULL CONSTRAINT DF_CertTemplate_Locale DEFAULT N'es-DO'
    , HtmlTemplate      NVARCHAR(MAX)    NOT NULL
    , IsDefault         BIT              NOT NULL CONSTRAINT DF_CertTemplate_IsDefault DEFAULT 0
    , IsActive          BIT              NOT NULL CONSTRAINT DF_CertTemplate_IsActive DEFAULT 1
    , CONSTRAINT PK_CertificationTemplate PRIMARY KEY CLUSTERED (CertificationTemplateId)
    , CONSTRAINT UQ_CertificationTemplate UNIQUE (TemplateCode, LocaleCode)
);
GO

/* --- comp.GatingDecisionLog : shadow mode ----------------------------- */
/* Durante shadow mode registramos cada decision sin bloquear, para medir la
   tasa de falsos positivos antes de activar enforce. Ver doc 07 seccion 4.3. */
IF OBJECT_ID(N'comp.GatingDecisionLog', N'U') IS NULL
CREATE TABLE comp.GatingDecisionLog (
      GatingDecisionLogId BIGINT         NOT NULL IDENTITY(1,1)
    , EmployeeId        INT              NOT NULL
    , StationId         INT              NULL
    , CompetencyId      INT              NULL
    , Decision          TINYINT          NOT NULL   -- 1=Allowed 2=AllowedWithSupervision 3=Blocked
    , GatingMode        TINYINT          NOT NULL   -- 1=Shadow 2=Warn 3=Enforce
    , WasEnforced       BIT              NOT NULL CONSTRAINT DF_GatingLog_WasEnforced DEFAULT 0
    , MissingRequirementsJson NVARCHAR(MAX) NULL
    , RequestSource     NVARCHAR(50)     NULL       -- 'Nexus','Movement','Manual'
    , EvaluatedAtUtc    DATETIME2(3)     NOT NULL CONSTRAINT DF_GatingLog_EvaluatedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_GatingDecisionLog PRIMARY KEY CLUSTERED (GatingDecisionLogId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_GatingLog_Time' AND object_id = OBJECT_ID(N'comp.GatingDecisionLog'))
    CREATE NONCLUSTERED INDEX IX_GatingLog_Time ON comp.GatingDecisionLog (EvaluatedAtUtc DESC)
        INCLUDE (EmployeeId, StationId, Decision, GatingMode);
GO

PRINT '=== 07_tables_compliance.sql completado ===';
GO
