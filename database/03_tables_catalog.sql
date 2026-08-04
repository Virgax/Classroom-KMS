/* =============================================================================
   Classroom LMS by Airlink
   03_tables_catalog.sql  -  lms: cursos, versiones, programas, categorias
   ============================================================================= */
USE AIRLINK_KMS;
GO
SET NOCOUNT ON;
GO

/* --- lms.CourseCategory (jerarquica) ------------------------------------- */
IF OBJECT_ID(N'lms.CourseCategory', N'U') IS NULL
CREATE TABLE lms.CourseCategory (
      CourseCategoryId  INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_CourseCategory_PublicId DEFAULT NEWID()
    , ParentCategoryId  INT              NULL
    , CategoryCode      NVARCHAR(40)     NOT NULL
    , NameEs            NVARCHAR(150)    NOT NULL
    , NameEn            NVARCHAR(150)    NULL
    , SortOrder         INT              NOT NULL CONSTRAINT DF_CourseCategory_SortOrder DEFAULT 0
    , IsActive          BIT              NOT NULL CONSTRAINT DF_CourseCategory_IsActive DEFAULT 1
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_CourseCategory_IsDeleted DEFAULT 0
    , CONSTRAINT PK_CourseCategory PRIMARY KEY CLUSTERED (CourseCategoryId)
    , CONSTRAINT UQ_CourseCategory_Code UNIQUE (CategoryCode)
    , CONSTRAINT FK_CourseCategory_Parent FOREIGN KEY (ParentCategoryId) REFERENCES lms.CourseCategory (CourseCategoryId)
);
GO

/* --- lms.Course : entidad estable. El contenido vive en CourseVersion. ---- */
IF OBJECT_ID(N'lms.Course', N'U') IS NULL
CREATE TABLE lms.Course (
      CourseId          INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Course_PublicId DEFAULT NEWID()
    , CourseCode        NVARCHAR(40)     NOT NULL   -- 'CRS-IQC-001'
    , NameEs            NVARCHAR(250)    NOT NULL
    , NameEn            NVARCHAR(250)    NULL
    , CourseCategoryId  INT              NULL
    , DeliveryType      TINYINT          NOT NULL CONSTRAINT DF_Course_DeliveryType DEFAULT 1
        /* 1=ELearning 2=InstructorLed 3=Blended 4=DocumentAcknowledgment
           5=OnTheJob 6=External */
    , OwnerDepartmentId INT              NULL
    , OwnerUserId       INT              NULL
    , EstimatedMinutes  INT              NULL
    , IsBlueprint       BIT              NOT NULL CONSTRAINT DF_Course_IsBlueprint DEFAULT 0
    , BlueprintCourseId INT              NULL       -- si es derivado de un maestro
    , AllowSelfEnrollment BIT            NOT NULL CONSTRAINT DF_Course_AllowSelfEnroll DEFAULT 0
    , CurrentVersionId  INT              NULL       -- version publicada vigente
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_Course_Status DEFAULT 1
                                         -- 1=Active 2=Retired
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Course_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Course_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Course PRIMARY KEY CLUSTERED (CourseId)
    , CONSTRAINT UQ_Course_Code UNIQUE (CourseCode)
    , CONSTRAINT UQ_Course_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT FK_Course_Category   FOREIGN KEY (CourseCategoryId)  REFERENCES lms.CourseCategory (CourseCategoryId)
    , CONSTRAINT FK_Course_Blueprint  FOREIGN KEY (BlueprintCourseId) REFERENCES lms.Course (CourseId)
    , CONSTRAINT FK_Course_Department FOREIGN KEY (OwnerDepartmentId) REFERENCES org.Department (DepartmentId)
    , CONSTRAINT CK_Course_DeliveryType CHECK (DeliveryType BETWEEN 1 AND 6)
    , CONSTRAINT CK_Course_Status       CHECK ([Status] IN (1,2))
);
GO

