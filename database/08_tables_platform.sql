/* =============================================================================
   Classroom LMS by Airlink
   08_tables_platform.sql  -  aud (auditoria), intg (integracion), ops (plataforma)
   ============================================================================= */
USE AIRLINK_LMS;
GO
SET NOCOUNT ON;
GO

/* =============================================================================
   AUD - AUDITORIA
   ============================================================================= */

/* --- aud.EventLog : particionada por mes en PROD ----------------------- */
IF OBJECT_ID(N'aud.EventLog', N'U') IS NULL
CREATE TABLE aud.EventLog (
      EventLogId        BIGINT           NOT NULL IDENTITY(1,1)
    , OccurredAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_EventLog_OccurredAtUtc DEFAULT SYSUTCDATETIME()
    , ActorUserId       INT              NULL
    , ActorEmployeeId   INT              NULL
    , EntityType        NVARCHAR(60)     NOT NULL   -- 'Certification','Enrollment',...
    , EntityId          INT              NULL
    , EntityPublicId    UNIQUEIDENTIFIER NULL
    , [Action]          NVARCHAR(60)     NOT NULL   -- 'Created','Published','Revoked',...
    , Severity          TINYINT          NOT NULL CONSTRAINT DF_EventLog_Severity DEFAULT 2
                                         -- 1=Info 2=Notable 3=Sensitive 4=Critical
    , [Description]     NVARCHAR(1000)   NULL
    , OldValuesJson     NVARCHAR(MAX)    NULL
    , NewValuesJson     NVARCHAR(MAX)    NULL
    , ProcedureName     NVARCHAR(150)    NULL
    , SessionId         UNIQUEIDENTIFIER NULL
    , DeviceId          INT              NULL
    , IpAddress         NVARCHAR(45)     NULL
    , CorrelationId     UNIQUEIDENTIFIER NULL
    , CONSTRAINT PK_EventLog PRIMARY KEY CLUSTERED (EventLogId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_EventLog_Entity' AND object_id = OBJECT_ID(N'aud.EventLog'))
    CREATE NONCLUSTERED INDEX IX_EventLog_Entity ON aud.EventLog (EntityType, EntityId, OccurredAtUtc DESC)
        INCLUDE (ActorUserId, [Action], Severity);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_EventLog_Actor_Time' AND object_id = OBJECT_ID(N'aud.EventLog'))
    CREATE NONCLUSTERED INDEX IX_EventLog_Actor_Time ON aud.EventLog (ActorUserId, OccurredAtUtc DESC);
GO

/* --- aud.ErrorLog ------------------------------------------------------ */
IF OBJECT_ID(N'aud.ErrorLog', N'U') IS NULL
CREATE TABLE aud.ErrorLog (
      ErrorLogId        BIGINT           NOT NULL IDENTITY(1,1)
    , OccurredAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_ErrorLog_OccurredAtUtc DEFAULT SYSUTCDATETIME()
    , ProcedureName     NVARCHAR(150)    NULL
    , ErrorNumber       INT              NULL
    , ErrorSeverity     INT              NULL
    , ErrorState        INT              NULL
    , ErrorLine         INT              NULL
    , ErrorMessage      NVARCHAR(4000)   NULL
    , ActorUserId       INT              NULL
    , ParametersJson    NVARCHAR(MAX)    NULL
    , CorrelationId     UNIQUEIDENTIFIER NULL
    , CONSTRAINT PK_ErrorLog PRIMARY KEY CLUSTERED (ErrorLogId)
);
GO

/* --- aud.SignatureRecord : cadena de hashes por empleado -------------- */
/* Hash = SHA256(PayloadCanonico + '|' + PreviousHash).
   Alterar una firma rompe todas las posteriores del mismo empleado.
   Ver docs/06-seguridad-y-rbac.md seccion 5.                            */
IF OBJECT_ID(N'aud.SignatureRecord', N'U') IS NULL
CREATE TABLE aud.SignatureRecord (
      SignatureId       BIGINT           NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_SignatureRecord_PublicId DEFAULT NEWID()
    , EmployeeId        INT              NOT NULL
    , UserId            INT              NOT NULL
    , SignatureType     TINYINT          NOT NULL
        /* 1=DocumentAcknowledgment 2=SessionAttendance 3=InstructorRoster
           4=PracticalEvaluator 5=PracticalEmployee 6=CertificationIssue
           7=WaiverApproval 8=DocumentApproval 9=QuizSubmission */
    , EntityType        NVARCHAR(60)     NOT NULL
    , EntityId          INT              NOT NULL
    , PayloadCanonical  NVARCHAR(2000)   NOT NULL   -- JSON con claves ordenadas
    , PayloadHash       VARBINARY(32)    NOT NULL   -- SHA-256
    , PreviousHash      VARBINARY(32)    NULL       -- NULL = genesis del empleado
    , SequenceNumber    INT              NOT NULL   -- ordinal por empleado
    , AuthMethod        TINYINT          NOT NULL   -- 1=Pin 2=EntraId 3=Biometric
    , SignedAtUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_SignatureRecord_SignedAtUtc DEFAULT SYSUTCDATETIME()
    , DeviceId          INT              NULL
    , IpAddress         NVARCHAR(45)     NULL
    , CONSTRAINT PK_SignatureRecord PRIMARY KEY CLUSTERED (SignatureId)
    , CONSTRAINT UQ_SignatureRecord_Sequence UNIQUE (EmployeeId, SequenceNumber)
    , CONSTRAINT UQ_SignatureRecord_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT FK_SignatureRecord_Employee FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_SignatureRecord_Entity' AND object_id = OBJECT_ID(N'aud.SignatureRecord'))
    CREATE NONCLUSTERED INDEX IX_SignatureRecord_Entity ON aud.SignatureRecord (EntityType, EntityId);
GO

/* --- aud.DataAccessLog : quien leyo el expediente de quien ----------- */
IF OBJECT_ID(N'aud.DataAccessLog', N'U') IS NULL
CREATE TABLE aud.DataAccessLog (
      DataAccessLogId   BIGINT           NOT NULL IDENTITY(1,1)
    , AccessedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_DataAccessLog_AtUtc DEFAULT SYSUTCDATETIME()
    , ActorUserId       INT              NOT NULL
    , SubjectEmployeeId INT              NOT NULL
    , AccessType        TINYINT          NOT NULL   -- 1=TrainingRecord 2=Certification 3=Export 4=AuditPackage
    , [Context]         NVARCHAR(200)    NULL
    , CONSTRAINT PK_DataAccessLog PRIMARY KEY CLUSTERED (DataAccessLogId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DataAccessLog_Subject' AND object_id = OBJECT_ID(N'aud.DataAccessLog'))
    CREATE NONCLUSTERED INDEX IX_DataAccessLog_Subject ON aud.DataAccessLog (SubjectEmployeeId, AccessedAtUtc DESC);
GO

/* --- aud.IdempotencyKey ---------------------------------------------- */
IF OBJECT_ID(N'aud.IdempotencyKey', N'U') IS NULL
CREATE TABLE aud.IdempotencyKey (
      IdempotencyKey    UNIQUEIDENTIFIER NOT NULL
    , OperationName     NVARCHAR(150)    NOT NULL
    , ActorUserId       INT              NULL
    , ResultEntityId    INT              NULL
    , ResultJson        NVARCHAR(MAX)    NULL
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_IdempotencyKey_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , ExpiresAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_IdempotencyKey_ExpiresAtUtc DEFAULT DATEADD(HOUR, 24, SYSUTCDATETIME())
    , CONSTRAINT PK_IdempotencyKey PRIMARY KEY CLUSTERED (IdempotencyKey)
);
GO

/* =============================================================================
   INTG - INTEGRACION
   ============================================================================= */

IF OBJECT_ID(N'intg.SyncWatermark', N'U') IS NULL
CREATE TABLE intg.SyncWatermark (
      SourceKey         NVARCHAR(80)     NOT NULL   -- 'SPN.Employee'
    , WatermarkValue    NVARCHAR(100)    NULL       -- timestamp o rowversion serializado
    , WatermarkAtUtc    DATETIME2(3)     NULL
    , LastRunAtUtc      DATETIME2(3)     NULL
    , LastSuccessAtUtc  DATETIME2(3)     NULL
    , ConsecutiveFailures INT            NOT NULL CONSTRAINT DF_SyncWatermark_Failures DEFAULT 0
    , CONSTRAINT PK_SyncWatermark PRIMARY KEY CLUSTERED (SourceKey)
);
GO

IF OBJECT_ID(N'intg.SyncRun', N'U') IS NULL
CREATE TABLE intg.SyncRun (
      SyncRunId         BIGINT           NOT NULL IDENTITY(1,1)
    , SourceKey         NVARCHAR(80)     NOT NULL
    , RunType           TINYINT          NOT NULL   -- 1=Incremental 2=Full 3=Manual
    , StartedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_SyncRun_StartedAtUtc DEFAULT SYSUTCDATETIME()
    , FinishedAtUtc     DATETIME2(3)     NULL
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_SyncRun_Status DEFAULT 1
                                         -- 1=Running 2=Success 3=PartialSuccess 4=Failed
    , RowsRead          INT              NOT NULL CONSTRAINT DF_SyncRun_RowsRead DEFAULT 0
    , RowsInserted      INT              NOT NULL CONSTRAINT DF_SyncRun_RowsInserted DEFAULT 0
    , RowsUpdated       INT              NOT NULL CONSTRAINT DF_SyncRun_RowsUpdated DEFAULT 0
    , RowsDeactivated   INT              NOT NULL CONSTRAINT DF_SyncRun_RowsDeactivated DEFAULT 0
    , RowsRejected      INT              NOT NULL CONSTRAINT DF_SyncRun_RowsRejected DEFAULT 0
    , ErrorMessage      NVARCHAR(4000)   NULL
    , CONSTRAINT PK_SyncRun PRIMARY KEY CLUSTERED (SyncRunId)
);
GO

IF OBJECT_ID(N'intg.EmployeeStaging', N'U') IS NULL
CREATE TABLE intg.EmployeeStaging (
      EmployeeStagingId INT              NOT NULL IDENTITY(1,1)
    , SyncRunId         BIGINT           NOT NULL
    , EmployeeCode      NVARCHAR(30)     NOT NULL
    , FirstName         NVARCHAR(100)    NULL
    , LastName          NVARCHAR(100)    NULL
    , NationalId        NVARCHAR(30)     NULL
    , Email             NVARCHAR(256)    NULL
    , Phone             NVARCHAR(30)     NULL
    , PositionCode      NVARCHAR(40)     NULL
    , PositionName      NVARCHAR(150)    NULL
    , DepartmentCode    NVARCHAR(30)     NULL
    , DepartmentName    NVARCHAR(150)    NULL
    , SiteCode          NVARCHAR(20)     NULL
    , ShiftCode         NVARCHAR(20)     NULL
    , SupervisorEmployeeCode NVARCHAR(30) NULL
    , HireDate          DATETIME2(3)     NULL
    , TerminationDate   DATETIME2(3)     NULL
    , SourceStatus      NVARCHAR(30)     NULL
    , IsActive          BIT              NULL
    , SourceHash        VARBINARY(32)    NULL
    , ValidationStatus  TINYINT          NOT NULL CONSTRAINT DF_EmployeeStaging_Validation DEFAULT 0
                                         -- 0=Pending 1=Valid 2=Rejected
    , ValidationMessage NVARCHAR(1000)   NULL
    , LoadedAtUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_EmployeeStaging_LoadedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_EmployeeStaging PRIMARY KEY CLUSTERED (EmployeeStagingId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_EmployeeStaging_Run_Code' AND object_id = OBJECT_ID(N'intg.EmployeeStaging'))
    CREATE NONCLUSTERED INDEX IX_EmployeeStaging_Run_Code ON intg.EmployeeStaging (SyncRunId, EmployeeCode);
GO

IF OBJECT_ID(N'intg.IntegrationError', N'U') IS NULL
CREATE TABLE intg.IntegrationError (
      IntegrationErrorId BIGINT          NOT NULL IDENTITY(1,1)
    , SyncRunId         BIGINT           NULL
    , SourceKey         NVARCHAR(80)     NOT NULL
    , RecordKey         NVARCHAR(100)    NULL
    , ErrorType         TINYINT          NOT NULL   -- 1=Validation 2=Mapping 3=Constraint 4=Unexpected
    , ErrorMessage      NVARCHAR(2000)   NOT NULL
    , RawDataJson       NVARCHAR(MAX)    NULL
    , OccurredAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_IntegrationError_AtUtc DEFAULT SYSUTCDATETIME()
    , IsResolved        BIT              NOT NULL CONSTRAINT DF_IntegrationError_IsResolved DEFAULT 0
    , ResolvedAtUtc     DATETIME2(3)     NULL
    , ResolvedByUserId  INT              NULL
    , CONSTRAINT PK_IntegrationError PRIMARY KEY CLUSTERED (IntegrationErrorId)
);
GO

IF OBJECT_ID(N'intg.ExternalIdMap', N'U') IS NULL
CREATE TABLE intg.ExternalIdMap (
      ExternalIdMapId   INT              NOT NULL IDENTITY(1,1)
    , SystemCode        NVARCHAR(30)     NOT NULL   -- 'SPN','AIRLINK','NEXUS','ENTRA'
    , EntityType        NVARCHAR(60)     NOT NULL
    , ExternalId        NVARCHAR(100)    NOT NULL
    , InternalId        INT              NOT NULL
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_ExternalIdMap_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_ExternalIdMap PRIMARY KEY CLUSTERED (ExternalIdMapId)
    , CONSTRAINT UQ_ExternalIdMap UNIQUE (SystemCode, EntityType, ExternalId)
);
GO

/* =============================================================================
   OPS - PLATAFORMA
   ============================================================================= */

IF OBJECT_ID(N'ops.Setting', N'U') IS NULL
CREATE TABLE ops.Setting (
      SettingId         INT              NOT NULL IDENTITY(1,1)
    , SettingKey        NVARCHAR(100)    NOT NULL
    , ScopeType         TINYINT          NOT NULL CONSTRAINT DF_Setting_ScopeType DEFAULT 1
                                         -- 1=Global 2=Site 3=Department
    , ScopeId           INT              NULL
    , SettingValue      NVARCHAR(MAX)    NULL
    , DataType          NVARCHAR(20)     NOT NULL CONSTRAINT DF_Setting_DataType DEFAULT N'string'
                                         -- string|int|bool|decimal|json
    , [Description]     NVARCHAR(400)    NULL
    , IsEncrypted       BIT              NOT NULL CONSTRAINT DF_Setting_IsEncrypted DEFAULT 0
    , ModifiedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_Setting_ModifiedAtUtc DEFAULT SYSUTCDATETIME()
    , ModifiedByUserId  INT              NULL
    , CONSTRAINT PK_Setting PRIMARY KEY CLUSTERED (SettingId)
    , CONSTRAINT UQ_Setting UNIQUE (SettingKey, ScopeType, ScopeId)
);
GO

IF OBJECT_ID(N'ops.FeatureFlag', N'U') IS NULL
CREATE TABLE ops.FeatureFlag (
      FeatureFlagId     INT              NOT NULL IDENTITY(1,1)
    , FlagKey           NVARCHAR(80)     NOT NULL
    , [Description]     NVARCHAR(400)    NULL
    , IsEnabled         BIT              NOT NULL CONSTRAINT DF_FeatureFlag_IsEnabled DEFAULT 0
    , AudienceType      TINYINT          NOT NULL CONSTRAINT DF_FeatureFlag_AudienceType DEFAULT 1
                                         -- 1=All 2=Role 3=Department 4=Site 5=UserList
    , AudienceValue     NVARCHAR(500)    NULL
    , ModifiedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_FeatureFlag_ModifiedAtUtc DEFAULT SYSUTCDATETIME()
    , ModifiedByUserId  INT              NULL
    , CONSTRAINT PK_FeatureFlag PRIMARY KEY CLUSTERED (FeatureFlagId)
    , CONSTRAINT UQ_FeatureFlag_Key UNIQUE (FlagKey)
);
GO

IF OBJECT_ID(N'ops.NotificationTemplate', N'U') IS NULL
CREATE TABLE ops.NotificationTemplate (
      NotificationTemplateId INT         NOT NULL IDENTITY(1,1)
    , TemplateKey       NVARCHAR(80)     NOT NULL   -- 'enrollment.assigned'
    , LocaleCode        NVARCHAR(10)     NOT NULL
    , Channel           TINYINT          NOT NULL   -- 1=Email 2=Teams 3=InApp 4=Sms
    , [Subject]         NVARCHAR(300)    NULL
    , BodyTemplate      NVARCHAR(MAX)    NOT NULL   -- placeholders {{EmployeeName}}
    , IsActive          BIT              NOT NULL CONSTRAINT DF_NotificationTemplate_IsActive DEFAULT 1
    , ModifiedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_NotificationTemplate_ModifiedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_NotificationTemplate PRIMARY KEY CLUSTERED (NotificationTemplateId)
    , CONSTRAINT UQ_NotificationTemplate UNIQUE (TemplateKey, LocaleCode, Channel)
);
GO

/* --- ops.NotificationQueue -------------------------------------------- */
/* ADR-008: los SPs encolan, un worker externo envia. Nunca sp_send_dbmail
   dentro de una transaccion de negocio.                                  */
IF OBJECT_ID(N'ops.NotificationQueue', N'U') IS NULL
CREATE TABLE ops.NotificationQueue (
      NotificationId    BIGINT           NOT NULL IDENTITY(1,1)
    , TemplateKey       NVARCHAR(80)     NOT NULL
    , Channel           TINYINT          NOT NULL
    , LocaleCode        NVARCHAR(10)     NOT NULL CONSTRAINT DF_NotificationQueue_Locale DEFAULT N'es-DO'
    , RecipientUserId   INT              NULL
    , RecipientEmployeeId INT            NULL
    , RecipientAddress  NVARCHAR(300)    NULL
    , PayloadJson       NVARCHAR(MAX)    NOT NULL   -- variables del template
    , Priority          TINYINT          NOT NULL CONSTRAINT DF_NotificationQueue_Priority DEFAULT 3
                                         -- 1=Critical 2=High 3=Normal 4=Low
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_NotificationQueue_Status DEFAULT 1
                                         -- 1=Pending 2=Processing 3=Sent 4=Failed 5=DeadLetter
    , AttemptCount      TINYINT          NOT NULL CONSTRAINT DF_NotificationQueue_AttemptCount DEFAULT 0
    , MaxAttempts       TINYINT          NOT NULL CONSTRAINT DF_NotificationQueue_MaxAttempts DEFAULT 5
    , NextAttemptAtUtc  DATETIME2(3)     NOT NULL CONSTRAINT DF_NotificationQueue_NextAttempt DEFAULT SYSUTCDATETIME()
    , EnqueuedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_NotificationQueue_EnqueuedAtUtc DEFAULT SYSUTCDATETIME()
    , SentAtUtc         DATETIME2(3)     NULL
    , LastError         NVARCHAR(2000)   NULL
    , CorrelationId     UNIQUEIDENTIFIER NULL
    , CONSTRAINT PK_NotificationQueue PRIMARY KEY CLUSTERED (NotificationId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_NotificationQueue_Pending' AND object_id = OBJECT_ID(N'ops.NotificationQueue'))
    CREATE NONCLUSTERED INDEX IX_NotificationQueue_Pending
        ON ops.NotificationQueue (NextAttemptAtUtc, Priority)
        INCLUDE (Channel, TemplateKey) WHERE [Status] IN (1,4);
GO

IF OBJECT_ID(N'ops.FileAsset', N'U') IS NULL
CREATE TABLE ops.FileAsset (
      FileAssetId       INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_FileAsset_PublicId DEFAULT NEWID()
    , FileName          NVARCHAR(300)    NOT NULL
    , ContentType       NVARCHAR(150)    NOT NULL
    , SizeBytes         BIGINT           NOT NULL
    , StorageProvider   TINYINT          NOT NULL CONSTRAINT DF_FileAsset_StorageProvider DEFAULT 1
                                         -- 1=FileShare 2=AzureBlob 3=S3
    , StoragePath       NVARCHAR(1000)   NOT NULL
    , ContentHash       VARBINARY(32)    NULL       -- SHA-256, deduplicacion e integridad
    , OwnerEntityType   NVARCHAR(60)     NULL
    , OwnerEntityId     INT              NULL
    , IsPublic          BIT              NOT NULL CONSTRAINT DF_FileAsset_IsPublic DEFAULT 0
    , UploadedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_FileAsset_UploadedAtUtc DEFAULT SYSUTCDATETIME()
    , UploadedByUserId  INT              NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_FileAsset_IsDeleted DEFAULT 0
    , DeletedAtUtc      DATETIME2(3)     NULL
    , CONSTRAINT PK_FileAsset PRIMARY KEY CLUSTERED (FileAssetId)
    , CONSTRAINT UQ_FileAsset_PublicId UNIQUE NONCLUSTERED (PublicId)
);
GO

IF OBJECT_ID(N'ops.JobRun', N'U') IS NULL
CREATE TABLE ops.JobRun (
      JobRunId          BIGINT           NOT NULL IDENTITY(1,1)
    , JobName           NVARCHAR(100)    NOT NULL
    , StartedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_JobRun_StartedAtUtc DEFAULT SYSUTCDATETIME()
    , FinishedAtUtc     DATETIME2(3)     NULL
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_JobRun_Status DEFAULT 1
                                         -- 1=Running 2=Success 3=Warning 4=Failed
    , RecordsProcessed  INT              NOT NULL CONSTRAINT DF_JobRun_RecordsProcessed DEFAULT 0
    , DurationMs        INT              NULL
    , Message           NVARCHAR(2000)   NULL
    , CONSTRAINT PK_JobRun PRIMARY KEY CLUSTERED (JobRunId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_JobRun_Name_Time' AND object_id = OBJECT_ID(N'ops.JobRun'))
    CREATE NONCLUSTERED INDEX IX_JobRun_Name_Time ON ops.JobRun (JobName, StartedAtUtc DESC);
GO

IF OBJECT_ID(N'ops.AppLog', N'U') IS NULL
CREATE TABLE ops.AppLog (
      AppLogId          BIGINT           NOT NULL IDENTITY(1,1)
    , LoggedAtUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_AppLog_LoggedAtUtc DEFAULT SYSUTCDATETIME()
    , [Level]           NVARCHAR(20)     NOT NULL   -- Information|Warning|Error|Critical
    , [Source]          NVARCHAR(150)    NULL
    , Message           NVARCHAR(4000)   NOT NULL
    , ExceptionDetail   NVARCHAR(MAX)    NULL
    , ActorUserId       INT              NULL
    , CorrelationId     UNIQUEIDENTIFIER NULL
    , CONSTRAINT PK_AppLog PRIMARY KEY CLUSTERED (AppLogId)
);
GO

PRINT '=== 08_tables_platform.sql completado ===';
GO
