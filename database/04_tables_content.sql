/* =============================================================================
   Classroom LMS by Airlink
   04_tables_content.sql  -  lms: modulos, items, paginas, traducciones
   ============================================================================= */
USE AIRLINK_KMS;
GO
SET NOCOUNT ON;
GO

/* --- lms.CourseModule --------------------------------------------------- */
IF OBJECT_ID(N'lms.CourseModule', N'U') IS NULL
CREATE TABLE lms.CourseModule (
      CourseModuleId    INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_CourseModule_PublicId DEFAULT NEWID()
    , CourseVersionId   INT              NOT NULL
    , TitleEs           NVARCHAR(250)    NOT NULL
    , TitleEn           NVARCHAR(250)    NULL
    , SortOrder         INT              NOT NULL
    , PrerequisiteModuleId INT           NULL       -- gating secuencial
    , CompletionRule    TINYINT          NOT NULL CONSTRAINT DF_CourseModule_CompletionRule DEFAULT 1
        /* 1=AllItems 2=AnyItem 3=MinimumScore 4=SpecificItems */
    , MinimumScore      DECIMAL(5,2)     NULL
    , IsRequired        BIT              NOT NULL CONSTRAINT DF_CourseModule_IsRequired DEFAULT 1
    , UnlockAtUtc       DATETIME2(3)     NULL
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_CourseModule_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_CourseModule_IsDeleted DEFAULT 0
    , CONSTRAINT PK_CourseModule PRIMARY KEY CLUSTERED (CourseModuleId)
    , CONSTRAINT UQ_CourseModule_Order UNIQUE (CourseVersionId, SortOrder)
    , CONSTRAINT FK_CourseModule_CourseVersion FOREIGN KEY (CourseVersionId) REFERENCES lms.CourseVersion (CourseVersionId)
    , CONSTRAINT FK_CourseModule_Prereq       FOREIGN KEY (PrerequisiteModuleId) REFERENCES lms.CourseModule (CourseModuleId)
    , CONSTRAINT CK_CourseModule_CompletionRule CHECK (CompletionRule BETWEEN 1 AND 4)
);
GO

/* --- lms.ModuleItem : POLIMORFICO --------------------------------------- */
/* ItemType + TargetId. Sin FK fisica; la integridad la garantiza
   lms.usp_ModuleItem_Add validando el target segun el tipo.
   Trade-off documentado en docs/04-modelo-de-datos.md seccion 2.2         */