/* --- lms.CourseVersion : TEMPORAL. Inmutable al publicar. ---------------- */
IF OBJECT_ID(N'lms.CourseVersion', N'U') IS NULL
BEGIN
    CREATE TABLE lms.CourseVersion (
          CourseVersionId   INT              NOT NULL IDENTITY(1,1)
        , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_CourseVersion_PublicId DEFAULT NEWID()
        , CourseId          INT              NOT NULL
        , VersionNumber     INT              NOT NULL
        , VersionLabel      NVARCHAR(20)     NULL       -- 'Rev.1'
        , [Status]          TINYINT          NOT NULL CONSTRAINT DF_CourseVersion_Status DEFAULT 1
            /* 1=Draft 2=InReview 3=Published 4=Retired 5=Rejected */
        , DescriptionEs     NVARCHAR(MAX)    NULL
        , DescriptionEn     NVARCHAR(MAX)    NULL
        , ObjectivesEs      NVARCHAR(MAX)    NULL
        , ObjectivesEn      NVARCHAR(MAX)    NULL
        , PassingScore      DECIMAL(5,2)     NOT NULL CONSTRAINT DF_CourseVersion_PassingScore DEFAULT 80.00
        , MaxAttempts       TINYINT          NOT NULL CONSTRAINT DF_CourseVersion_MaxAttempts DEFAULT 3
        , EnforceSequence   BIT              NOT NULL CONSTRAINT DF_CourseVersion_EnforceSeq DEFAULT 1
        , EnforceMinimumTime BIT             NOT NULL CONSTRAINT DF_CourseVersion_EnforceTime DEFAULT 0
        , RequiresRetraining BIT             NOT NULL CONSTRAINT DF_CourseVersion_RequiresRetrain DEFAULT 0
            /* 1 = al publicar, invalida certificaciones basadas en la version anterior */
        , ChangeSummary     NVARCHAR(1000)   NULL
        , PublishedAtUtc    DATETIME2(3)     NULL
        , PublishedByUserId INT              NULL
        , RetiredAtUtc      DATETIME2(3)     NULL
        , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_CourseVersion_CreatedAtUtc DEFAULT SYSUTCDATETIME()
        , CreatedByUserId   INT              NOT NULL
        , ModifiedAtUtc     DATETIME2(3)     NULL
        , ModifiedByUserId  INT              NULL
        , ValidFromUtc      DATETIME2(3)     GENERATED ALWAYS AS ROW START NOT NULL
        , ValidToUtc        DATETIME2(3)     GENERATED ALWAYS AS ROW END   NOT NULL
        , PERIOD FOR SYSTEM_TIME (ValidFromUtc, ValidToUtc)
        , CONSTRAINT PK_CourseVersion PRIMARY KEY CLUSTERED (CourseVersionId)
        , CONSTRAINT UQ_CourseVersion UNIQUE (CourseId, VersionNumber)
        , CONSTRAINT UQ_CourseVersion_PublicId UNIQUE NONCLUSTERED (PublicId)
        , CONSTRAINT CK_CourseVersion_Status CHECK ([Status] BETWEEN 1 AND 5)
        , CONSTRAINT CK_CourseVersion_PassingScore CHECK (PassingScore BETWEEN 0 AND 100)
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = lms.CourseVersionHistory));

    ALTER TABLE lms.CourseVersion ADD CONSTRAINT FK_CourseVersion_Course
        FOREIGN KEY (CourseId) REFERENCES lms.Course (CourseId);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Course_CurrentVersion')
    ALTER TABLE lms.Course ADD CONSTRAINT FK_Course_CurrentVersion
        FOREIGN KEY (CurrentVersionId) REFERENCES lms.CourseVersion (CourseVersionId);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_CourseVersion_Course_Status' AND object_id = OBJECT_ID(N'lms.CourseVersion'))
    CREATE NONCLUSTERED INDEX IX_CourseVersion_Course_Status ON lms.CourseVersion (CourseId, [Status])
        INCLUDE (VersionNumber, PublishedAtUtc);
GO

/* --- lms.CourseVersionLocale : estado de traduccion por idioma ----------- */
IF OBJECT_ID(N'lms.CourseVersionLocale', N'U') IS NULL
CREATE TABLE lms.CourseVersionLocale (
      CourseVersionId   INT              NOT NULL
    , LocaleCode        NVARCHAR(10)     NOT NULL   -- 'es-DO','en-US'
    , TranslationStatus TINYINT          NOT NULL CONSTRAINT DF_CVLocale_Status DEFAULT 1
                                         -- 1=NotStarted 2=InProgress 3=Complete 4=Reviewed
    , CompletionPercent DECIMAL(5,2)     NOT NULL CONSTRAINT DF_CVLocale_Percent DEFAULT 0
    , IsAvailable       BIT              NOT NULL CONSTRAINT DF_CVLocale_IsAvailable DEFAULT 0
    , TranslatedByUserId INT             NULL
    , ReviewedByUserId  INT              NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , CONSTRAINT PK_CourseVersionLocale PRIMARY KEY CLUSTERED (CourseVersionId, LocaleCode)
    , CONSTRAINT FK_CVLocale_CourseVersion FOREIGN KEY (CourseVersionId) REFERENCES lms.CourseVersion (CourseVersionId)
);
GO

