/* =============================================================================
   Classroom LMS by Airlink
   02_tables_core.sql  -  sec (identidad) + org (organizacion y empleados)
   Idempotente.
   ============================================================================= */

USE AIRLINK_LMS;
GO
SET NOCOUNT ON;
GO

/* =============================================================================
   SEC - IDENTIDAD Y SEGURIDAD
   ============================================================================= */

/* --- sec.Permission ------------------------------------------------------- */
IF OBJECT_ID(N'sec.Permission', N'U') IS NULL
CREATE TABLE sec.Permission (
      PermissionId      INT              NOT NULL IDENTITY(1,1)
    , PermissionCode    NVARCHAR(80)     NOT NULL   -- 'course.publish'
    , Domain            NVARCHAR(40)     NOT NULL   -- 'Course','Certification',...
    , DisplayNameEs     NVARCHAR(150)    NOT NULL
    , DisplayNameEn     NVARCHAR(150)    NOT NULL
    , Description       NVARCHAR(400)    NULL
    , IsSystem          BIT              NOT NULL CONSTRAINT DF_Permission_IsSystem DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Permission_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_Permission PRIMARY KEY CLUSTERED (PermissionId)
    , CONSTRAINT UQ_Permission_Code UNIQUE (PermissionCode)
);
GO

/* --- sec.Role ------------------------------------------------------------- */
IF OBJECT_ID(N'sec.Role', N'U') IS NULL
CREATE TABLE sec.Role (
      RoleId            INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Role_PublicId DEFAULT NEWID()
    , RoleCode          NVARCHAR(50)     NOT NULL   -- 'Learner','QualityManager'
    , DisplayNameEs     NVARCHAR(100)    NOT NULL
    , DisplayNameEn     NVARCHAR(100)    NOT NULL
    , Description       NVARCHAR(400)    NULL
    , IsSystem          BIT              NOT NULL CONSTRAINT DF_Role_IsSystem DEFAULT 0
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Role_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Role_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Role_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Role PRIMARY KEY CLUSTERED (RoleId)
    , CONSTRAINT UQ_Role_Code UNIQUE (RoleCode)
    , CONSTRAINT UQ_Role_PublicId UNIQUE NONCLUSTERED (PublicId)
);
GO

/* --- sec.RolePermission --------------------------------------------------- */
IF OBJECT_ID(N'sec.RolePermission', N'U') IS NULL
CREATE TABLE sec.RolePermission (
      RoleId            INT              NOT NULL
    , PermissionId      INT              NOT NULL
    , GrantedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_RolePermission_GrantedAtUtc DEFAULT SYSUTCDATETIME()
    , GrantedByUserId   INT              NULL
    , CONSTRAINT PK_RolePermission PRIMARY KEY CLUSTERED (RoleId, PermissionId)
    , CONSTRAINT FK_RolePermission_Role       FOREIGN KEY (RoleId)       REFERENCES sec.Role (RoleId)
    , CONSTRAINT FK_RolePermission_Permission FOREIGN KEY (PermissionId) REFERENCES sec.Permission (PermissionId)
);
GO