IF OBJECT_ID(N'lms.ModuleItem', N'U') IS NULL
CREATE TABLE lms.ModuleItem (
      ModuleItemId      INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_ModuleItem_PublicId DEFAULT NEWID()
    , CourseModuleId    INT              NOT NULL
    , ItemType          TINYINT          NOT NULL
        /* 1=Page 2=File 3=Video 4=Quiz 5=PracticalAssessment
           6=DocumentAcknowledgment 7=ExternalLink 8=SubHeader 9=Cmi5Package */
    , TargetId          INT              NULL       -- NULL para SubHeader
    , TitleEs           NVARCHAR(250)    NOT NULL
    , TitleEn           NVARCHAR(250)    NULL
    , SortOrder         INT              NOT NULL
    , Indent            TINYINT          NOT NULL CONSTRAINT DF_ModuleItem_Indent DEFAULT 0
    , IsRequiredForCompletion BIT        NOT NULL CONSTRAINT DF_ModuleItem_IsRequired DEFAULT 1
    , CompletionCriteria TINYINT         NOT NULL CONSTRAINT DF_ModuleItem_CompletionCriteria DEFAULT 1
        /* 1=View 2=MarkDone 3=Submit 4=MinimumScore 5=MinimumTime */
    , MinimumScore      DECIMAL(5,2)     NULL
    , MinimumSeconds    INT              NULL       -- anti-skip
    , Points            DECIMAL(9,2)     NULL
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_ModuleItem_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_ModuleItem_IsDeleted DEFAULT 0
    , CONSTRAINT PK_ModuleItem PRIMARY KEY CLUSTERED (ModuleItemId)
    , CONSTRAINT UQ_ModuleItem_Order UNIQUE (CourseModuleId, SortOrder)
    , CONSTRAINT FK_ModuleItem_CourseModule FOREIGN KEY (CourseModuleId) REFERENCES lms.CourseModule (CourseModuleId)
    , CONSTRAINT CK_ModuleItem_ItemType CHECK (ItemType BETWEEN 1 AND 9)
    , CONSTRAINT CK_ModuleItem_Target   CHECK ((ItemType = 8 AND TargetId IS NULL)
                                            OR (ItemType <> 8 AND TargetId IS NOT NULL))
    , CONSTRAINT CK_ModuleItem_Criteria CHECK (CompletionCriteria BETWEEN 1 AND 5)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ModuleItem_Target' AND object_id = OBJECT_ID(N'lms.ModuleItem'))
    CREATE NONCLUSTERED INDEX IX_ModuleItem_Target ON lms.ModuleItem (ItemType, TargetId)
        WHERE IsDeleted = 0;
GO

/* --- lms.Page ---------------------------------------------------------- */
IF OBJECT_ID(N'lms.Page', N'U') IS NULL
CREATE TABLE lms.Page (
      PageId            INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Page_PublicId DEFAULT NEWID()
    , CourseVersionId   INT              NOT NULL
    , TitleEs           NVARCHAR(250)    NOT NULL
    , TitleEn           NVARCHAR(250)    NULL
    , BodyHtmlEs        NVARCHAR(MAX)    NULL       -- HTML ya sanitizado por la API
    , BodyHtmlEn        NVARCHAR(MAX)    NULL
    , EstimatedMinutes  INT              NULL
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Page_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Page_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Page PRIMARY KEY CLUSTERED (PageId)
    , CONSTRAINT FK_Page_CourseVersion FOREIGN KEY (CourseVersionId) REFERENCES lms.CourseVersion (CourseVersionId)
);
GO

/* --- lms.ExternalResource ---------------------------------------------- */
IF OBJECT_ID(N'lms.ExternalResource', N'U') IS NULL
CREATE TABLE lms.ExternalResource (
      ExternalResourceId INT             NOT NULL IDENTITY(1,1)
    , CourseVersionId   INT              NOT NULL
    , ResourceType      TINYINT          NOT NULL CONSTRAINT DF_ExternalResource_Type DEFAULT 1
                                         -- 1=Url 2=LtiTool 3=SharePoint 4=Video
    , TitleEs           NVARCHAR(250)    NOT NULL
    , TitleEn           NVARCHAR(250)    NULL
    , Url               NVARCHAR(1000)   NOT NULL
    , OpenInNewWindow   BIT              NOT NULL CONSTRAINT DF_ExternalResource_NewWindow DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_ExternalResource_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_ExternalResource_IsDeleted DEFAULT 0
    , CONSTRAINT PK_ExternalResource PRIMARY KEY CLUSTERED (ExternalResourceId)
    , CONSTRAINT FK_ExternalResource_CourseVersion FOREIGN KEY (CourseVersionId) REFERENCES lms.CourseVersion (CourseVersionId)
);
GO

/* --- lms.ContentTranslation : i18n generico ---------------------------- */
/* Para locales adicionales mas alla de los campos Es/En inline.
   EntityType: 1=Course 2=CourseVersion 3=CourseModule 4=ModuleItem 5=Page
               6=Question 7=QuestionOption 8=Quiz 9=Competency
               10=PracticalCriterion 11=NotificationTemplate               */
IF OBJECT_ID(N'lms.ContentTranslation', N'U') IS NULL
CREATE TABLE lms.ContentTranslation (
      EntityType        TINYINT          NOT NULL
    , EntityId          INT              NOT NULL
    , LocaleCode        NVARCHAR(10)     NOT NULL
    , FieldName         NVARCHAR(50)     NOT NULL
    , TranslatedText    NVARCHAR(MAX)    NOT NULL
    , TranslatedByUserId INT             NULL
    , ReviewedByUserId  INT              NULL
    , ModifiedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_ContentTranslation_ModifiedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_ContentTranslation PRIMARY KEY CLUSTERED (EntityType, EntityId, LocaleCode, FieldName)
);
GO

/* --- lms.VideoAsset : tracking de reproduccion ------------------------- */
IF OBJECT_ID(N'lms.VideoAsset', N'U') IS NULL
CREATE TABLE lms.VideoAsset (
      VideoAssetId      INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_VideoAsset_PublicId DEFAULT NEWID()
    , CourseVersionId   INT              NOT NULL
    , FileAssetId       INT              NULL
    , ExternalUrl       NVARCHAR(1000)   NULL
    , TitleEs           NVARCHAR(250)    NOT NULL
    , TitleEn           NVARCHAR(250)    NULL
    , DurationSeconds   INT              NULL
    , RequiredWatchPercent DECIMAL(5,2)  NOT NULL CONSTRAINT DF_VideoAsset_RequiredPercent DEFAULT 90.00
    , AllowSeek         BIT              NOT NULL CONSTRAINT DF_VideoAsset_AllowSeek DEFAULT 0
    , CaptionFileAssetId INT             NULL
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_VideoAsset_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_VideoAsset_IsDeleted DEFAULT 0
    , CONSTRAINT PK_VideoAsset PRIMARY KEY CLUSTERED (VideoAssetId)
    , CONSTRAINT FK_VideoAsset_CourseVersion FOREIGN KEY (CourseVersionId) REFERENCES lms.CourseVersion (CourseVersionId)
);
GO

PRINT '=== 04_tables_content.sql completado ===';
GO