/* --- lms.CourseApproval : workflow de publicacion ------------------------ */
IF OBJECT_ID(N'lms.CourseApproval', N'U') IS NULL
CREATE TABLE lms.CourseApproval (
      CourseApprovalId  INT              NOT NULL IDENTITY(1,1)
    , CourseVersionId   INT              NOT NULL
    , ApprovalRole      TINYINT          NOT NULL   -- 1=Author 2=TechnicalReviewer 3=QualityApprover
    , ApproverUserId    INT              NOT NULL
    , Decision          TINYINT          NULL       -- 1=Approved 2=Rejected
    , Comments          NVARCHAR(1000)   NULL
    , RequestedAtUtc    DATETIME2(3)     NOT NULL CONSTRAINT DF_CourseApproval_Requested DEFAULT SYSUTCDATETIME()
    , DecidedAtUtc      DATETIME2(3)     NULL
    , CONSTRAINT PK_CourseApproval PRIMARY KEY CLUSTERED (CourseApprovalId)
    , CONSTRAINT FK_CourseApproval_CourseVersion FOREIGN KEY (CourseVersionId) REFERENCES lms.CourseVersion (CourseVersionId)
    , CONSTRAINT UQ_CourseApproval UNIQUE (CourseVersionId, ApprovalRole, ApproverUserId)
);
GO

/* --- lms.Program : learning path ---------------------------------------- */
IF OBJECT_ID(N'lms.Program', N'U') IS NULL
CREATE TABLE lms.Program (
      ProgramId         INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Program_PublicId DEFAULT NEWID()
    , ProgramCode       NVARCHAR(40)     NOT NULL
    , NameEs            NVARCHAR(250)    NOT NULL
    , NameEn            NVARCHAR(250)    NULL
    , DescriptionEs     NVARCHAR(MAX)    NULL
    , DescriptionEn     NVARCHAR(MAX)    NULL
    , EnforceSequence   BIT              NOT NULL CONSTRAINT DF_Program_EnforceSeq DEFAULT 1
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_Program_Status DEFAULT 1
                                         -- 1=Draft 2=Published 3=Retired
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Program_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Program_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Program PRIMARY KEY CLUSTERED (ProgramId)
    , CONSTRAINT UQ_Program_Code UNIQUE (ProgramCode)
);
GO

/* --- lms.ProgramCourse -------------------------------------------------- */
IF OBJECT_ID(N'lms.ProgramCourse', N'U') IS NULL
CREATE TABLE lms.ProgramCourse (
      ProgramCourseId   INT              NOT NULL IDENTITY(1,1)
    , ProgramId         INT              NOT NULL
    , CourseId          INT              NOT NULL
    , SortOrder         INT              NOT NULL
    , IsRequired        BIT              NOT NULL CONSTRAINT DF_ProgramCourse_IsRequired DEFAULT 1
    , PrerequisiteProgramCourseId INT    NULL
    , CONSTRAINT PK_ProgramCourse PRIMARY KEY CLUSTERED (ProgramCourseId)
    , CONSTRAINT UQ_ProgramCourse UNIQUE (ProgramId, CourseId)
    , CONSTRAINT FK_ProgramCourse_Program FOREIGN KEY (ProgramId) REFERENCES lms.Program (ProgramId)
    , CONSTRAINT FK_ProgramCourse_Course  FOREIGN KEY (CourseId)  REFERENCES lms.Course (CourseId)
    , CONSTRAINT FK_ProgramCourse_Prereq  FOREIGN KEY (PrerequisiteProgramCourseId) REFERENCES lms.ProgramCourse (ProgramCourseId)
);
GO

/* --- lms.CourseBlueprintLink : maestro -> derivado ---------------------- */
IF OBJECT_ID(N'lms.CourseBlueprintLink', N'U') IS NULL
CREATE TABLE lms.CourseBlueprintLink (
      CourseBlueprintLinkId INT          NOT NULL IDENTITY(1,1)
    , BlueprintCourseId INT              NOT NULL
    , DerivedCourseId   INT              NOT NULL
    , SyncContent       BIT              NOT NULL CONSTRAINT DF_BlueprintLink_SyncContent DEFAULT 1
    , SyncSettings      BIT              NOT NULL CONSTRAINT DF_BlueprintLink_SyncSettings DEFAULT 1
    , LastSyncedAtUtc   DATETIME2(3)     NULL
    , LastSyncedVersionId INT            NULL
    , CONSTRAINT PK_CourseBlueprintLink PRIMARY KEY CLUSTERED (CourseBlueprintLinkId)
    , CONSTRAINT UQ_CourseBlueprintLink UNIQUE (BlueprintCourseId, DerivedCourseId)
    , CONSTRAINT FK_BlueprintLink_Master  FOREIGN KEY (BlueprintCourseId) REFERENCES lms.Course (CourseId)
    , CONSTRAINT FK_BlueprintLink_Derived FOREIGN KEY (DerivedCourseId)   REFERENCES lms.Course (CourseId)
);
GO

PRINT '=== 03_tables_catalog.sql completado ===';
GO