/* --- sec.User ------------------------------------------------------------- */
IF OBJECT_ID(N'sec.User', N'U') IS NULL
CREATE TABLE sec.[User] (
      UserId            INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_User_PublicId DEFAULT NEWID()
    , EmployeeId        INT              NULL      -- NULL = usuario sin empleado (auditor, contratista)
    , UserName          NVARCHAR(100)    NOT NULL  -- codigo de empleado o UPN
    , DisplayName       NVARCHAR(200)    NOT NULL
    , Email             NVARCHAR(256)    NULL
    , ExternalObjectId  NVARCHAR(100)    NULL      -- 'oid' de Entra ID
    , AuthMethod        TINYINT          NOT NULL CONSTRAINT DF_User_AuthMethod DEFAULT 1
                                                  -- 1=EntraId 2=Pin 3=Both
    , PreferredLocale   NVARCHAR(10)     NOT NULL CONSTRAINT DF_User_PreferredLocale DEFAULT N'es-DO'
    , TimeZoneId        NVARCHAR(60)     NOT NULL CONSTRAINT DF_User_TimeZoneId DEFAULT N'SA Western Standard Time'
    , IsActive          BIT              NOT NULL CONSTRAINT DF_User_IsActive DEFAULT 1
    , LastLoginAtUtc    DATETIME2(3)     NULL
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_User_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_User_IsDeleted DEFAULT 0
    , CONSTRAINT PK_User PRIMARY KEY CLUSTERED (UserId)
    , CONSTRAINT UQ_User_UserName UNIQUE (UserName)
    , CONSTRAINT UQ_User_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT CK_User_AuthMethod CHECK (AuthMethod IN (1,2,3))
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_User_ExternalObjectId' AND object_id = OBJECT_ID(N'sec.User'))
    CREATE UNIQUE NONCLUSTERED INDEX IX_User_ExternalObjectId ON sec.[User] (ExternalObjectId)
        WHERE ExternalObjectId IS NOT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_User_EmployeeId' AND object_id = OBJECT_ID(N'sec.User'))
    CREATE UNIQUE NONCLUSTERED INDEX IX_User_EmployeeId ON sec.[User] (EmployeeId)
        WHERE EmployeeId IS NOT NULL AND IsDeleted = 0;
GO

/* --- sec.UserCredential : PIN de kiosko ----------------------------------- */
/* El hash y el salt los calcula la API (PBKDF2-HMAC-SHA256, >=210k iteraciones).
   T-SQL nunca ve el PIN en claro ni hace criptografia de contrasenas.         */
IF OBJECT_ID(N'sec.UserCredential', N'U') IS NULL
CREATE TABLE sec.UserCredential (
      UserId                INT           NOT NULL
    , PinHash               VARBINARY(64) NOT NULL
    , PinSalt               VARBINARY(32) NOT NULL
    , Iterations            INT           NOT NULL CONSTRAINT DF_UserCredential_Iterations DEFAULT 210000
    , Algorithm             NVARCHAR(40)  NOT NULL CONSTRAINT DF_UserCredential_Algorithm DEFAULT N'PBKDF2-HMACSHA256'
    , MustChangeOnNextLogin BIT           NOT NULL CONSTRAINT DF_UserCredential_MustChange DEFAULT 1
    , ExpiresAtUtc          DATETIME2(3)  NULL
    , FailedAttemptCount    TINYINT       NOT NULL CONSTRAINT DF_UserCredential_Failed DEFAULT 0
    , LockedUntilUtc        DATETIME2(3)  NULL
    , LastChangedAtUtc      DATETIME2(3)  NOT NULL CONSTRAINT DF_UserCredential_LastChanged DEFAULT SYSUTCDATETIME()
    , RowVersion            ROWVERSION    NOT NULL
    , CONSTRAINT PK_UserCredential PRIMARY KEY CLUSTERED (UserId)
    , CONSTRAINT FK_UserCredential_User FOREIGN KEY (UserId) REFERENCES sec.[User] (UserId)
);
GO

/* --- sec.UserRoleAssignment : TEMPORAL (historia de quien tuvo que rol) ---- */
IF OBJECT_ID(N'sec.UserRoleAssignment', N'U') IS NULL
BEGIN
    CREATE TABLE sec.UserRoleAssignment (
          UserRoleAssignmentId INT           NOT NULL IDENTITY(1,1)
        , UserId               INT           NOT NULL
        , RoleId               INT           NOT NULL
        , ScopeType            TINYINT       NOT NULL CONSTRAINT DF_URA_ScopeType DEFAULT 1
                                             -- 1=Global 2=Site 3=Department 4=Area 5=Self
        , ScopeId              INT           NULL     -- NULL cuando ScopeType=1 o 5
        , IsActive             BIT           NOT NULL CONSTRAINT DF_URA_IsActive DEFAULT 1
        , AssignedAtUtc        DATETIME2(3)  NOT NULL CONSTRAINT DF_URA_AssignedAtUtc DEFAULT SYSUTCDATETIME()
        , AssignedByUserId     INT           NOT NULL
        , RevokedAtUtc         DATETIME2(3)  NULL
        , RevokedByUserId      INT           NULL
        , ValidFromUtc         DATETIME2(3)  GENERATED ALWAYS AS ROW START NOT NULL
        , ValidToUtc           DATETIME2(3)  GENERATED ALWAYS AS ROW END   NOT NULL
        , PERIOD FOR SYSTEM_TIME (ValidFromUtc, ValidToUtc)
        , CONSTRAINT PK_UserRoleAssignment PRIMARY KEY CLUSTERED (UserRoleAssignmentId)
        , CONSTRAINT FK_URA_User CHECK (1=1)  -- FKs abajo
        , CONSTRAINT CK_URA_ScopeType CHECK (ScopeType BETWEEN 1 AND 5)
        , CONSTRAINT CK_URA_ScopeId   CHECK ((ScopeType IN (1,5) AND ScopeId IS NULL)
                                          OR (ScopeType IN (2,3,4) AND ScopeId IS NOT NULL))
    )
    WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = sec.UserRoleAssignmentHistory));

    ALTER TABLE sec.UserRoleAssignment DROP CONSTRAINT FK_URA_User;
    ALTER TABLE sec.UserRoleAssignment ADD CONSTRAINT FK_URA_UserRef FOREIGN KEY (UserId) REFERENCES sec.[User] (UserId);
    ALTER TABLE sec.UserRoleAssignment ADD CONSTRAINT FK_URA_RoleRef FOREIGN KEY (RoleId) REFERENCES sec.Role (RoleId);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_URA_User_Active' AND object_id = OBJECT_ID(N'sec.UserRoleAssignment'))
    CREATE NONCLUSTERED INDEX IX_URA_User_Active ON sec.UserRoleAssignment (UserId, IsActive)
        INCLUDE (RoleId, ScopeType, ScopeId);
