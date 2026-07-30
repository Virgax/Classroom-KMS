/* =============================================================================
   Classroom LMS by Airlink
   06_tables_delivery.sql  -  dlv: inscripciones, progreso, cohortes, ILT
   ============================================================================= */
USE AIRLINK_LMS;
GO
SET NOCOUNT ON;
GO

/* --- dlv.Cohort : equivalente a "section" de Canvas. Turno + instructor. -- */
IF OBJECT_ID(N'dlv.Cohort', N'U') IS NULL
CREATE TABLE dlv.Cohort (
      CohortId          INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Cohort_PublicId DEFAULT NEWID()
    , CourseId          INT              NOT NULL
    , CohortCode        NVARCHAR(40)     NOT NULL
    , [Name]            NVARCHAR(200)    NOT NULL
    , InstructorEmployeeId INT           NULL
    , ShiftCode         NVARCHAR(20)     NULL
    , LocaleCode        NVARCHAR(10)     NOT NULL CONSTRAINT DF_Cohort_LocaleCode DEFAULT N'es-DO'
    , StartsAtUtc       DATETIME2(3)     NULL
    , EndsAtUtc         DATETIME2(3)     NULL
    , MaxParticipants   INT              NULL
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_Cohort_Status DEFAULT 1
                                         -- 1=Open 2=Full 3=InProgress 4=Closed 5=Cancelled
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Cohort_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Cohort_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Cohort PRIMARY KEY CLUSTERED (CohortId)
    , CONSTRAINT UQ_Cohort_Code UNIQUE (CohortCode)
    , CONSTRAINT FK_Cohort_Course FOREIGN KEY (CourseId) REFERENCES lms.Course (CourseId)
);
GO

/* --- dlv.Enrollment : TEMPORAL. La entidad mas consultada del sistema. --- */
IF OBJECT_ID(N'dlv.Enrollment', N'U') IS NULL
BEGIN
    CREATE TABLE dlv.Enrollment (
          EnrollmentId      INT              NOT NULL IDENTITY(1,1)
        , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Enrollment_PublicId DEFAULT NEWID()
        , EmployeeId        INT              NOT NULL
        , CourseId          INT              NOT NULL
        , CourseVersionId   INT              NOT NULL   -- version congelada al inscribir
        , CohortId          INT              NULL
        , ProgramId         INT              NULL       -- si viene de un learning path
        , [Source]          TINYINT          NOT NULL CONSTRAINT DF_Enrollment_Source DEFAULT 2
            /* 1=CompetencyRequired  2=AssignedByManager  3=SelfEnrolled
               4=BulkAssignment      5=DocumentRevisionRetraining */
        , SourceRequirementId INT            NULL       -- comp.CompetencyRequirement
        , [Status]          TINYINT          NOT NULL CONSTRAINT DF_Enrollment_Status DEFAULT 1
            /* 1=Assigned 2=InProgress 3=Completed 4=Failed 5=Withdrawn 6=Expired */
        , AttemptNumber     TINYINT          NOT NULL CONSTRAINT DF_Enrollment_AttemptNumber DEFAULT 1
        , ProgressPercent   DECIMAL(5,2)     NOT NULL CONSTRAINT DF_Enrollment_ProgressPercent DEFAULT 0
        , ScorePercent      DECIMAL(5,2)     NULL
        , IsPassed          BIT              NULL
        , AssignedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_Enrollment_AssignedAtUtc DEFAULT SYSUTCDATETIME()
        , AssignedByUserId  INT              NULL
        , DueAtUtc          DATETIME2(3)     NULL
        , StartedAtUtc      DATETIME2(3)     NULL
        , CompletedAtUtc    DATETIME2(3)     NULL
        , WithdrawnAtUtc    DATETIME2(3)     NULL
        , WithdrawnByUserId INT              NULL
        , WithdrawReason    NVARCHAR(400)    NULL
        , LastAccessedAtUtc DATETIME2(3)     NULL
        , LastAccessedItemId INT             NULL       -- continuar donde quedo
        , TotalTimeSpentSeconds INT          NOT NULL CONSTRAINT DF_Enrollment_TimeSpent DEFAULT 0
        , PreviousEnrollmentId INT           NULL       -- re-inscripcion: nunca sobreescribir
        , ModifiedAtUtc     DATETIME2(3)     NULL
        , ModifiedByUserId  INT              NULL
        , ValidFromUtc      DATETIME2(3)     GENERATED ALWAYS AS ROW START NOT NULL
        , ValidToUtc        DATETIME2(3)     GENERATED ALWAYS AS ROW END   NOT NULL
        , PERIOD FOR SYSTEM_TIME (ValidFromUtc, ValidToUtc)
        , CONSTRAINT PK_Enrollment PRIMARY KEY CLUSTERED (EnrollmentId)
        , CONSTRAINT UQ_Enrollment_PublicId UNIQUE NONCLUSTERED (PublicId)
        , CONSTRAINT CK_Enrollment_Source CHECK ([Source] BETWEEN 1 AND 5)
        , CONSTRAINT CK_Enrollment_Status CHECK ([Status] BETWEEN 1 AND 6)
        , CONSTRAINT CK_Enrollment_Progress CHECK (ProgressPercent BETWEEN 0 AND 100)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = dlv.EnrollmentHistory));

    ALTER TABLE dlv.Enrollment ADD CONSTRAINT FK_Enrollment_Employee
        FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId);
    ALTER TABLE dlv.Enrollment ADD CONSTRAINT FK_Enrollment_Course
        FOREIGN KEY (CourseId) REFERENCES lms.Course (CourseId);
    ALTER TABLE dlv.Enrollment ADD CONSTRAINT FK_Enrollment_CourseVersion
        FOREIGN KEY (CourseVersionId) REFERENCES lms.CourseVersion (CourseVersionId);
    ALTER TABLE dlv.Enrollment ADD CONSTRAINT FK_Enrollment_Cohort
        FOREIGN KEY (CohortId) REFERENCES dlv.Cohort (CohortId);
    ALTER TABLE dlv.Enrollment ADD CONSTRAINT FK_Enrollment_Previous
        FOREIGN KEY (PreviousEnrollmentId) REFERENCES dlv.Enrollment (EnrollmentId);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Enrollment_Employee_Status' AND object_id = OBJECT_ID(N'dlv.Enrollment'))
    CREATE NONCLUSTERED INDEX IX_Enrollment_Employee_Status ON dlv.Enrollment (EmployeeId, [Status])
        INCLUDE (CourseId, CourseVersionId, DueAtUtc, ProgressPercent, IsPassed);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Enrollment_Due_Open' AND object_id = OBJECT_ID(N'dlv.Enrollment'))
    CREATE NONCLUSTERED INDEX IX_Enrollment_Due_Open ON dlv.Enrollment (DueAtUtc)
        INCLUDE (EmployeeId, CourseId, [Status]) WHERE [Status] IN (1,2);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Enrollment_CourseVersion_Status' AND object_id = OBJECT_ID(N'dlv.Enrollment'))
    CREATE NONCLUSTERED INDEX IX_Enrollment_CourseVersion_Status ON dlv.Enrollment (CourseVersionId, [Status])
        INCLUDE (EmployeeId, CompletedAtUtc);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Enrollment_Requirement' AND object_id = OBJECT_ID(N'dlv.Enrollment'))
    CREATE NONCLUSTERED INDEX IX_Enrollment_Requirement ON dlv.Enrollment (SourceRequirementId, [Status])
        WHERE SourceRequirementId IS NOT NULL;
GO