GO

/* --- sec.DeviceRegistration : terminales de kiosko ------------------------ */
IF OBJECT_ID(N'sec.DeviceRegistration', N'U') IS NULL
CREATE TABLE sec.DeviceRegistration (
      DeviceId          INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Device_PublicId DEFAULT NEWID()
    , DeviceName        NVARCHAR(100)    NOT NULL   -- 'Tablet-Linea-SMT-02'
    , DeviceTokenHash   VARBINARY(64)    NOT NULL
    , SiteId            INT              NULL
    , DepartmentId      INT              NULL
    , AreaId            INT              NULL
    , StationId         INT              NULL
    , IsKiosk           BIT              NOT NULL CONSTRAINT DF_Device_IsKiosk DEFAULT 1
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Device_IsActive DEFAULT 1
    , LastSeenAtUtc     DATETIME2(3)     NULL
    , LastIpAddress     NVARCHAR(45)     NULL
    , RegisteredAtUtc   DATETIME2(3)     NOT NULL CONSTRAINT DF_Device_RegisteredAtUtc DEFAULT SYSUTCDATETIME()
    , RegisteredByUserId INT             NOT NULL
    , RevokedAtUtc      DATETIME2(3)     NULL
    , RevokedByUserId   INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_DeviceRegistration PRIMARY KEY CLUSTERED (DeviceId)
    , CONSTRAINT UQ_Device_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT UQ_Device_Name UNIQUE (DeviceName)
);
GO