/* --- dlv.ModuleProgress : materializado para performance ---------------- */
IF OBJECT_ID(N'dlv.ModuleProgress', N'U') IS NULL
CREATE TABLE dlv.ModuleProgress (
      ModuleProgressId  INT              NOT NULL IDENTITY(1,1)
    , EnrollmentId      INT              NOT NULL
    , CourseModuleId    INT              NOT NULL
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_ModuleProgress_Status DEFAULT 1
                                         -- 1=Locked 2=Available 3=InProgress 4=Completed
    , ItemsTotal        INT              NOT NULL CONSTRAINT DF_ModuleProgress_ItemsTotal DEFAULT 0
    , ItemsCompleted    INT              NOT NULL CONSTRAINT DF_ModuleProgress_ItemsCompleted DEFAULT 0
    , ProgressPercent   DECIMAL(5,2)     NOT NULL CONSTRAINT DF_ModuleProgress_Percent DEFAULT 0
    , UnlockedAtUtc     DATETIME2(3)     NULL
    , CompletedAtUtc    DATETIME2(3)     NULL
    , ModifiedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_ModuleProgress_ModifiedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_ModuleProgress PRIMARY KEY CLUSTERED (ModuleProgressId)
    , CONSTRAINT UQ_ModuleProgress UNIQUE (EnrollmentId, CourseModuleId)
    , CONSTRAINT FK_ModuleProgress_Enrollment FOREIGN KEY (EnrollmentId)   REFERENCES dlv.Enrollment (EnrollmentId)
    , CONSTRAINT FK_ModuleProgress_Module     FOREIGN KEY (CourseModuleId) REFERENCES lms.CourseModule (CourseModuleId)
);
GO

/* --- dlv.ItemProgress -------------------------------------------------- */
IF OBJECT_ID(N'dlv.ItemProgress', N'U') IS NULL
CREATE TABLE dlv.ItemProgress (
      ItemProgressId    INT              NOT NULL IDENTITY(1,1)
    , EnrollmentId      INT              NOT NULL
    , ModuleItemId      INT              NOT NULL
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_ItemProgress_Status DEFAULT 1
                                         -- 1=NotStarted 2=InProgress 3=Completed 4=Failed
    , TimeSpentSeconds  INT              NOT NULL CONSTRAINT DF_ItemProgress_TimeSpent DEFAULT 0
    , ViewCount         INT              NOT NULL CONSTRAINT DF_ItemProgress_ViewCount DEFAULT 0
    , ScorePercent      DECIMAL(5,2)     NULL
    , VideoPositionSeconds INT           NULL       -- reanudar video
    , VideoWatchedPercent DECIMAL(5,2)   NULL       -- anti-skip
    , FirstAccessedAtUtc DATETIME2(3)    NULL
    , LastAccessedAtUtc DATETIME2(3)     NULL
    , CompletedAtUtc    DATETIME2(3)     NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_ItemProgress PRIMARY KEY CLUSTERED (ItemProgressId)
    , CONSTRAINT UQ_ItemProgress UNIQUE (EnrollmentId, ModuleItemId)
    , CONSTRAINT FK_ItemProgress_Enrollment FOREIGN KEY (EnrollmentId) REFERENCES dlv.Enrollment (EnrollmentId)
    , CONSTRAINT FK_ItemProgress_ModuleItem FOREIGN KEY (ModuleItemId) REFERENCES lms.ModuleItem (ModuleItemId)
    , CONSTRAINT CK_ItemProgress_Status CHECK ([Status] BETWEEN 1 AND 4)
);
GO

/* --- dlv.EnrollmentEvidence : que satisface esta inscripcion ------------ */
/* Une la inscripcion con la evidencia concreta. Alimenta la emision de
   certificacion y el paquete de auditoria.                                */
IF OBJECT_ID(N'dlv.EnrollmentEvidence', N'U') IS NULL
CREATE TABLE dlv.EnrollmentEvidence (
      EnrollmentEvidenceId INT           NOT NULL IDENTITY(1,1)
    , EnrollmentId      INT              NOT NULL
    , EvidenceType      TINYINT          NOT NULL
        /* 1=QuizAttempt 2=PracticalAssessment 3=SessionAttendance
           4=DocumentAcknowledgment 5=RubricAssessment 6=ExternalCredential */
    , EvidenceId        INT              NOT NULL   -- polimorfico
    , IsPassing         BIT              NOT NULL CONSTRAINT DF_EnrollmentEvidence_IsPassing DEFAULT 0
    , ScorePercent      DECIMAL(5,2)     NULL
    , RecordedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_EnrollmentEvidence_RecordedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_EnrollmentEvidence PRIMARY KEY CLUSTERED (EnrollmentEvidenceId)
    , CONSTRAINT UQ_EnrollmentEvidence UNIQUE (EnrollmentId, EvidenceType, EvidenceId)
    , CONSTRAINT FK_EnrollmentEvidence_Enrollment FOREIGN KEY (EnrollmentId) REFERENCES dlv.Enrollment (EnrollmentId)
    , CONSTRAINT CK_EnrollmentEvidence_Type CHECK (EvidenceType BETWEEN 1 AND 6)
);
GO

/* --- dlv.EnrollmentExtension : prorroga con justificacion -------------- */
IF OBJECT_ID(N'dlv.EnrollmentExtension', N'U') IS NULL
CREATE TABLE dlv.EnrollmentExtension (
      EnrollmentExtensionId INT          NOT NULL IDENTITY(1,1)
    , EnrollmentId      INT              NOT NULL
    , PreviousDueAtUtc  DATETIME2(3)     NULL
    , NewDueAtUtc       DATETIME2(3)     NOT NULL
    , Justification     NVARCHAR(1000)   NOT NULL   -- obligatoria
    , RequestedByUserId INT              NOT NULL
    , ApprovedByUserId  INT              NOT NULL
    , GrantedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_EnrollmentExtension_GrantedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_EnrollmentExtension PRIMARY KEY CLUSTERED (EnrollmentExtensionId)
    , CONSTRAINT FK_EnrollmentExtension_Enrollment FOREIGN KEY (EnrollmentId) REFERENCES dlv.Enrollment (EnrollmentId)
);
GO

/* --- dlv.LearningActivity : heartbeat cada 30s ------------------------- */
/* Tiempo real de sesion, no diferencia de timestamps: evita inflar el tiempo
   dejando la pestana abierta. Retencion 90 dias.                          */