/* --- sec.UserSession ------------------------------------------------------ */
IF OBJECT_ID(N'sec.UserSession', N'U') IS NULL
CREATE TABLE sec.UserSession (
      SessionId         UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_UserSession_SessionId DEFAULT NEWID()
    , UserId            INT              NOT NULL
    , DeviceId          INT              NULL
    , SessionType       TINYINT          NOT NULL CONSTRAINT DF_UserSession_Type DEFAULT 1
                                         -- 1=Web 2=Kiosk 3=Api 4=Mobile
    , IpAddress         NVARCHAR(45)     NULL
    , UserAgent         NVARCHAR(400)    NULL
    , StartedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_UserSession_StartedAtUtc DEFAULT SYSUTCDATETIME()
    , LastSeenAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_UserSession_LastSeenAtUtc DEFAULT SYSUTCDATETIME()
    , ExpiresAtUtc      DATETIME2(3)     NOT NULL
    , EndedAtUtc        DATETIME2(3)     NULL
    , EndReason         TINYINT          NULL   -- 1=Logout 2=Timeout 3=Revoked 4=Expired
    , CONSTRAINT PK_UserSession PRIMARY KEY CLUSTERED (SessionId)
    , CONSTRAINT FK_UserSession_User   FOREIGN KEY (UserId)   REFERENCES sec.[User] (UserId)
    , CONSTRAINT FK_UserSession_Device FOREIGN KEY (DeviceId) REFERENCES sec.DeviceRegistration (DeviceId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_UserSession_User_Active' AND object_id = OBJECT_ID(N'sec.UserSession'))
    CREATE NONCLUSTERED INDEX IX_UserSession_User_Active ON sec.UserSession (UserId, EndedAtUtc)
        INCLUDE (ExpiresAtUtc);
GO

/* --- sec.LoginAttempt : deteccion de fuerza bruta ------------------------- */
IF OBJECT_ID(N'sec.LoginAttempt', N'U') IS NULL
CREATE TABLE sec.LoginAttempt (
      LoginAttemptId    BIGINT           NOT NULL IDENTITY(1,1)
    , UserName          NVARCHAR(100)    NOT NULL
    , UserId            INT              NULL
    , DeviceId          INT              NULL
    , IsSuccess         BIT              NOT NULL
    , FailureReason     TINYINT          NULL   -- 1=NoUser 2=BadPin 3=Locked 4=Inactive 5=NoDevice
    , IpAddress         NVARCHAR(45)     NULL
    , AttemptedAtUtc    DATETIME2(3)     NOT NULL CONSTRAINT DF_LoginAttempt_AtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_LoginAttempt PRIMARY KEY CLUSTERED (LoginAttemptId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_LoginAttempt_UserName_Time' AND object_id = OBJECT_ID(N'sec.LoginAttempt'))
    CREATE NONCLUSTERED INDEX IX_LoginAttempt_UserName_Time ON sec.LoginAttempt (UserName, AttemptedAtUtc DESC)
        INCLUDE (IsSuccess);
GO

/* --- sec.RoleGroupMapping : grupo de Entra ID -> rol ---------------------- */
IF OBJECT_ID(N'sec.RoleGroupMapping', N'U') IS NULL
CREATE TABLE sec.RoleGroupMapping (
      RoleGroupMappingId INT             NOT NULL IDENTITY(1,1)
    , ExternalGroupId    NVARCHAR(100)   NOT NULL
    , ExternalGroupName  NVARCHAR(200)   NULL
    , RoleId             INT             NOT NULL
    , ScopeType          TINYINT         NOT NULL CONSTRAINT DF_RGM_ScopeType DEFAULT 1
    , ScopeId            INT             NULL
    , IsActive           BIT             NOT NULL CONSTRAINT DF_RGM_IsActive DEFAULT 1
    , CONSTRAINT PK_RoleGroupMapping PRIMARY KEY CLUSTERED (RoleGroupMappingId)
    , CONSTRAINT UQ_RGM UNIQUE (ExternalGroupId, RoleId)
    , CONSTRAINT FK_RGM_Role FOREIGN KEY (RoleId) REFERENCES sec.Role (RoleId)
);
GO


/* =============================================================================
   ORG - ORGANIZACION Y EMPLEADOS
   ============================================================================= */

/* --- org.Organization ---------------------------------------------------- */
IF OBJECT_ID(N'org.Organization', N'U') IS NULL
CREATE TABLE org.Organization (
      OrganizationId    INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Organization_PublicId DEFAULT NEWID()
    , OrganizationCode  NVARCHAR(20)     NOT NULL
    , [Name]            NVARCHAR(200)    NOT NULL
    , LegalName         NVARCHAR(250)    NULL
    , TaxId             NVARCHAR(30)     NULL
    , LogoFileAssetId   INT              NULL
    , DefaultLocale     NVARCHAR(10)     NOT NULL CONSTRAINT DF_Organization_Locale DEFAULT N'es-DO'
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Organization_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Organization_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_Organization PRIMARY KEY CLUSTERED (OrganizationId)
    , CONSTRAINT UQ_Organization_Code UNIQUE (OrganizationCode)
);
GO

/* --- org.Site ------------------------------------------------------------ */
IF OBJECT_ID(N'org.Site', N'U') IS NULL
CREATE TABLE org.Site (
      SiteId            INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Site_PublicId DEFAULT NEWID()
    , OrganizationId    INT              NOT NULL
    , SiteCode          NVARCHAR(20)     NOT NULL
    , [Name]            NVARCHAR(150)    NOT NULL
    , [Address]         NVARCHAR(400)    NULL
    , City              NVARCHAR(100)    NULL
    , CountryCode       NCHAR(2)         NOT NULL CONSTRAINT DF_Site_CountryCode DEFAULT N'DO'
    , TimeZoneId        NVARCHAR(60)     NOT NULL CONSTRAINT DF_Site_TimeZoneId DEFAULT N'SA Western Standard Time'
    , IsR2Certified     BIT              NOT NULL CONSTRAINT DF_Site_IsR2Certified DEFAULT 0
    , IsIso9001Certified BIT             NOT NULL CONSTRAINT DF_Site_IsIso9001 DEFAULT 0
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Site_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Site_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Site_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Site PRIMARY KEY CLUSTERED (SiteId)
    , CONSTRAINT UQ_Site_Code UNIQUE (SiteCode)
    , CONSTRAINT FK_Site_Organization FOREIGN KEY (OrganizationId) REFERENCES org.Organization (OrganizationId)
);
GO

/* --- org.Department ------------------------------------------------------ */
IF OBJECT_ID(N'org.Department', N'U') IS NULL
CREATE TABLE org.Department (
      DepartmentId      INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Department_PublicId DEFAULT NEWID()
    , SiteId            INT              NOT NULL
    , ParentDepartmentId INT             NULL      -- jerarquia dentro del sitio
    , DepartmentCode    NVARCHAR(30)     NOT NULL
    , [Name]            NVARCHAR(150)    NOT NULL
    , ManagerEmployeeId INT              NULL
    , CostCenter        NVARCHAR(30)     NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Department_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Department_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Department_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Department PRIMARY KEY CLUSTERED (DepartmentId)
    , CONSTRAINT UQ_Department_Code UNIQUE (DepartmentCode)
    , CONSTRAINT FK_Department_Site   FOREIGN KEY (SiteId)             REFERENCES org.Site (SiteId)
    , CONSTRAINT FK_Department_Parent FOREIGN KEY (ParentDepartmentId) REFERENCES org.Department (DepartmentId)
);
GO

/* --- org.Area : linea / celda de produccion ------------------------------ */
IF OBJECT_ID(N'org.Area', N'U') IS NULL
CREATE TABLE org.Area (
      AreaId            INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Area_PublicId DEFAULT NEWID()
    , DepartmentId      INT              NOT NULL
    , AreaCode          NVARCHAR(30)     NOT NULL
    , [Name]            NVARCHAR(150)    NOT NULL
    , AreaType          TINYINT          NOT NULL CONSTRAINT DF_Area_AreaType DEFAULT 1
                                         -- 1=ProductionLine 2=Cell 3=Warehouse 4=Lab 5=Office
    , SupervisorEmployeeId INT           NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Area_IsActive DEFAULT 1
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Area_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Area PRIMARY KEY CLUSTERED (AreaId)
    , CONSTRAINT UQ_Area_Code UNIQUE (AreaCode)
    , CONSTRAINT FK_Area_Department FOREIGN KEY (DepartmentId) REFERENCES org.Department (DepartmentId)
);
GO

/* --- org.Station : estacion de trabajo (unidad de gating) ---------------- */
IF OBJECT_ID(N'org.Station', N'U') IS NULL
CREATE TABLE org.Station (
      StationId         INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Station_PublicId DEFAULT NEWID()
    , AreaId            INT              NOT NULL
    , StationCode       NVARCHAR(40)     NOT NULL   -- 'RXR-01','IQC-03'
    , [Name]            NVARCHAR(150)    NOT NULL
    , ProcessCode       NVARCHAR(40)     NULL       -- alineado con Nexus/THOR
    , EquipmentName     NVARCHAR(150)    NULL       -- 'Roxer SmartRox PATRICK'
    , RequiresGating    BIT              NOT NULL CONSTRAINT DF_Station_RequiresGating DEFAULT 0
    , GatingMode        TINYINT          NOT NULL CONSTRAINT DF_Station_GatingMode DEFAULT 1
                                         -- 1=Shadow 2=Warn 3=Enforce   (ver doc 07 - rollout)
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Station_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Station_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Station_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Station PRIMARY KEY CLUSTERED (StationId)
    , CONSTRAINT UQ_Station_Code UNIQUE (StationCode)
    , CONSTRAINT FK_Station_Area FOREIGN KEY (AreaId) REFERENCES org.Area (AreaId)
    , CONSTRAINT CK_Station_GatingMode CHECK (GatingMode IN (1,2,3))
);
GO

/* --- org.Position -------------------------------------------------------- */
IF OBJECT_ID(N'org.Position', N'U') IS NULL
CREATE TABLE org.[Position] (
      PositionId        INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Position_PublicId DEFAULT NEWID()
    , PositionCode      NVARCHAR(40)     NOT NULL
    , [Name]            NVARCHAR(150)    NOT NULL
    , NameEn            NVARCHAR(150)    NULL
    , JobFamily         NVARCHAR(80)     NULL
    , JobLevel          TINYINT          NULL
    , [Description]     NVARCHAR(1000)   NULL
    , AffectsProductQuality BIT          NOT NULL CONSTRAINT DF_Position_AffectsQuality DEFAULT 0
                                         -- ISO 9001 cl.7.2 aplica a estas posiciones
    , IsMappedFromSource BIT             NOT NULL CONSTRAINT DF_Position_IsMapped DEFAULT 0
    , RequiresReview    BIT              NOT NULL CONSTRAINT DF_Position_RequiresReview DEFAULT 0
                                         -- 1 = posicion detectada en SPN sin requisitos definidos
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Position_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Position_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Position_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Position PRIMARY KEY CLUSTERED (PositionId)
    , CONSTRAINT UQ_Position_Code UNIQUE (PositionCode)
);
GO

/* --- org.Employee : espejo de SPN. NUNCA se borra. ----------------------- */
IF OBJECT_ID(N'org.Employee', N'U') IS NULL
CREATE TABLE org.Employee (
      EmployeeId        INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Employee_PublicId DEFAULT NEWID()
    , EmployeeCode      NVARCHAR(30)     NOT NULL   -- clave natural desde SPN
    , FirstName         NVARCHAR(100)    NOT NULL
    , LastName          NVARCHAR(100)    NOT NULL
    , FullName          AS (FirstName + N' ' + LastName) PERSISTED
    , PreferredName     NVARCHAR(100)    NULL
    , NationalIdMasked  NVARCHAR(20)     NULL       -- ultimos 4 visibles
    , NationalIdEnc     VARBINARY(256)   NULL       -- Always Encrypted si se requiere
    , Email             NVARCHAR(256)    NULL
    , Phone             NVARCHAR(30)     NULL
    , SiteId            INT              NULL
    , DepartmentId      INT              NULL
    , AreaId            INT              NULL
    , PrimaryPositionId INT              NULL
    , SupervisorEmployeeId INT           NULL
    , ShiftCode         NVARCHAR(20)     NULL
    , HireDateUtc       DATETIME2(3)     NULL
    , TerminationDateUtc DATETIME2(3)    NULL
    , EmploymentType    TINYINT          NOT NULL CONSTRAINT DF_Employee_EmploymentType DEFAULT 1
                                         -- 1=Employee 2=Contractor 3=Agency 4=Temp
                                         -- ISO 9001 cl.7.2 aplica a TODOS: "personas
                                         -- que hacen trabajo bajo el control de la organizacion"
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Employee_IsActive DEFAULT 1
    , SourceSystem      NVARCHAR(20)     NOT NULL CONSTRAINT DF_Employee_SourceSystem DEFAULT N'SPN'
    , SourceHash        VARBINARY(32)     NULL      -- deteccion de cambios en el sync
    , LastSyncedAtUtc   DATETIME2(3)     NULL
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Employee_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_Employee PRIMARY KEY CLUSTERED (EmployeeId)
    , CONSTRAINT UQ_Employee_Code UNIQUE (EmployeeCode)
    , CONSTRAINT UQ_Employee_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT FK_Employee_Site       FOREIGN KEY (SiteId)            REFERENCES org.Site (SiteId)
    , CONSTRAINT FK_Employee_Department FOREIGN KEY (DepartmentId)      REFERENCES org.Department (DepartmentId)
    , CONSTRAINT FK_Employee_Area       FOREIGN KEY (AreaId)            REFERENCES org.Area (AreaId)
    , CONSTRAINT FK_Employee_Position   FOREIGN KEY (PrimaryPositionId) REFERENCES org.[Position] (PositionId)
    , CONSTRAINT FK_Employee_Supervisor FOREIGN KEY (SupervisorEmployeeId) REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT CK_Employee_EmploymentType CHECK (EmploymentType BETWEEN 1 AND 4)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Employee_Dept_Active' AND object_id = OBJECT_ID(N'org.Employee'))
    CREATE NONCLUSTERED INDEX IX_Employee_Dept_Active ON org.Employee (DepartmentId, IsActive)
        INCLUDE (EmployeeCode, FirstName, LastName, PrimaryPositionId, AreaId);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Employee_Supervisor' AND object_id = OBJECT_ID(N'org.Employee'))
    CREATE NONCLUSTERED INDEX IX_Employee_Supervisor ON org.Employee (SupervisorEmployeeId)
        WHERE IsActive = 1;
GO

-- FK diferida de sec.User a org.Employee
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_User_Employee')
    ALTER TABLE sec.[User] ADD CONSTRAINT FK_User_Employee
        FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId);
GO

/* --- org.EmployeePosition : N posiciones por empleado -------------------- */
IF OBJECT_ID(N'org.EmployeePosition', N'U') IS NULL
CREATE TABLE org.EmployeePosition (
      EmployeePositionId INT             NOT NULL IDENTITY(1,1)
    , EmployeeId        INT              NOT NULL
    , PositionId        INT              NOT NULL
    , IsPrimary         BIT              NOT NULL CONSTRAINT DF_EmployeePosition_IsPrimary DEFAULT 0
    , EffectiveFromUtc  DATETIME2(3)     NOT NULL CONSTRAINT DF_EmployeePosition_From DEFAULT SYSUTCDATETIME()
    , EffectiveToUtc    DATETIME2(3)     NULL     -- NULL = vigente
    , AssignedByUserId  INT              NULL
    , Notes             NVARCHAR(400)    NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_EmployeePosition PRIMARY KEY CLUSTERED (EmployeePositionId)
    , CONSTRAINT FK_EmployeePosition_Employee FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT FK_EmployeePosition_Position FOREIGN KEY (PositionId) REFERENCES org.[Position] (PositionId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_EmployeePosition_Current' AND object_id = OBJECT_ID(N'org.EmployeePosition'))
    CREATE NONCLUSTERED INDEX IX_EmployeePosition_Current ON org.EmployeePosition (EmployeeId, PositionId)
        INCLUDE (IsPrimary, EffectiveFromUtc) WHERE EffectiveToUtc IS NULL;
GO

/* --- org.EmployeeAssignment : ubicacion y turno vigente ------------------ */
IF OBJECT_ID(N'org.EmployeeAssignment', N'U') IS NULL
CREATE TABLE org.EmployeeAssignment (
      EmployeeAssignmentId INT           NOT NULL IDENTITY(1,1)
    , EmployeeId        INT              NOT NULL
    , SiteId            INT              NULL
    , DepartmentId      INT              NULL
    , AreaId            INT              NULL
    , StationId         INT              NULL
    , ShiftCode         NVARCHAR(20)     NULL
    , EffectiveFromUtc  DATETIME2(3)     NOT NULL CONSTRAINT DF_EmployeeAssignment_From DEFAULT SYSUTCDATETIME()
    , EffectiveToUtc    DATETIME2(3)     NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_EmployeeAssignment PRIMARY KEY CLUSTERED (EmployeeAssignmentId)
    , CONSTRAINT FK_EmployeeAssignment_Employee FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_EmployeeAssignment_Current' AND object_id = OBJECT_ID(N'org.EmployeeAssignment'))
    CREATE NONCLUSTERED INDEX IX_EmployeeAssignment_Current ON org.EmployeeAssignment (EmployeeId)
        INCLUDE (DepartmentId, AreaId, StationId, ShiftCode) WHERE EffectiveToUtc IS NULL;
GO

PRINT '=== 02_tables_core.sql completado ===';
GO