IF OBJECT_ID(N'dlv.LearningActivity', N'U') IS NULL
CREATE TABLE dlv.LearningActivity (
      LearningActivityId BIGINT          NOT NULL IDENTITY(1,1)
    , EnrollmentId      INT              NOT NULL
    , ModuleItemId      INT              NULL
    , SessionId         UNIQUEIDENTIFIER NULL
    , HeartbeatAtUtc    DATETIME2(3)     NOT NULL CONSTRAINT DF_LearningActivity_AtUtc DEFAULT SYSUTCDATETIME()
    , IntervalSeconds   SMALLINT         NOT NULL CONSTRAINT DF_LearningActivity_Interval DEFAULT 30
    , IsActive          BIT              NOT NULL CONSTRAINT DF_LearningActivity_IsActive DEFAULT 1
    , CONSTRAINT PK_LearningActivity PRIMARY KEY CLUSTERED (LearningActivityId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_LearningActivity_Enrollment' AND object_id = OBJECT_ID(N'dlv.LearningActivity'))
    CREATE NONCLUSTERED INDEX IX_LearningActivity_Enrollment ON dlv.LearningActivity (EnrollmentId, HeartbeatAtUtc);
GO

/* =============================================================================
   SESIONES PRESENCIALES (ILT) - ~70% del entrenamiento real en planta
   ============================================================================= */

IF OBJECT_ID(N'dlv.TrainingSession', N'U') IS NULL
CREATE TABLE dlv.TrainingSession (
      TrainingSessionId INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_TrainingSession_PublicId DEFAULT NEWID()
    , CourseId          INT              NOT NULL
    , CourseVersionId   INT              NOT NULL
    , CohortId          INT              NULL
    , SessionCode       NVARCHAR(40)     NOT NULL
    , TitleEs           NVARCHAR(250)    NOT NULL
    , TitleEn           NVARCHAR(250)    NULL
    , InstructorEmployeeId INT           NOT NULL
    , SecondaryInstructorEmployeeId INT  NULL
    , LocationType      TINYINT          NOT NULL CONSTRAINT DF_TrainingSession_LocationType DEFAULT 1
                                         -- 1=Room 2=ProductionLine 3=Station 4=Virtual 5=External
    , LocationName      NVARCHAR(200)    NULL
    , SiteId            INT              NULL
    , AreaId            INT              NULL
    , StationId         INT              NULL
    , VirtualMeetingUrl NVARCHAR(1000)   NULL
    , LocaleCode        NVARCHAR(10)     NOT NULL CONSTRAINT DF_TrainingSession_Locale DEFAULT N'es-DO'
    , ScheduledStartUtc DATETIME2(3)     NOT NULL
    , ScheduledEndUtc   DATETIME2(3)     NOT NULL
    , ActualStartUtc    DATETIME2(3)     NULL
    , ActualEndUtc      DATETIME2(3)     NULL
    , RequiredMinutes   INT              NULL       -- minutos minimos para acreditar
    , MinParticipants   INT              NULL
    , MaxParticipants   INT              NULL
    , AllowWaitlist     BIT              NOT NULL CONSTRAINT DF_TrainingSession_AllowWaitlist DEFAULT 1
    , RecurrenceGroupId UNIQUEIDENTIFIER NULL       -- serie recurrente
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_TrainingSession_Status DEFAULT 1
        /* 1=Scheduled 2=Open 3=Full 4=InProgress 5=Completed 6=Cancelled */
    , CancelReason      NVARCHAR(1000)   NULL
    , CancelledAtUtc    DATETIME2(3)     NULL
    , CancelledByUserId INT              NULL
    , RosterSignatureId BIGINT           NULL       -- firma del instructor
    , ClosedAtUtc       DATETIME2(3)     NULL
    , ClosedByUserId    INT              NULL
    , InstructorNotes   NVARCHAR(MAX)    NULL
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_TrainingSession_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_TrainingSession_IsDeleted DEFAULT 0
    , CONSTRAINT PK_TrainingSession PRIMARY KEY CLUSTERED (TrainingSessionId)
    , CONSTRAINT UQ_TrainingSession_Code UNIQUE (SessionCode)
    , CONSTRAINT UQ_TrainingSession_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT FK_TrainingSession_Course        FOREIGN KEY (CourseId)        REFERENCES lms.Course (CourseId)
    , CONSTRAINT FK_TrainingSession_CourseVersion FOREIGN KEY (CourseVersionId) REFERENCES lms.CourseVersion (CourseVersionId)
    , CONSTRAINT FK_TrainingSession_Instructor    FOREIGN KEY (InstructorEmployeeId) REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT CK_TrainingSession_Status CHECK ([Status] BETWEEN 1 AND 6)
    , CONSTRAINT CK_TrainingSession_Schedule CHECK (ScheduledEndUtc > ScheduledStartUtc)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_TrainingSession_Instructor_Schedule' AND object_id = OBJECT_ID(N'dlv.TrainingSession'))
    CREATE NONCLUSTERED INDEX IX_TrainingSession_Instructor_Schedule
        ON dlv.TrainingSession (InstructorEmployeeId, ScheduledStartUtc, ScheduledEndUtc)
        WHERE [Status] NOT IN (6) AND IsDeleted = 0;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_TrainingSession_Upcoming' AND object_id = OBJECT_ID(N'dlv.TrainingSession'))
    CREATE NONCLUSTERED INDEX IX_TrainingSession_Upcoming ON dlv.TrainingSession (ScheduledStartUtc)
        INCLUDE (CourseId, [Status], MaxParticipants) WHERE IsDeleted = 0;
GO

IF OBJECT_ID(N'dlv.SessionRegistration', N'U') IS NULL
CREATE TABLE dlv.SessionRegistration (
      SessionRegistrationId INT          NOT NULL IDENTITY(1,1)
    , TrainingSessionId INT              NOT NULL
    , EmployeeId        INT              NOT NULL
    , EnrollmentId      INT              NULL
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_SessionRegistration_Status DEFAULT 1
        /* 1=Registered 2=Waitlisted 3=Confirmed 4=Cancelled 5=NoShow */
    , WaitlistPosition  INT              NULL
    , RegisteredAtUtc   DATETIME2(3)     NOT NULL CONSTRAINT DF_SessionRegistration_RegisteredAtUtc DEFAULT SYSUTCDATETIME()
    , RegisteredByUserId INT             NULL
    , ConfirmedAtUtc    DATETIME2(3)     NULL
    , CancelledAtUtc    DATETIME2(3)     NULL
    , CancelReason      NVARCHAR(400)    NULL
    , PromotedFromWaitlistAtUtc DATETIME2(3) NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_SessionRegistration PRIMARY KEY CLUSTERED (SessionRegistrationId)
    , CONSTRAINT UQ_SessionRegistration UNIQUE (TrainingSessionId, EmployeeId)
    , CONSTRAINT FK_SessionRegistration_Session  FOREIGN KEY (TrainingSessionId) REFERENCES dlv.TrainingSession (TrainingSessionId)
    , CONSTRAINT FK_SessionRegistration_Employee FOREIGN KEY (EmployeeId)        REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT CK_SessionRegistration_Status CHECK ([Status] BETWEEN 1 AND 5)
);
GO

IF OBJECT_ID(N'dlv.SessionAttendance', N'U') IS NULL
CREATE TABLE dlv.SessionAttendance (
      SessionAttendanceId INT            NOT NULL IDENTITY(1,1)
    , TrainingSessionId INT              NOT NULL
    , EmployeeId        INT              NOT NULL
    , EnrollmentId      INT              NULL
    , AttendanceStatus  TINYINT          NOT NULL CONSTRAINT DF_SessionAttendance_Status DEFAULT 1
        /* 1=Present 2=Late 3=LeftEarly 4=Absent 5=Excused */
    , CheckInAtUtc      DATETIME2(3)     NULL
    , CheckOutAtUtc     DATETIME2(3)     NULL
    , MinutesAttended   INT              NULL
    , CheckInMethod     TINYINT          NULL       -- 1=BadgeScan 2=EmployeeCode 3=Manual
    , DeviceId          INT              NULL
    , RecordedByUserId  INT              NOT NULL
    , ResultCode        TINYINT          NULL       -- 1=Passed 2=Failed 3=Incomplete
    , ParticipantSignatureId BIGINT      NULL
    , Notes             NVARCHAR(1000)   NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_SessionAttendance PRIMARY KEY CLUSTERED (SessionAttendanceId)
    , CONSTRAINT UQ_SessionAttendance UNIQUE (TrainingSessionId, EmployeeId)
    , CONSTRAINT FK_SessionAttendance_Session  FOREIGN KEY (TrainingSessionId) REFERENCES dlv.TrainingSession (TrainingSessionId)
    , CONSTRAINT FK_SessionAttendance_Employee FOREIGN KEY (EmployeeId)        REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT CK_SessionAttendance_Status CHECK (AttendanceStatus BETWEEN 1 AND 5)
);
GO

IF OBJECT_ID(N'dlv.SessionMaterial', N'U') IS NULL
CREATE TABLE dlv.SessionMaterial (
      SessionMaterialId INT              NOT NULL IDENTITY(1,1)
    , TrainingSessionId INT              NOT NULL
    , FileAssetId       INT              NULL
    , DocumentRevisionId INT             NULL       -- WI usada en la sesion
    , [Description]     NVARCHAR(400)    NULL
    , UploadedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_SessionMaterial_UploadedAtUtc DEFAULT SYSUTCDATETIME()
    , UploadedByUserId  INT              NOT NULL
    , CONSTRAINT PK_SessionMaterial PRIMARY KEY CLUSTERED (SessionMaterialId)
    , CONSTRAINT FK_SessionMaterial_Session FOREIGN KEY (TrainingSessionId) REFERENCES dlv.TrainingSession (TrainingSessionId)
);
GO

PRINT '=== 06_tables_delivery.sql completado ===';
GO
