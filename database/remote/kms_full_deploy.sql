/* =============================================================================
   Classroom KMS - DESPLIEGUE COMPLETO DE LA CAPA DE DATOS
   Archivo GENERADO por scripts/build-full-deploy.sh - no editar a mano.

   Crea la base AIRLINK_KMS completa: esquemas, ~100 tablas, funciones,
   vistas, ~200 stored procedures, seed de referencia y jobs del Agent.

   ANTES DE CORRER (una sola vez):
     1. Reemplazar las 3 contrasenas placeholder
        <<REEMPLAZAR-DESDE-KEY-VAULT-...>> en la seccion de logins.
     2. Verificar que la conexion tenga QUOTED_IDENTIFIER ON
        (SSMS y DataGrip lo traen por defecto).
     3. El ultimo bloque (jobs del Agent) requiere SQL Server Agent activo;
        si el Agent no esta disponible, ese bloque fallara y puede
        omitirse sin afectar el resto.

   Idempotente: re-ejecutable sobre una base existente.
   El orden NO es numerico a proposito: 18 corre antes que 11-17 porque
   todos los SPs de negocio llaman a aud.usp_Error_Log / usp_Event_Log.
   ============================================================================= */

/* ############################################################################
   ARCHIVO: database/00_setup_database_roles.sql
   ############################################################################ */
/* =============================================================================
   Classroom LMS by Airlink
   00_setup_database_roles.sql
   -----------------------------------------------------------------------------
   Crea la base de datos, los principals y los roles de aplicacion.

   ATENCION - LEER ANTES DE EJECUTAR
   ---------------------------------
   1. NO reutilizar AlAppUser. Es read-only y no puede soportar un LMS.
      AlAppUser queda intacto para lo que ya hace hoy.
   2. Las contrasenas de este script son PLACEHOLDERS. Generarlas con un
      administrador de secretos (>= 24 caracteres) y almacenarlas en Azure Key
      Vault o Windows Credential Manager. NUNCA en el repositorio, chat o correo.
   3. Preferir gMSA + autenticacion integrada de Windows si el dominio lo permite:
      cero contrasenas en configuracion.
   4. Ejecutar como sysadmin en la instancia 192.168.181.248,13999.

   Idempotente. Re-ejecutable.
   ============================================================================= */

SET NOCOUNT ON;
GO

/* -----------------------------------------------------------------------------
   1. Base de datos
   ADR-001: base de datos propia. NO se crean tablas del LMS dentro de AIRLINK.
   Cambiar el nombre por AIRLINK_KMS_DEV / _QA segun el entorno.
   -------------------------------------------------------------------------- */
DECLARE @DbName SYSNAME = N'AIRLINK_KMS';

IF DB_ID(@DbName) IS NULL
BEGIN
    DECLARE @sql NVARCHAR(MAX) = N'CREATE DATABASE ' + QUOTENAME(@DbName) + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Base de datos creada: ' + @DbName;
END
ELSE
    PRINT 'Base de datos ya existe: ' + @DbName;
GO

USE AIRLINK_KMS;
GO

/* Configuracion de base de datos */
ALTER DATABASE CURRENT SET RECOVERY FULL;
ALTER DATABASE CURRENT SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;  -- reduce bloqueos de lectura
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION ON;
ALTER DATABASE CURRENT SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE CURRENT SET AUTO_UPDATE_STATISTICS ON;
ALTER DATABASE CURRENT SET AUTO_SHRINK OFF;
ALTER DATABASE CURRENT SET AUTO_CLOSE OFF;
ALTER DATABASE CURRENT SET PAGE_VERIFY CHECKSUM;
ALTER DATABASE CURRENT SET TRUSTWORTHY OFF;       -- seguridad: nunca ON
ALTER DATABASE CURRENT SET QUERY_STORE = ON;
GO

ALTER DATABASE CURRENT SET QUERY_STORE (
      OPERATION_MODE = READ_WRITE
    , MAX_STORAGE_SIZE_MB = 2048
    , QUERY_CAPTURE_MODE = AUTO
);
GO

/* -----------------------------------------------------------------------------
   2. Logins a nivel de servidor
   -------------------------------------------------------------------------- */
USE master;
GO

-- 2.1 AlLmsAppUser : la aplicacion. Solo EXECUTE. Cero SELECT sobre tablas.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'AlLmsAppUser')
BEGIN
    CREATE LOGIN [AlLmsAppUser]
        WITH PASSWORD     = N'<<REEMPLAZAR-DESDE-KEY-VAULT-APP>>'
           , CHECK_POLICY  = ON
           , CHECK_EXPIRATION = OFF
           , DEFAULT_DATABASE = [AIRLINK_KMS];
    PRINT 'Login creado: AlLmsAppUser';
END
GO

-- 2.2 AlLmsSyncUser : jobs de sincronizacion. Lee SPN y AIRLINK.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'AlLmsSyncUser')
BEGIN
    CREATE LOGIN [AlLmsSyncUser]
        WITH PASSWORD     = N'<<REEMPLAZAR-DESDE-KEY-VAULT-SYNC>>'
           , CHECK_POLICY  = ON
           , CHECK_EXPIRATION = OFF
           , DEFAULT_DATABASE = [AIRLINK_KMS];
    PRINT 'Login creado: AlLmsSyncUser';
END
GO

-- 2.3 AlLmsReportUser : Power BI. Solo SELECT sobre el esquema rpt.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'AlLmsReportUser')
BEGIN
    CREATE LOGIN [AlLmsReportUser]
        WITH PASSWORD     = N'<<REEMPLAZAR-DESDE-KEY-VAULT-REPORT>>'
           , CHECK_POLICY  = ON
           , CHECK_EXPIRATION = OFF
           , DEFAULT_DATABASE = [AIRLINK_KMS];
    PRINT 'Login creado: AlLmsReportUser';
END
GO

/* -----------------------------------------------------------------------------
   3. Usuarios y roles en AIRLINK_KMS
   -------------------------------------------------------------------------- */
USE AIRLINK_KMS;
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'AlLmsAppUser')
    CREATE USER [AlLmsAppUser] FOR LOGIN [AlLmsAppUser];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'AlLmsSyncUser')
    CREATE USER [AlLmsSyncUser] FOR LOGIN [AlLmsSyncUser];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'AlLmsReportUser')
    CREATE USER [AlLmsReportUser] FOR LOGIN [AlLmsReportUser];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'db_lms_app' AND type = 'R')
    CREATE ROLE [db_lms_app];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'db_lms_sync' AND type = 'R')
    CREATE ROLE [db_lms_sync];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'db_lms_report' AND type = 'R')
    CREATE ROLE [db_lms_report];
GO

ALTER ROLE [db_lms_app]    ADD MEMBER [AlLmsAppUser];
ALTER ROLE [db_lms_sync]   ADD MEMBER [AlLmsSyncUser];
ALTER ROLE [db_lms_report] ADD MEMBER [AlLmsReportUser];
GO

/* -----------------------------------------------------------------------------
   4. Permisos
   Los GRANT de esquema se aplican en 01_schemas.sql, despues de crearlos.
   Aqui solo se niega explicitamente lo que nunca debe poder hacerse.
   -------------------------------------------------------------------------- */

-- La aplicacion NO puede leer tablas directamente. Esta es la garantia tecnica
-- de la regla "todo por stored procedure": no es una convencion de codigo, es
-- una restriccion de la base de datos que falla en runtime si se viola.
DENY SELECT, INSERT, UPDATE, DELETE ON DATABASE::[AIRLINK_KMS] TO [db_lms_app];
GO

-- Nadie de la aplicacion altera esquema.
-- OJO: sin CONTROL en la lista. DENY CONTROL implica DENY CONNECT y
-- bloquea el login por completo (y DENY siempre vence a GRANT).
DENY ALTER, CREATE TABLE, CREATE PROCEDURE, CREATE VIEW
    ON DATABASE::[AIRLINK_KMS] TO [db_lms_app], [db_lms_sync], [db_lms_report];
GO

-- Limpieza idempotente: instalaciones previas de este script aplicaban
-- DENY CONTROL (bloqueaba CONNECT) y DENY SELECT a nivel de base para
-- db_lms_report (anulaba el GRANT sobre rpt, porque DENY gana).
REVOKE CONTROL ON DATABASE::[AIRLINK_KMS] FROM [db_lms_app];
REVOKE CONTROL ON DATABASE::[AIRLINK_KMS] FROM [db_lms_sync];
REVOKE CONTROL ON DATABASE::[AIRLINK_KMS] FROM [db_lms_report];
REVOKE SELECT  ON DATABASE::[AIRLINK_KMS] FROM [db_lms_report];
GO

/* El rol de reporteria no ve nada fuera de rpt: eso lo garantiza el
   default-deny de SQL Server (sin GRANT no hay acceso). El unico GRANT
   que recibe es SELECT sobre el esquema rpt, en 01_schemas.sql. */

PRINT '';
PRINT '=== 00_setup_database_roles.sql completado ===';
PRINT 'Siguiente: 01_schemas.sql';
PRINT '';
PRINT 'RECORDATORIO: rotar la contrasena de AlAppUser (fue expuesta en texto claro)';
PRINT 'y reemplazar los placeholders de contrasena de este script.';
GO

/* -----------------------------------------------------------------------------
   5. Permisos de lectura en SPN y AIRLINK para el sync (ejecutar por separado)
   -----------------------------------------------------------------------------
   Descomentar y ejecutar una vez que se confirmen los nombres reales de las
   vistas/tablas de origen. Principio de menor privilegio: SELECT sobre objetos
   especificos, nunca db_datareader sobre la base completa.

USE SPN;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'AlLmsSyncUser')
    CREATE USER [AlLmsSyncUser] FOR LOGIN [AlLmsSyncUser];
GO
-- TODO: reemplazar con los objetos reales de SPN
-- GRANT SELECT ON [dbo].[Employee]        TO [AlLmsSyncUser];
-- GRANT SELECT ON [dbo].[Position]        TO [AlLmsSyncUser];
-- GRANT SELECT ON [dbo].[Department]      TO [AlLmsSyncUser];
GO

USE AIRLINK;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'AlLmsSyncUser')
    CREATE USER [AlLmsSyncUser] FOR LOGIN [AlLmsSyncUser];
GO
-- TODO: reemplazar con los objetos reales de AIRLINK
-- GRANT SELECT ON [dbo].[VW_HistoryUnitProcess] TO [AlLmsSyncUser];
GO
   -------------------------------------------------------------------------- */

/* ############################################################################
   ARCHIVO: database/01_schemas.sql
   ############################################################################ */
/* =============================================================================
   Classroom LMS by Airlink
   01_schemas.sql  -  Esquemas y permisos de esquema
   Idempotente.
   ============================================================================= */

USE AIRLINK_KMS;
GO
SET NOCOUNT ON;
GO

DECLARE @schemas TABLE (Name SYSNAME, Descripcion NVARCHAR(200));
INSERT INTO @schemas (Name, Descripcion) VALUES
      (N'sec',  N'Identidad, usuarios, roles, permisos, sesiones, dispositivos')
    , (N'org',  N'Organizacion, sitios, departamentos, areas, posiciones, empleados')
    , (N'lms',  N'Cursos, versiones, modulos, items, contenido, programas')
    , (N'asmt', N'Evaluacion: bancos, preguntas, quizzes, intentos, rubricas, practica')
    , (N'dlv',  N'Delivery: inscripciones, progreso, cohortes, sesiones ILT')
    , (N'comp', N'Compliance: competencias, requisitos, certificaciones, documentos')
    , (N'aud',  N'Auditoria: eventos, errores, firmas, idempotencia')
    , (N'intg', N'Integracion: staging, watermarks, mapeos externos')
    , (N'ops',  N'Plataforma: settings, flags, notificaciones, archivos, jobs')
    , (N'rpt',  N'Reporteria: vistas y procedimientos de reportes');

DECLARE @name SYSNAME, @sql NVARCHAR(MAX);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT Name FROM @schemas;
OPEN c;
FETCH NEXT FROM c INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = @name)
    BEGIN
        SET @sql = N'CREATE SCHEMA ' + QUOTENAME(@name) + N' AUTHORIZATION [dbo];';
        EXEC sys.sp_executesql @sql;
        PRINT 'Esquema creado: ' + @name;
    END
    FETCH NEXT FROM c INTO @name;
END
CLOSE c; DEALLOCATE c;
GO

/* -----------------------------------------------------------------------------
   Permisos de esquema
   -----------------------------------------------------------------------------
   db_lms_app    : EXECUTE unicamente. Sin SELECT. La cadena de propiedad
                   (ownership chaining) permite que los SPs lean las tablas
                   porque SPs y tablas comparten el dueno dbo.
   db_lms_sync   : EXECUTE sobre intg + lo minimo en org para el merge.
   db_lms_report : SELECT sobre rpt unicamente.
   -------------------------------------------------------------------------- */

GRANT EXECUTE ON SCHEMA::[sec]  TO [db_lms_app];
GRANT EXECUTE ON SCHEMA::[org]  TO [db_lms_app];
GRANT EXECUTE ON SCHEMA::[lms]  TO [db_lms_app];
GRANT EXECUTE ON SCHEMA::[asmt] TO [db_lms_app];
GRANT EXECUTE ON SCHEMA::[dlv]  TO [db_lms_app];
GRANT EXECUTE ON SCHEMA::[comp] TO [db_lms_app];
GRANT EXECUTE ON SCHEMA::[aud]  TO [db_lms_app];
GRANT EXECUTE ON SCHEMA::[ops]  TO [db_lms_app];
GRANT EXECUTE ON SCHEMA::[rpt]  TO [db_lms_app];
GO

GRANT EXECUTE ON SCHEMA::[intg] TO [db_lms_sync];
GRANT EXECUTE ON SCHEMA::[comp] TO [db_lms_sync];   -- recalculo de brechas post-sync
GRANT EXECUTE ON SCHEMA::[ops]  TO [db_lms_sync];   -- JobRun, NotificationEnqueue
GRANT EXECUTE ON SCHEMA::[aud]  TO [db_lms_sync];
GO

GRANT SELECT ON SCHEMA::[rpt] TO [db_lms_report];
GO

-- La app NO puede ejecutar nada en intg: la integracion es exclusiva de los jobs.
DENY EXECUTE ON SCHEMA::[intg] TO [db_lms_app];
GO

/* Tipos de tabla (TVP) usados por los SPs de operacion masiva */
IF TYPE_ID(N'ops.IntListType') IS NULL
    CREATE TYPE ops.IntListType AS TABLE (Value INT NOT NULL PRIMARY KEY);
GO

IF TYPE_ID(N'ops.StringListType') IS NULL
    CREATE TYPE ops.StringListType AS TABLE (Value NVARCHAR(200) NOT NULL PRIMARY KEY);
GO

IF TYPE_ID(N'dlv.EnrollmentRequestType') IS NULL
    CREATE TYPE dlv.EnrollmentRequestType AS TABLE (
          EmployeeCode    NVARCHAR(30)  NOT NULL
        , CourseCode      NVARCHAR(40)  NOT NULL
        , CohortId        INT           NULL
        , DueAtUtc        DATETIME2(3)  NULL
        , PRIMARY KEY (EmployeeCode, CourseCode)
    );
GO

IF TYPE_ID(N'asmt.AnswerType') IS NULL
    CREATE TYPE asmt.AnswerType AS TABLE (
          AttemptQuestionId  INT             NOT NULL
        , SelectedOptionIds  NVARCHAR(200)   NULL   -- CSV de AttemptOptionId
        , TextAnswer         NVARCHAR(MAX)   NULL
        , NumericAnswer      DECIMAL(18,4)   NULL
        , PRIMARY KEY (AttemptQuestionId)
    );
GO

IF TYPE_ID(N'asmt.CriterionResultType') IS NULL
    CREATE TYPE asmt.CriterionResultType AS TABLE (
          PracticalCriterionId INT           NOT NULL
        , ResultCode           TINYINT       NOT NULL   -- 1=Pass 2=Fail 3=N/A
        , Comments             NVARCHAR(1000) NULL
        , PRIMARY KEY (PracticalCriterionId)
    );
GO

PRINT '=== 01_schemas.sql completado ===';
GO

/* ############################################################################
   ARCHIVO: database/02_tables_core.sql
   ############################################################################ */
/* =============================================================================
   Classroom LMS by Airlink
   02_tables_core.sql  -  sec (identidad) + org (organizacion y empleados)
   Idempotente.
   ============================================================================= */

USE AIRLINK_KMS;
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

/* --- org.EmployeePhoto : foto del empleado (viene del hub de SPN) -------- */
IF OBJECT_ID(N'org.EmployeePhoto', N'U') IS NULL
CREATE TABLE org.EmployeePhoto (
      EmployeeId        INT              NOT NULL
    , ContentType       NVARCHAR(60)     NOT NULL CONSTRAINT DF_EmployeePhoto_ContentType DEFAULT N'image/jpeg'
    , PhotoBytes        VARBINARY(MAX)   NOT NULL
    , PhotoHash         AS CAST(HASHBYTES('SHA2_256', PhotoBytes) AS VARBINARY(32))
    , [Source]          NVARCHAR(30)     NOT NULL CONSTRAINT DF_EmployeePhoto_Source DEFAULT N'SPN_HUB'
    , UpdatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_EmployeePhoto_UpdatedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_EmployeePhoto PRIMARY KEY CLUSTERED (EmployeeId)
    , CONSTRAINT FK_EmployeePhoto_Employee FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId)
);
GO

/* ############################################################################
   ARCHIVO: database/03_tables_catalog.sql
   ############################################################################ */
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

/* ############################################################################
   ARCHIVO: database/04_tables_content.sql
   ############################################################################ */
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

/* ############################################################################
   ARCHIVO: database/05_tables_assessment.sql
   ############################################################################ */
/* =============================================================================
   Classroom LMS by Airlink
   05_tables_assessment.sql  -  asmt: bancos, preguntas, quizzes, intentos,
                                rubricas, evaluacion practica (OJT)
   ============================================================================= */
USE AIRLINK_KMS;
GO
SET NOCOUNT ON;
GO

/* --- asmt.QuestionBank -------------------------------------------------- */
IF OBJECT_ID(N'asmt.QuestionBank', N'U') IS NULL
CREATE TABLE asmt.QuestionBank (
      QuestionBankId    INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_QuestionBank_PublicId DEFAULT NEWID()
    , BankCode          NVARCHAR(40)     NOT NULL
    , NameEs            NVARCHAR(250)    NOT NULL
    , NameEn            NVARCHAR(250)    NULL
    , CompetencyId      INT              NULL       -- banco alineado a una competencia
    , OwnerDepartmentId INT              NULL
    , IsShared          BIT              NOT NULL CONSTRAINT DF_QuestionBank_IsShared DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_QuestionBank_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_QuestionBank_IsDeleted DEFAULT 0
    , CONSTRAINT PK_QuestionBank PRIMARY KEY CLUSTERED (QuestionBankId)
    , CONSTRAINT UQ_QuestionBank_Code UNIQUE (BankCode)
);
GO

/* --- asmt.Question ----------------------------------------------------- */
IF OBJECT_ID(N'asmt.Question', N'U') IS NULL
CREATE TABLE asmt.Question (
      QuestionId        INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Question_PublicId DEFAULT NEWID()
    , QuestionBankId    INT              NOT NULL
    , QuestionType      TINYINT          NOT NULL
        /* 1=MultipleChoice 2=MultipleAnswer 3=TrueFalse 4=Matching 5=Ordering
           6=ShortAnswer 7=Numeric 8=Essay 9=HotSpot 10=FileUpload */
    , TextEs            NVARCHAR(MAX)    NOT NULL
    , TextEn            NVARCHAR(MAX)    NULL
    , Points            DECIMAL(9,2)     NOT NULL CONSTRAINT DF_Question_Points DEFAULT 1
    , Difficulty        TINYINT          NOT NULL CONSTRAINT DF_Question_Difficulty DEFAULT 2
                                         -- 1=Easy 2=Medium 3=Hard
    , CorrectFeedbackEs NVARCHAR(1000)   NULL
    , CorrectFeedbackEn NVARCHAR(1000)   NULL
    , IncorrectFeedbackEs NVARCHAR(1000) NULL       -- referencia a la seccion de la WI
    , IncorrectFeedbackEn NVARCHAR(1000) NULL
    , ReferenceDocumentCode NVARCHAR(60) NULL       -- 'WI-IP68-RXR-001 Rev.1 sec.4.2'
    , MediaFileAssetId  INT              NULL       -- imagen para HotSpot
    , NumericAnswer     DECIMAL(18,4)    NULL
    , NumericTolerance  DECIMAL(18,4)    NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Question_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Question_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Question_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Question PRIMARY KEY CLUSTERED (QuestionId)
    , CONSTRAINT FK_Question_Bank FOREIGN KEY (QuestionBankId) REFERENCES asmt.QuestionBank (QuestionBankId)
    , CONSTRAINT CK_Question_Type CHECK (QuestionType BETWEEN 1 AND 10)
    , CONSTRAINT CK_Question_Points CHECK (Points > 0)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Question_Bank_Active' AND object_id = OBJECT_ID(N'asmt.Question'))
    CREATE NONCLUSTERED INDEX IX_Question_Bank_Active ON asmt.Question (QuestionBankId, IsActive, Difficulty)
        WHERE IsDeleted = 0;
GO

/* --- asmt.QuestionOption ----------------------------------------------- */
IF OBJECT_ID(N'asmt.QuestionOption', N'U') IS NULL
CREATE TABLE asmt.QuestionOption (
      QuestionOptionId  INT              NOT NULL IDENTITY(1,1)
    , QuestionId        INT              NOT NULL
    , TextEs            NVARCHAR(1000)   NOT NULL
    , TextEn            NVARCHAR(1000)   NULL
    , IsCorrect         BIT              NOT NULL CONSTRAINT DF_QuestionOption_IsCorrect DEFAULT 0
    , SortOrder         INT              NOT NULL
    , MatchGroupKey     NVARCHAR(40)     NULL       -- para Matching
    , HotSpotX          INT              NULL       -- para HotSpot (px)
    , HotSpotY          INT              NULL
    , HotSpotRadius     INT              NULL
    , PartialCredit     DECIMAL(5,2)     NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_QuestionOption_IsDeleted DEFAULT 0
    , CONSTRAINT PK_QuestionOption PRIMARY KEY CLUSTERED (QuestionOptionId)
    , CONSTRAINT FK_QuestionOption_Question FOREIGN KEY (QuestionId) REFERENCES asmt.Question (QuestionId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_QuestionOption_Question' AND object_id = OBJECT_ID(N'asmt.QuestionOption'))
    CREATE NONCLUSTERED INDEX IX_QuestionOption_Question ON asmt.QuestionOption (QuestionId, SortOrder)
        WHERE IsDeleted = 0;
GO

/* --- asmt.Quiz --------------------------------------------------------- */
IF OBJECT_ID(N'asmt.Quiz', N'U') IS NULL
CREATE TABLE asmt.Quiz (
      QuizId            INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Quiz_PublicId DEFAULT NEWID()
    , CourseVersionId   INT              NULL       -- NULL = quiz reutilizable
    , TitleEs           NVARCHAR(250)    NOT NULL
    , TitleEn           NVARCHAR(250)    NULL
    , InstructionsEs    NVARCHAR(MAX)    NULL
    , InstructionsEn    NVARCHAR(MAX)    NULL
    , QuizType          TINYINT          NOT NULL CONSTRAINT DF_Quiz_QuizType DEFAULT 1
                                         -- 1=Graded 2=Practice 3=Survey 4=PreTest
    , PassingScore      DECIMAL(5,2)     NOT NULL CONSTRAINT DF_Quiz_PassingScore DEFAULT 80.00
    , MaxAttempts       TINYINT          NOT NULL CONSTRAINT DF_Quiz_MaxAttempts DEFAULT 3
    , ScorePolicy       TINYINT          NOT NULL CONSTRAINT DF_Quiz_ScorePolicy DEFAULT 1
                                         -- 1=Highest 2=Latest 3=Average 4=First
    , TimeLimitMinutes  INT              NULL
    , ShuffleQuestions  BIT              NOT NULL CONSTRAINT DF_Quiz_ShuffleQuestions DEFAULT 1
    , ShuffleOptions    BIT              NOT NULL CONSTRAINT DF_Quiz_ShuffleOptions DEFAULT 1
    , OneQuestionAtATime BIT             NOT NULL CONSTRAINT DF_Quiz_OneAtATime DEFAULT 0
    , AllowBacktrack    BIT              NOT NULL CONSTRAINT DF_Quiz_AllowBacktrack DEFAULT 1
    , ShowCorrectAnswers TINYINT         NOT NULL CONSTRAINT DF_Quiz_ShowCorrect DEFAULT 2
                                         -- 1=Never 2=AfterPassing 3=Always 4=AfterLastAttempt
    , ShowScoreImmediately BIT           NOT NULL CONSTRAINT DF_Quiz_ShowScore DEFAULT 1
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Quiz_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Quiz_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Quiz_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Quiz PRIMARY KEY CLUSTERED (QuizId)
    , CONSTRAINT FK_Quiz_CourseVersion FOREIGN KEY (CourseVersionId) REFERENCES lms.CourseVersion (CourseVersionId)
    , CONSTRAINT CK_Quiz_ScorePolicy CHECK (ScorePolicy BETWEEN 1 AND 4)
);
GO

/* --- asmt.QuizSection + fuentes (seleccion aleatoria de banco) ---------- */
IF OBJECT_ID(N'asmt.QuizSection', N'U') IS NULL
CREATE TABLE asmt.QuizSection (
      QuizSectionId     INT              NOT NULL IDENTITY(1,1)
    , QuizId            INT              NOT NULL
    , TitleEs           NVARCHAR(250)    NULL
    , TitleEn           NVARCHAR(250)    NULL
    , SortOrder         INT              NOT NULL
    , SelectionMode     TINYINT          NOT NULL CONSTRAINT DF_QuizSection_SelectionMode DEFAULT 1
                                         -- 1=FixedQuestions 2=RandomFromBank
    , CONSTRAINT PK_QuizSection PRIMARY KEY CLUSTERED (QuizSectionId)
    , CONSTRAINT FK_QuizSection_Quiz FOREIGN KEY (QuizId) REFERENCES asmt.Quiz (QuizId)
);
GO

IF OBJECT_ID(N'asmt.QuizSectionSource', N'U') IS NULL
CREATE TABLE asmt.QuizSectionSource (
      QuizSectionSourceId INT            NOT NULL IDENTITY(1,1)
    , QuizSectionId     INT              NOT NULL
    , QuestionBankId    INT              NOT NULL
    , QuestionCount     INT              NOT NULL   -- "toma N del banco"
    , DifficultyFilter  TINYINT          NULL
    , PointsPerQuestion DECIMAL(9,2)     NULL       -- override
    , CONSTRAINT PK_QuizSectionSource PRIMARY KEY CLUSTERED (QuizSectionSourceId)
    , CONSTRAINT FK_QuizSectionSource_Section FOREIGN KEY (QuizSectionId)  REFERENCES asmt.QuizSection (QuizSectionId)
    , CONSTRAINT FK_QuizSectionSource_Bank    FOREIGN KEY (QuestionBankId) REFERENCES asmt.QuestionBank (QuestionBankId)
    , CONSTRAINT CK_QuizSectionSource_Count CHECK (QuestionCount > 0)
);
GO

IF OBJECT_ID(N'asmt.QuizQuestion', N'U') IS NULL
CREATE TABLE asmt.QuizQuestion (
      QuizQuestionId    INT              NOT NULL IDENTITY(1,1)
    , QuizSectionId     INT              NOT NULL
    , QuestionId        INT              NOT NULL
    , SortOrder         INT              NOT NULL
    , PointsOverride    DECIMAL(9,2)     NULL
    , CONSTRAINT PK_QuizQuestion PRIMARY KEY CLUSTERED (QuizQuestionId)
    , CONSTRAINT UQ_QuizQuestion UNIQUE (QuizSectionId, QuestionId)
    , CONSTRAINT FK_QuizQuestion_Section  FOREIGN KEY (QuizSectionId) REFERENCES asmt.QuizSection (QuizSectionId)
    , CONSTRAINT FK_QuizQuestion_Question FOREIGN KEY (QuestionId)    REFERENCES asmt.Question (QuestionId)
);
GO

/* --- asmt.QuizAttempt -------------------------------------------------- */
IF OBJECT_ID(N'asmt.QuizAttempt', N'U') IS NULL
CREATE TABLE asmt.QuizAttempt (
      QuizAttemptId     INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_QuizAttempt_PublicId DEFAULT NEWID()
    , QuizId            INT              NOT NULL
    , EnrollmentId      INT              NULL       -- NULL si es practica libre
    , EmployeeId        INT              NOT NULL
    , ModuleItemId      INT              NULL
    , AttemptNumber     TINYINT          NOT NULL
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_QuizAttempt_Status DEFAULT 1
        /* 1=InProgress 2=Submitted 3=Graded 4=Abandoned 5=PendingManualGrading */
    , StartedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_QuizAttempt_StartedAtUtc DEFAULT SYSUTCDATETIME()
    , ExpiresAtUtc      DATETIME2(3)     NULL       -- StartedAt + TimeLimit
    , SubmittedAtUtc    DATETIME2(3)     NULL
    , GradedAtUtc       DATETIME2(3)     NULL
    , GradedByUserId    INT              NULL
    , PointsEarned      DECIMAL(9,2)     NULL
    , PointsPossible    DECIMAL(9,2)     NULL
    , ScorePercent      DECIMAL(5,2)     NULL
    , IsPassed          BIT              NULL
    , TimeSpentSeconds  INT              NOT NULL CONSTRAINT DF_QuizAttempt_TimeSpent DEFAULT 0
    , SessionId         UNIQUEIDENTIFIER NULL
    , DeviceId          INT              NULL
    , IpAddress         NVARCHAR(45)     NULL
    , CONSTRAINT PK_QuizAttempt PRIMARY KEY CLUSTERED (QuizAttemptId)
    , CONSTRAINT UQ_QuizAttempt_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT FK_QuizAttempt_Quiz     FOREIGN KEY (QuizId)     REFERENCES asmt.Quiz (QuizId)
    , CONSTRAINT FK_QuizAttempt_Employee FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT CK_QuizAttempt_Status CHECK ([Status] BETWEEN 1 AND 5)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_QuizAttempt_Enrollment' AND object_id = OBJECT_ID(N'asmt.QuizAttempt'))
    CREATE NONCLUSTERED INDEX IX_QuizAttempt_Enrollment ON asmt.QuizAttempt (EnrollmentId, AttemptNumber)
        INCLUDE ([Status], ScorePercent, IsPassed);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_QuizAttempt_Expiring' AND object_id = OBJECT_ID(N'asmt.QuizAttempt'))
    CREATE NONCLUSTERED INDEX IX_QuizAttempt_Expiring ON asmt.QuizAttempt (ExpiresAtUtc)
        WHERE [Status] = 1;
GO

/* --- SNAPSHOT DEL INTENTO --------------------------------------------------
   asmt.QuizAttemptQuestion / QuizAttemptOption congelan la pregunta y las
   opciones EXACTAMENTE como se le presentaron al empleado, en el orden en que
   se mostraron. Si el banco cambia despues, el intento historico sigue siendo
   reproducible. Sin esto, un auditor puede impugnar toda la evidencia de
   evaluacion. NO ELIMINAR NI "OPTIMIZAR" ESTAS TABLAS.
   ---------------------------------------------------------------------- */
IF OBJECT_ID(N'asmt.QuizAttemptQuestion', N'U') IS NULL
CREATE TABLE asmt.QuizAttemptQuestion (
      AttemptQuestionId INT              NOT NULL IDENTITY(1,1)
    , QuizAttemptId     INT              NOT NULL
    , QuestionId        INT              NOT NULL   -- referencia, no fuente de verdad
    , QuestionType      TINYINT          NOT NULL
    , QuestionTextSnapshot NVARCHAR(MAX) NOT NULL   -- texto tal como se mostro
    , LocaleCode        NVARCHAR(10)     NOT NULL
    , PointsPossible    DECIMAL(9,2)     NOT NULL
    , PresentedOrder    INT              NOT NULL
    , NumericAnswerSnapshot DECIMAL(18,4) NULL
    , NumericToleranceSnapshot DECIMAL(18,4) NULL
    , ReferenceDocumentCode NVARCHAR(60) NULL
    , CONSTRAINT PK_QuizAttemptQuestion PRIMARY KEY CLUSTERED (AttemptQuestionId)
    , CONSTRAINT UQ_QuizAttemptQuestion UNIQUE (QuizAttemptId, PresentedOrder)
    , CONSTRAINT FK_AttemptQuestion_Attempt FOREIGN KEY (QuizAttemptId) REFERENCES asmt.QuizAttempt (QuizAttemptId)
);
GO

IF OBJECT_ID(N'asmt.QuizAttemptOption', N'U') IS NULL
CREATE TABLE asmt.QuizAttemptOption (
      AttemptOptionId   INT              NOT NULL IDENTITY(1,1)
    , AttemptQuestionId INT              NOT NULL
    , QuestionOptionId  INT              NULL
    , OptionTextSnapshot NVARCHAR(1000)  NOT NULL
    , IsCorrectSnapshot BIT              NOT NULL
    , PresentedOrder    INT              NOT NULL
    , MatchGroupKey     NVARCHAR(40)     NULL
    , HotSpotX          INT              NULL
    , HotSpotY          INT              NULL
    , HotSpotRadius     INT              NULL
    , PartialCredit     DECIMAL(5,2)     NULL
    , CONSTRAINT PK_QuizAttemptOption PRIMARY KEY CLUSTERED (AttemptOptionId)
    , CONSTRAINT UQ_QuizAttemptOption UNIQUE (AttemptQuestionId, PresentedOrder)
    , CONSTRAINT FK_AttemptOption_AttemptQuestion FOREIGN KEY (AttemptQuestionId) REFERENCES asmt.QuizAttemptQuestion (AttemptQuestionId)
);
GO

IF OBJECT_ID(N'asmt.QuizAttemptAnswer', N'U') IS NULL
CREATE TABLE asmt.QuizAttemptAnswer (
      AttemptAnswerId   INT              NOT NULL IDENTITY(1,1)
    , AttemptQuestionId INT              NOT NULL
    , SelectedOptionIds NVARCHAR(200)    NULL       -- CSV de AttemptOptionId
    , TextAnswer        NVARCHAR(MAX)    NULL
    , NumericAnswer     DECIMAL(18,4)    NULL
    , FileAssetId       INT              NULL
    , IsCorrect         BIT              NULL       -- NULL = pendiente de calificar
    , PointsEarned      DECIMAL(9,2)     NULL
    , GraderComments    NVARCHAR(1000)   NULL
    , GradedByUserId    INT              NULL
    , GradedAtUtc       DATETIME2(3)     NULL
    , AnsweredAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_AttemptAnswer_AnsweredAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_QuizAttemptAnswer PRIMARY KEY CLUSTERED (AttemptAnswerId)
    , CONSTRAINT UQ_QuizAttemptAnswer UNIQUE (AttemptQuestionId)
    , CONSTRAINT FK_AttemptAnswer_AttemptQuestion FOREIGN KEY (AttemptQuestionId) REFERENCES asmt.QuizAttemptQuestion (AttemptQuestionId)
);
GO

/* --- asmt.Rubric ------------------------------------------------------- */
IF OBJECT_ID(N'asmt.Rubric', N'U') IS NULL
CREATE TABLE asmt.Rubric (
      RubricId          INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Rubric_PublicId DEFAULT NEWID()
    , RubricCode        NVARCHAR(40)     NOT NULL
    , NameEs            NVARCHAR(250)    NOT NULL
    , NameEn            NVARCHAR(250)    NULL
    , TotalPoints       DECIMAL(9,2)     NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Rubric_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Rubric_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Rubric_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Rubric PRIMARY KEY CLUSTERED (RubricId)
    , CONSTRAINT UQ_Rubric_Code UNIQUE (RubricCode)
);
GO

IF OBJECT_ID(N'asmt.RubricCriterion', N'U') IS NULL
CREATE TABLE asmt.RubricCriterion (
      RubricCriterionId INT              NOT NULL IDENTITY(1,1)
    , RubricId          INT              NOT NULL
    , DescriptionEs     NVARCHAR(1000)   NOT NULL
    , DescriptionEn     NVARCHAR(1000)   NULL
    , CompetencyId      INT              NULL       -- alineacion a competencia (outcome)
    , MaxPoints         DECIMAL(9,2)     NOT NULL
    , SortOrder         INT              NOT NULL
    , IsCritical        BIT              NOT NULL CONSTRAINT DF_RubricCriterion_IsCritical DEFAULT 0
    , CONSTRAINT PK_RubricCriterion PRIMARY KEY CLUSTERED (RubricCriterionId)
    , CONSTRAINT FK_RubricCriterion_Rubric FOREIGN KEY (RubricId) REFERENCES asmt.Rubric (RubricId)
);
GO

IF OBJECT_ID(N'asmt.RubricLevel', N'U') IS NULL
CREATE TABLE asmt.RubricLevel (
      RubricLevelId     INT              NOT NULL IDENTITY(1,1)
    , RubricCriterionId INT              NOT NULL
    , LabelEs           NVARCHAR(100)    NOT NULL
    , LabelEn           NVARCHAR(100)    NULL
    , DescriptionEs     NVARCHAR(1000)   NULL
    , DescriptionEn     NVARCHAR(1000)   NULL
    , Points            DECIMAL(9,2)     NOT NULL
    , SortOrder         INT              NOT NULL
    , CONSTRAINT PK_RubricLevel PRIMARY KEY CLUSTERED (RubricLevelId)
    , CONSTRAINT FK_RubricLevel_Criterion FOREIGN KEY (RubricCriterionId) REFERENCES asmt.RubricCriterion (RubricCriterionId)
);
GO

IF OBJECT_ID(N'asmt.RubricAssessment', N'U') IS NULL
CREATE TABLE asmt.RubricAssessment (
      RubricAssessmentId INT             NOT NULL IDENTITY(1,1)
    , RubricId          INT              NOT NULL
    , EnrollmentId      INT              NULL
    , QuizAttemptId     INT              NULL
    , EmployeeId        INT              NOT NULL
    , AssessorUserId    INT              NOT NULL
    , TotalPoints       DECIMAL(9,2)     NULL
    , ScorePercent      DECIMAL(5,2)     NULL
    , Comments          NVARCHAR(MAX)    NULL
    , AssessedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_RubricAssessment_AssessedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_RubricAssessment PRIMARY KEY CLUSTERED (RubricAssessmentId)
    , CONSTRAINT FK_RubricAssessment_Rubric   FOREIGN KEY (RubricId)   REFERENCES asmt.Rubric (RubricId)
    , CONSTRAINT FK_RubricAssessment_Employee FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId)
);
GO

IF OBJECT_ID(N'asmt.RubricAssessmentRating', N'U') IS NULL
CREATE TABLE asmt.RubricAssessmentRating (
      RubricAssessmentRatingId INT       NOT NULL IDENTITY(1,1)
    , RubricAssessmentId INT             NOT NULL
    , RubricCriterionId INT              NOT NULL
    , RubricLevelId     INT              NULL
    , PointsAwarded     DECIMAL(9,2)     NOT NULL
    , Comments          NVARCHAR(1000)   NULL
    , CONSTRAINT PK_RubricAssessmentRating PRIMARY KEY CLUSTERED (RubricAssessmentRatingId)
    , CONSTRAINT UQ_RubricAssessmentRating UNIQUE (RubricAssessmentId, RubricCriterionId)
    , CONSTRAINT FK_RAR_Assessment FOREIGN KEY (RubricAssessmentId) REFERENCES asmt.RubricAssessment (RubricAssessmentId)
    , CONSTRAINT FK_RAR_Criterion  FOREIGN KEY (RubricCriterionId)  REFERENCES asmt.RubricCriterion (RubricCriterionId)
);
GO

/* =============================================================================
   EVALUACION PRACTICA / OJT
   Esta es la evidencia que ISO 9001 cl.7.2 llama "registros de entrenamiento en
   el puesto" y que R2v3 exige como competencia tecnica del trabajador.
   ============================================================================= */

IF OBJECT_ID(N'asmt.PracticalAssessmentTemplate', N'U') IS NULL
CREATE TABLE asmt.PracticalAssessmentTemplate (
      PracticalTemplateId INT            NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_PracticalTemplate_PublicId DEFAULT NEWID()
    , TemplateCode      NVARCHAR(40)     NOT NULL
    , NameEs            NVARCHAR(250)    NOT NULL
    , NameEn            NVARCHAR(250)    NULL
    , CompetencyId      INT              NULL
    , StationId         INT              NULL
    , RequiredRepetitions TINYINT        NOT NULL CONSTRAINT DF_PracticalTemplate_Reps DEFAULT 1
        /* "ejecuto el proceso correctamente N de N veces" */
    , PassingScore      DECIMAL(5,2)     NOT NULL CONSTRAINT DF_PracticalTemplate_PassingScore DEFAULT 100.00
    , MinimumEvaluatorLevelId INT        NULL       -- el evaluador debe tener >= este nivel
    , RequiresDualSignature BIT          NOT NULL CONSTRAINT DF_PracticalTemplate_DualSig DEFAULT 1
    , InstructionsEs    NVARCHAR(MAX)    NULL
    , InstructionsEn    NVARCHAR(MAX)    NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_PracticalTemplate_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_PracticalTemplate_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_PracticalTemplate_IsDeleted DEFAULT 0
    , CONSTRAINT PK_PracticalAssessmentTemplate PRIMARY KEY CLUSTERED (PracticalTemplateId)
    , CONSTRAINT UQ_PracticalTemplate_Code UNIQUE (TemplateCode)
);
GO

IF OBJECT_ID(N'asmt.PracticalCriterion', N'U') IS NULL
CREATE TABLE asmt.PracticalCriterion (
      PracticalCriterionId INT           NOT NULL IDENTITY(1,1)
    , PracticalTemplateId INT            NOT NULL
    , DescriptionEs     NVARCHAR(1000)   NOT NULL   -- observable, verificable
    , DescriptionEn     NVARCHAR(1000)   NULL
    , SortOrder         INT              NOT NULL
    , IsCritical        BIT              NOT NULL CONSTRAINT DF_PracticalCriterion_IsCritical DEFAULT 0
        /* Fallar un criterio critico reprueba toda la evaluacion */
    , Weight            DECIMAL(5,2)     NOT NULL CONSTRAINT DF_PracticalCriterion_Weight DEFAULT 1
    , ReferenceDocumentCode NVARCHAR(60) NULL
    , RequiresPhoto     BIT              NOT NULL CONSTRAINT DF_PracticalCriterion_RequiresPhoto DEFAULT 0
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_PracticalCriterion_IsDeleted DEFAULT 0
    , CONSTRAINT PK_PracticalCriterion PRIMARY KEY CLUSTERED (PracticalCriterionId)
    , CONSTRAINT FK_PracticalCriterion_Template FOREIGN KEY (PracticalTemplateId) REFERENCES asmt.PracticalAssessmentTemplate (PracticalTemplateId)
);
GO

IF OBJECT_ID(N'asmt.PracticalAssessment', N'U') IS NULL
CREATE TABLE asmt.PracticalAssessment (
      PracticalAssessmentId INT          NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_PracticalAssessment_PublicId DEFAULT NEWID()
    , PracticalTemplateId INT            NOT NULL
    , EnrollmentId      INT              NULL
    , EmployeeId        INT              NOT NULL   -- el evaluado
    , EvaluatorUserId   INT              NOT NULL   -- el evaluador
    , StationId         INT              NULL
    , AttemptNumber     TINYINT          NOT NULL CONSTRAINT DF_PracticalAssessment_Attempt DEFAULT 1
    , RepetitionsObserved TINYINT        NOT NULL CONSTRAINT DF_PracticalAssessment_Reps DEFAULT 0
    , RepetitionsPassed TINYINT          NOT NULL CONSTRAINT DF_PracticalAssessment_RepsPassed DEFAULT 0
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_PracticalAssessment_Status DEFAULT 1
        /* 1=InProgress 2=Submitted 3=Passed 4=Failed 5=Voided */
    , ScorePercent      DECIMAL(5,2)     NULL
    , IsPassed          BIT              NULL
    , CriticalFailureCount TINYINT       NOT NULL CONSTRAINT DF_PracticalAssessment_CritFail DEFAULT 0
    , EvaluatorComments NVARCHAR(MAX)    NULL
    , EmployeeComments  NVARCHAR(MAX)    NULL
    , StartedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_PracticalAssessment_StartedAtUtc DEFAULT SYSUTCDATETIME()
    , SubmittedAtUtc    DATETIME2(3)     NULL
    , EvaluatorSignatureId BIGINT        NULL       -- aud.SignatureRecord
    , EmployeeSignatureId BIGINT         NULL
    , SupersededByAssessmentId INT       NULL       -- correccion = nueva evaluacion
    , VoidReason        NVARCHAR(1000)   NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_PracticalAssessment PRIMARY KEY CLUSTERED (PracticalAssessmentId)
    , CONSTRAINT UQ_PracticalAssessment_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT FK_PracticalAssessment_Template FOREIGN KEY (PracticalTemplateId) REFERENCES asmt.PracticalAssessmentTemplate (PracticalTemplateId)
    , CONSTRAINT FK_PracticalAssessment_Employee FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT FK_PracticalAssessment_Superseded FOREIGN KEY (SupersededByAssessmentId) REFERENCES asmt.PracticalAssessment (PracticalAssessmentId)
    , CONSTRAINT CK_PracticalAssessment_Status CHECK ([Status] BETWEEN 1 AND 5)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PracticalAssessment_Employee' AND object_id = OBJECT_ID(N'asmt.PracticalAssessment'))
    CREATE NONCLUSTERED INDEX IX_PracticalAssessment_Employee ON asmt.PracticalAssessment (EmployeeId, [Status])
        INCLUDE (PracticalTemplateId, SubmittedAtUtc, IsPassed);
GO

IF OBJECT_ID(N'asmt.PracticalCriterionResult', N'U') IS NULL
CREATE TABLE asmt.PracticalCriterionResult (
      PracticalCriterionResultId INT     NOT NULL IDENTITY(1,1)
    , PracticalAssessmentId INT          NOT NULL
    , PracticalCriterionId INT           NOT NULL
    , CriterionTextSnapshot NVARCHAR(1000) NOT NULL  -- snapshot para auditoria
    , IsCriticalSnapshot BIT             NOT NULL
    , ResultCode        TINYINT          NOT NULL   -- 1=Pass 2=Fail 3=NotApplicable
    , Comments          NVARCHAR(1000)   NULL
    , RecordedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_PCR_RecordedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_PracticalCriterionResult PRIMARY KEY CLUSTERED (PracticalCriterionResultId)
    , CONSTRAINT UQ_PracticalCriterionResult UNIQUE (PracticalAssessmentId, PracticalCriterionId)
    , CONSTRAINT FK_PCR_Assessment FOREIGN KEY (PracticalAssessmentId) REFERENCES asmt.PracticalAssessment (PracticalAssessmentId)
    , CONSTRAINT FK_PCR_Criterion  FOREIGN KEY (PracticalCriterionId)  REFERENCES asmt.PracticalCriterion (PracticalCriterionId)
    , CONSTRAINT CK_PCR_ResultCode CHECK (ResultCode IN (1,2,3))
);
GO

IF OBJECT_ID(N'asmt.PracticalAssessmentAttachment', N'U') IS NULL
CREATE TABLE asmt.PracticalAssessmentAttachment (
      AttachmentId      INT              NOT NULL IDENTITY(1,1)
    , PracticalAssessmentId INT          NOT NULL
    , PracticalCriterionId INT           NULL
    , FileAssetId       INT              NOT NULL
    , [Description]     NVARCHAR(400)    NULL
    , UploadedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_PAA_UploadedAtUtc DEFAULT SYSUTCDATETIME()
    , UploadedByUserId  INT              NOT NULL
    , CONSTRAINT PK_PracticalAssessmentAttachment PRIMARY KEY CLUSTERED (AttachmentId)
    , CONSTRAINT FK_PAA_Assessment FOREIGN KEY (PracticalAssessmentId) REFERENCES asmt.PracticalAssessment (PracticalAssessmentId)
);
GO

PRINT '=== 05_tables_assessment.sql completado ===';
GO

/* ############################################################################
   ARCHIVO: database/06_tables_delivery.sql
   ############################################################################ */
/* =============================================================================
   Classroom LMS by Airlink
   06_tables_delivery.sql  -  dlv: inscripciones, progreso, cohortes, ILT
   ============================================================================= */
USE AIRLINK_KMS;
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
        WHERE [Status] <> 6 AND IsDeleted = 0;
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

/* ############################################################################
   ARCHIVO: database/07_tables_compliance.sql
   ############################################################################ */
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
USE AIRLINK_KMS;
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

/* ############################################################################
   ARCHIVO: database/08_tables_platform.sql
   ############################################################################ */
/* =============================================================================
   Classroom LMS by Airlink
   08_tables_platform.sql  -  aud (auditoria), intg (integracion), ops (plataforma)
   ============================================================================= */
USE AIRLINK_KMS;
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
      SyncWatermarkId   INT              NOT NULL IDENTITY(1,1)
    , SourceSystem      NVARCHAR(50)     NOT NULL   -- 'SPN','AIRLINK'
    , SourceEntity      NVARCHAR(80)     NOT NULL   -- 'Employee','Station'
    , WatermarkValue    NVARCHAR(100)    NULL       -- timestamp o rowversion serializado
    , LastRunAtUtc      DATETIME2(3)     NULL
    , LastSuccessAtUtc  DATETIME2(3)     NULL
    , LastRowCount      INT              NULL
    , ConsecutiveFailures INT            NOT NULL CONSTRAINT DF_SyncWatermark_Failures DEFAULT 0
    , IsEnabled         BIT              NOT NULL CONSTRAINT DF_SyncWatermark_IsEnabled DEFAULT 1
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , CONSTRAINT PK_SyncWatermark PRIMARY KEY CLUSTERED (SyncWatermarkId)
    , CONSTRAINT UQ_SyncWatermark UNIQUE (SourceSystem, SourceEntity)
);
GO

IF OBJECT_ID(N'intg.SyncRun', N'U') IS NULL
CREATE TABLE intg.SyncRun (
      SyncRunId         BIGINT           NOT NULL IDENTITY(1,1)
    , SourceSystem      NVARCHAR(50)     NOT NULL
    , SourceEntity      NVARCHAR(80)     NOT NULL
    , RunMode           TINYINT          NOT NULL CONSTRAINT DF_SyncRun_RunMode DEFAULT 1
                                         -- 1=Incremental 2=Full 3=Manual
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_SyncRun_Status DEFAULT 1
                                         -- 1=Running 2=Success 3=Failed 4=SuccessWithErrors
    , WatermarkFrom     NVARCHAR(100)    NULL
    , TriggeredBy       NVARCHAR(100)    NULL
    , RowsRead          INT              NOT NULL CONSTRAINT DF_SyncRun_RowsRead DEFAULT 0
    , RowsInserted      INT              NOT NULL CONSTRAINT DF_SyncRun_RowsInserted DEFAULT 0
    , RowsUpdated       INT              NOT NULL CONSTRAINT DF_SyncRun_RowsUpdated DEFAULT 0
    , RowsSkipped       INT              NOT NULL CONSTRAINT DF_SyncRun_RowsSkipped DEFAULT 0
    , RowsErrored       INT              NOT NULL CONSTRAINT DF_SyncRun_RowsErrored DEFAULT 0
    , StartedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_SyncRun_StartedAtUtc DEFAULT SYSUTCDATETIME()
    , CompletedAtUtc    DATETIME2(3)     NULL
    , DurationMs        AS DATEDIFF(MILLISECOND, StartedAtUtc, CompletedAtUtc)
    , ErrorMessage      NVARCHAR(4000)   NULL
    , CONSTRAINT PK_SyncRun PRIMARY KEY CLUSTERED (SyncRunId)
);
GO

IF OBJECT_ID(N'intg.EmployeeStaging', N'U') IS NULL
CREATE TABLE intg.EmployeeStaging (
      EmployeeStagingId BIGINT           NOT NULL IDENTITY(1,1)
    , SyncRunId         BIGINT           NOT NULL
    , SourceEmployeeCode NVARCHAR(30)    NOT NULL
    , FirstName         NVARCHAR(80)     NULL
    , LastName          NVARCHAR(80)     NULL
    , FullNameRaw       NVARCHAR(200)    NULL
    , NationalId        NVARCHAR(30)     NULL
    , Email             NVARCHAR(200)    NULL
    , PositionTitleRaw  NVARCHAR(150)    NULL
    , DepartmentRaw     NVARCHAR(150)    NULL
    , SiteRaw           NVARCHAR(100)    NULL
    , SupervisorCodeRaw NVARCHAR(30)     NULL
    , HireDate          DATE             NULL
    , TerminationDate   DATE             NULL
    , EmploymentStatusRaw NVARCHAR(50)   NULL
    , SourceRowHash     BINARY(32)       NULL       -- SHA-256: salta filas sin cambios
    , IsValid           BIT              NOT NULL CONSTRAINT DF_EmployeeStaging_IsValid DEFAULT 1
    , ValidationMessage NVARCHAR(1000)   NULL
    , LoadedAtUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_EmployeeStaging_LoadedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_EmployeeStaging PRIMARY KEY CLUSTERED (EmployeeStagingId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_EmployeeStaging_Run_Code' AND object_id = OBJECT_ID(N'intg.EmployeeStaging'))
    CREATE NONCLUSTERED INDEX IX_EmployeeStaging_Run_Code ON intg.EmployeeStaging (SyncRunId, SourceEmployeeCode);
GO

IF OBJECT_ID(N'intg.IntegrationError', N'U') IS NULL
CREATE TABLE intg.IntegrationError (
      IntegrationErrorId BIGINT          NOT NULL IDENTITY(1,1)
    , SyncRunId         BIGINT           NULL
    , SourceSystem      NVARCHAR(50)     NOT NULL
    , SourceEntity      NVARCHAR(80)     NOT NULL
    , SourceKey         NVARCHAR(100)    NULL       -- clave natural de la fila que fallo
    , ErrorCode         NVARCHAR(40)     NULL       -- 'UNRESOLVED_REFERENCE', ...
    , ErrorMessage      NVARCHAR(MAX)    NOT NULL
    , PayloadJson       NVARCHAR(MAX)    NULL
    , OccurredAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_IntegrationError_AtUtc DEFAULT SYSUTCDATETIME()
    , IsResolved        BIT              NOT NULL CONSTRAINT DF_IntegrationError_IsResolved DEFAULT 0
    , ResolvedAtUtc     DATETIME2(3)     NULL
    , ResolvedByUserId  INT              NULL
    , ResolutionNote    NVARCHAR(400)    NULL
    , CONSTRAINT PK_IntegrationError PRIMARY KEY CLUSTERED (IntegrationErrorId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_IntegrationError_Open' AND object_id = OBJECT_ID(N'intg.IntegrationError'))
    CREATE NONCLUSTERED INDEX IX_IntegrationError_Open
        ON intg.IntegrationError (SourceEntity, OccurredAtUtc DESC) WHERE IsResolved = 0;
GO

IF OBJECT_ID(N'intg.ExternalIdMap', N'U') IS NULL
CREATE TABLE intg.ExternalIdMap (
      ExternalIdMapId   INT              NOT NULL IDENTITY(1,1)
    , SourceSystem      NVARCHAR(50)     NOT NULL   -- 'SPN','AIRLINK','NEXUS','ENTRA'
    , EntityType        NVARCHAR(60)     NOT NULL
    , ExternalId        NVARCHAR(100)    NOT NULL
    , ExternalCode      NVARCHAR(100)    NULL
    , InternalId        INT              NOT NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_ExternalIdMap_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_ExternalIdMap_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , CONSTRAINT PK_ExternalIdMap PRIMARY KEY CLUSTERED (ExternalIdMapId)
    , CONSTRAINT UQ_ExternalIdMap UNIQUE (SourceSystem, EntityType, ExternalId)
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

/* ############################################################################
   ARCHIVO: database/09_functions.sql
   ############################################################################ */
/* =============================================================================
   Classroom LMS by Airlink
   09_functions.sql  -  Funciones escalares y con valores de tabla
   ============================================================================= */
USE AIRLINK_KMS;
GO
SET NOCOUNT ON;
GO

/* -----------------------------------------------------------------------------
   sec.fn_UserHasPermission
   Devuelve 1 si el usuario tiene el permiso en cualquier scope.
   Para validar scope especifico usar sec.fn_UserScopeIncludes.
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION sec.fn_UserHasPermission
(
      @UserId         INT
    , @PermissionCode NVARCHAR(80)
)
RETURNS BIT
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @Result BIT = 0;

    IF EXISTS (
        SELECT 1
        FROM sec.UserRoleAssignment ura
        JOIN sec.RolePermission     rp ON rp.RoleId = ura.RoleId
        JOIN sec.Permission         p  ON p.PermissionId = rp.PermissionId
        JOIN sec.Role               r  ON r.RoleId = ura.RoleId
        WHERE ura.UserId       = @UserId
          AND ura.IsActive     = 1
          AND ura.RevokedAtUtc IS NULL
          AND r.IsActive       = 1
          AND r.IsDeleted      = 0
          AND p.PermissionCode = @PermissionCode
    )
        SET @Result = 1;

    RETURN @Result;
END;
GO

/* -----------------------------------------------------------------------------
   sec.fn_UserScopeIncludes
   Verifica que el usuario tenga el permiso Y que el scope de su asignacion
   cubra el objetivo. Global cubre todo; Site cubre sus departamentos; etc.
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION sec.fn_UserScopeIncludes
(
      @UserId          INT
    , @PermissionCode  NVARCHAR(80)
    , @TargetSiteId    INT
    , @TargetDepartmentId INT
    , @TargetAreaId    INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @Result BIT = 0;

    IF EXISTS (
        SELECT 1
        FROM sec.UserRoleAssignment ura
        JOIN sec.RolePermission     rp ON rp.RoleId = ura.RoleId
        JOIN sec.Permission         p  ON p.PermissionId = rp.PermissionId
        WHERE ura.UserId       = @UserId
          AND ura.IsActive     = 1
          AND ura.RevokedAtUtc IS NULL
          AND p.PermissionCode = @PermissionCode
          AND (
                 ura.ScopeType = 1                                        -- Global
              OR (ura.ScopeType = 2 AND ura.ScopeId = @TargetSiteId)       -- Site
              OR (ura.ScopeType = 3 AND ura.ScopeId = @TargetDepartmentId) -- Department
              OR (ura.ScopeType = 4 AND ura.ScopeId = @TargetAreaId)       -- Area
              OR (ura.ScopeType = 2 AND EXISTS (
                     SELECT 1 FROM org.Department d
                     WHERE d.DepartmentId = @TargetDepartmentId
                       AND d.SiteId = ura.ScopeId))
              OR (ura.ScopeType = 3 AND EXISTS (
                     SELECT 1 FROM org.Area a
                     WHERE a.AreaId = @TargetAreaId
                       AND a.DepartmentId = ura.ScopeId))
          )
    )
        SET @Result = 1;

    RETURN @Result;
END;
GO

/* -----------------------------------------------------------------------------
   comp.fn_GetCertificationStatus
   Estado derivado de una certificacion en un momento dado.
   1=Valid 2=ExpiringSoon 3=Expired 4=RetrainingRequired 5=Revoked 6=Provisional
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION comp.fn_GetCertificationStatus
(
      @StoredStatus     TINYINT
    , @ExpiresAtUtc     DATETIME2(3)
    , @AlertWindowDays  INT
    , @AsOfUtc          DATETIME2(3)
)
RETURNS TINYINT
AS
BEGIN
    -- Revoked y RetrainingRequired son estados explicitos: no se derivan.
    IF @StoredStatus IN (4, 5) RETURN @StoredStatus;

    IF @ExpiresAtUtc IS NULL
        RETURN CASE WHEN @StoredStatus = 6 THEN 6 ELSE 1 END;

    IF @AsOfUtc > @ExpiresAtUtc                       RETURN 3;  -- Expired
    IF @AsOfUtc > DATEADD(DAY, -ISNULL(@AlertWindowDays, 30), @ExpiresAtUtc)
                                                       RETURN 2;  -- ExpiringSoon
    IF @StoredStatus = 6                               RETURN 6;  -- Provisional
    RETURN 1;                                                     -- Valid
END;
GO

/* -----------------------------------------------------------------------------
   comp.fn_GetEffectiveRequirements
   Requisitos efectivos de un empleado: union de todas sus posiciones vigentes,
   su departamento, su area, su sitio, los globales y los asignados a el
   directamente. Deduplicado quedandose con el nivel MAS ALTO exigido.

   Es la funcion mas usada del motor de compliance.
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION comp.fn_GetEffectiveRequirements (@EmployeeId INT)
RETURNS TABLE
AS
RETURN
(
    WITH EmployeeContext AS (
        SELECT  e.EmployeeId
              , e.SiteId
              , e.DepartmentId
              , e.AreaId
              , e.HireDateUtc
        FROM org.Employee e
        WHERE e.EmployeeId = @EmployeeId
    ),
    EmployeePositions AS (
        SELECT ep.PositionId
        FROM org.EmployeePosition ep
        WHERE ep.EmployeeId = @EmployeeId
          AND ep.EffectiveToUtc IS NULL
    ),
    EmployeeStations AS (
        SELECT ea.StationId
        FROM org.EmployeeAssignment ea
        WHERE ea.EmployeeId = @EmployeeId
          AND ea.EffectiveToUtc IS NULL
          AND ea.StationId IS NOT NULL
    ),
    Applicable AS (
        SELECT  r.RequirementId
              , r.CompetencyId
              , r.MinimumLevelId
              , r.ValidityMonths
              , r.AlertWindowDays
              , r.Criticality
              , r.RegulatoryBasis
              , r.GracePeriodDays
              , r.AllowProvisional
              , r.AppliesFromHireDays
              , r.ScopeType
              , cl.LevelOrdinal AS RequiredLevelOrdinal
        FROM comp.CompetencyRequirement r
        JOIN comp.CompetencyLevel cl ON cl.CompetencyLevelId = r.MinimumLevelId
        CROSS JOIN EmployeeContext ec
        WHERE r.[Status] = 1
          AND (r.EffectiveToUtc IS NULL OR r.EffectiveToUtc > SYSUTCDATETIME())
          AND r.EffectiveFromUtc <= SYSUTCDATETIME()
          -- el requisito aplica solo despues de N dias desde el ingreso
          AND (ec.HireDateUtc IS NULL
               OR DATEADD(DAY, r.AppliesFromHireDays, ec.HireDateUtc) <= SYSUTCDATETIME())
          AND (
                 (r.ScopeType = 7)                                                    -- Global
              OR (r.ScopeType = 6 AND r.ScopeId = ec.SiteId)                          -- Site
              OR (r.ScopeType = 2 AND r.ScopeId = ec.DepartmentId)                    -- Department
              OR (r.ScopeType = 3 AND r.ScopeId = ec.AreaId)                          -- Area
              OR (r.ScopeType = 5 AND r.ScopeId = ec.EmployeeId)                      -- Employee
              OR (r.ScopeType = 1 AND r.ScopeId IN (SELECT PositionId FROM EmployeePositions))
              OR (r.ScopeType = 4 AND r.ScopeId IN (SELECT StationId  FROM EmployeeStations))
          )
    ),
    Ranked AS (
        SELECT  a.*
              , ROW_NUMBER() OVER (
                    PARTITION BY a.CompetencyId
                    ORDER BY a.RequiredLevelOrdinal DESC   -- gana el nivel mas alto
                           , a.Criticality ASC             -- luego el mas critico
                           , a.RequirementId ASC
                ) AS rn
        FROM Applicable a
    )
    SELECT  RequirementId
          , CompetencyId
          , MinimumLevelId
          , RequiredLevelOrdinal
          , ValidityMonths
          , AlertWindowDays
          , Criticality
          , RegulatoryBasis
          , GracePeriodDays
          , AllowProvisional
          , ScopeType
    FROM Ranked
    WHERE rn = 1
);
GO

/* -----------------------------------------------------------------------------
   comp.fn_HasActiveWaiver
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION comp.fn_HasActiveWaiver
(
      @EmployeeId    INT
    , @RequirementId INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @Result BIT = 0;

    IF EXISTS (
        SELECT 1
        FROM comp.Waiver w
        WHERE w.EmployeeId    = @EmployeeId
          AND w.RequirementId = @RequirementId
          AND w.[Status]      = 2                                  -- Approved
          AND w.RevokedAtUtc IS NULL
          AND (w.EffectiveFromUtc IS NULL OR w.EffectiveFromUtc <= SYSUTCDATETIME())
          AND (w.ExpiresAtUtc     IS NULL OR w.ExpiresAtUtc     >  SYSUTCDATETIME())
    )
        SET @Result = 1;

    RETURN @Result;
END;
GO

/* -----------------------------------------------------------------------------
   ops.fn_SplitAlertWindow -> primer valor (el mas amplio) de '60,30,7'
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION ops.fn_FirstAlertWindowDays (@AlertWindowDays NVARCHAR(50))
RETURNS INT
AS
BEGIN
    IF @AlertWindowDays IS NULL OR LEN(@AlertWindowDays) = 0 RETURN 30;

    DECLARE @First NVARCHAR(20) =
        CASE WHEN CHARINDEX(N',', @AlertWindowDays) > 0
             THEN LEFT(@AlertWindowDays, CHARINDEX(N',', @AlertWindowDays) - 1)
             ELSE @AlertWindowDays
        END;

    RETURN TRY_CONVERT(INT, LTRIM(RTRIM(@First)));
END;
GO

/* -----------------------------------------------------------------------------
   org.fn_GetTeamEmployeeIds
   Reportes directos e indirectos de un supervisor (jerarquia recursiva).
   -------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION org.fn_GetTeamEmployeeIds
(
      @SupervisorEmployeeId INT
    , @IncludeIndirect      BIT
)
RETURNS TABLE
AS
RETURN
(
    WITH Team AS (
        SELECT e.EmployeeId, 1 AS [Level]
        FROM org.Employee e
        WHERE e.SupervisorEmployeeId = @SupervisorEmployeeId
          AND e.IsActive = 1

        UNION ALL

        SELECT e.EmployeeId, t.[Level] + 1
        FROM org.Employee e
        JOIN Team t ON t.EmployeeId = e.SupervisorEmployeeId
        WHERE @IncludeIndirect = 1
          AND e.IsActive = 1
          AND t.[Level] < 10          -- corta ciclos de datos malos
    )
    SELECT EmployeeId, [Level] FROM Team
);
GO

PRINT '=== 09_functions.sql completado ===';
GO

/* ############################################################################
   ARCHIVO: database/10_views_reporting.sql
   ############################################################################ */
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

/* ############################################################################
   ARCHIVO: database/18_procs_platform.sql
   ############################################################################ */
/* =====================================================================
   Classroom - LMS by Airlink
   18_procs_platform.sql
   Esquemas: aud (auditoria, firmas) + ops (notificaciones, settings,
             flags, archivos, jobs, retencion)

   Este archivo es dependencia de TODOS los demas: cada SP de negocio
   llama a aud.usp_Error_Log, aud.usp_Event_Log, aud.usp_Signature_Create
   u ops.usp_Notification_Enqueue. Por eso se despliega antes en el
   orden de ejecucion aunque lleve numero 18 (ver scripts/deploy-db.ps1,
   que reordena: 18 corre justo despues de las vistas).

   La pieza critica es la CADENA DE FIRMAS (GAP-06):

     firma[n].PreviousHash = firma[n-1].PayloadHash   (por empleado)

   Si alguien edita una fila del historial, el PayloadHash deja de
   cuadrar con el PreviousHash de la siguiente y la verificacion lo
   canta. Eso convierte "confien en nosotros" en "verifiquenlo ustedes".

   Codigos de error de este archivo: 50700-50799
   ===================================================================== */

USE AIRLINK_KMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 18_procs_platform.sql iniciado ===';
GO

/* =====================================================================
   aud.usp_Error_Log

   Se llama SIEMPRE desde el CATCH. Nunca lanza: si el logger falla, se
   traga el error. Un fallo del logger no puede convertirse en el error
   que ve el usuario en vez del error real.
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_Error_Log
      @ProcedureName  NVARCHAR(150) = NULL
    , @ActorUserId    INT           = NULL
    , @ParametersJson NVARCHAR(MAX) = NULL
    , @CorrelationId  UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        INSERT INTO aud.ErrorLog (ProcedureName, ErrorNumber, ErrorSeverity, ErrorState
                                , ErrorLine, ErrorMessage, ActorUserId, ParametersJson, CorrelationId)
        VALUES (ISNULL(@ProcedureName, ERROR_PROCEDURE())
              , ERROR_NUMBER(), ERROR_SEVERITY(), ERROR_STATE()
              , ERROR_LINE(), ERROR_MESSAGE(), @ActorUserId, @ParametersJson, @CorrelationId);
    END TRY
    BEGIN CATCH
        /* Silencio intencional. */
    END CATCH;
    RETURN 0;
END;
GO

/* =====================================================================
   aud.usp_Event_Log

   Bitacora de negocio. La firma de parametros usa @EventType con formato
   'Entidad.Accion' porque asi lo llaman los SPs de negocio; aqui se
   parte y se guarda en las columnas reales EntityType / [Action].
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_Event_Log
      @EventType     NVARCHAR(120)
    , @EntityType    NVARCHAR(60)  = NULL
    , @EntityId      INT           = NULL
    , @EntityPublicId UNIQUEIDENTIFIER = NULL
    , @EmployeeId    INT           = NULL
    , @ActorUserId   INT           = NULL
    , @Severity      TINYINT       = 1
    , @Summary       NVARCHAR(1000) = NULL
    , @OldValuesJson NVARCHAR(MAX) = NULL
    , @NewValuesJson NVARCHAR(MAX) = NULL
    , @SessionId     UNIQUEIDENTIFIER = NULL
    , @DeviceId      INT           = NULL
    , @IpAddress     NVARCHAR(45)  = NULL
    , @CorrelationId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @Dot INT = CHARINDEX(N'.', @EventType);

        INSERT INTO aud.EventLog (ActorUserId, ActorEmployeeId, EntityType, EntityId, EntityPublicId
                                , [Action], Severity, [Description]
                                , OldValuesJson, NewValuesJson, ProcedureName
                                , SessionId, DeviceId, IpAddress, CorrelationId)
        VALUES ( @ActorUserId
               , COALESCE(@EmployeeId, (SELECT EmployeeId FROM sec.[User] WHERE UserId = @ActorUserId))
               , COALESCE(@EntityType, CASE WHEN @Dot > 1 THEN LEFT(@EventType, @Dot - 1) ELSE @EventType END)
               , @EntityId
               , @EntityPublicId
               , CASE WHEN @Dot > 0 THEN SUBSTRING(@EventType, @Dot + 1, 60) ELSE @EventType END
               , ISNULL(@Severity, 1)
               , @Summary
               , @OldValuesJson, @NewValuesJson, ERROR_PROCEDURE()
               , @SessionId, @DeviceId, @IpAddress, @CorrelationId);
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'aud.usp_Event_Log', @ActorUserId = @ActorUserId;
    END CATCH;
    RETURN 0;
END;
GO

/* =====================================================================
   aud.usp_Signature_Create        -- GAP-06, el corazon de la evidencia

   Una firma es: el payload canonico de lo que se firmo, su hash, y el
   hash de la firma anterior de ESE MISMO empleado. Con eso queda una
   cadena por persona que no se puede reordenar ni editar en silencio.

   El UPDLOCK/HOLDLOCK sobre la ultima firma del empleado es lo que
   evita que dos firmas concurrentes tomen el mismo SequenceNumber. La
   restriccion UQ_SignatureRecord_Sequence es la red de seguridad si
   aun asi se cuela una carrera.

   @SignatureMeaning llega como texto desde los SPs de negocio
   ('Acknowledged','Evaluated','Certified','Approved','Reviewed') y se
   traduce al TINYINT SignatureType que guarda la tabla.
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_Signature_Create
      @ActorUserId       INT
    , @SignatureMeaning  NVARCHAR(40)
    , @EntityType        NVARCHAR(60)
    , @EntityId          INT
    , @PayloadCanonical  NVARCHAR(MAX)
    , @AuthMethod        TINYINT       = 1
    , @EmployeeId        INT           = NULL
    , @DeviceId          INT           = NULL
    , @IpAddress         NVARCHAR(45)  = NULL
    , @SignatureRecordId BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50701 el usuario no tiene empleado asociado
                50702 payload vacio
                50703 payload demasiado largo                            */
    BEGIN TRY
        IF @PayloadCanonical IS NULL OR LEN(@PayloadCanonical) = 0
            THROW 50702, 'No se puede firmar un payload vacio.', 1;

        /* La columna guarda 2000 chars: es una huella, no el documento.
           Si el payload viene mas largo, el llamador esta metiendo datos
           que no pertenecen a la firma. */
        IF LEN(@PayloadCanonical) > 2000
            THROW 50703, 'El payload canonico de la firma excede 2000 caracteres.', 1;

        SELECT @EmployeeId = COALESCE(@EmployeeId, EmployeeId)
        FROM sec.[User] WHERE UserId = @ActorUserId;

        IF @EmployeeId IS NULL
            THROW 50701, 'El usuario que firma no tiene empleado asociado.', 1;

        DECLARE @SignatureType TINYINT = CASE @SignatureMeaning
                    WHEN N'Acknowledged' THEN 1
                    WHEN N'Attended'     THEN 2
                    WHEN N'Roster'       THEN 3
                    WHEN N'Evaluated'    THEN 4
                    WHEN N'Evaluatee'    THEN 5
                    WHEN N'Certified'    THEN 6
                    WHEN N'Waiver'       THEN 7
                    WHEN N'Approved'     THEN 8
                    WHEN N'Reviewed'     THEN 8
                    WHEN N'Submitted'    THEN 9
                    ELSE 1 END;

        DECLARE @PayloadHash  VARBINARY(32) = HASHBYTES('SHA2_256', @PayloadCanonical)
              , @PreviousHash VARBINARY(32)
              , @Sequence     INT;

        DECLARE @OwnsTran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
        IF @OwnsTran = 1 BEGIN TRANSACTION;

        /* Ultimo eslabon de la cadena de ESTE empleado. El lock se
           sostiene hasta el commit: es lo que serializa las firmas
           concurrentes de la misma persona. */
        SELECT TOP (1) @PreviousHash = s.PayloadHash, @Sequence = s.SequenceNumber
        FROM aud.SignatureRecord s WITH (UPDLOCK, HOLDLOCK)
        WHERE s.EmployeeId = @EmployeeId
        ORDER BY s.SequenceNumber DESC;

        SET @Sequence = ISNULL(@Sequence, 0) + 1;   -- 1 = genesis, PreviousHash NULL

        INSERT INTO aud.SignatureRecord (EmployeeId, UserId, SignatureType, EntityType, EntityId
                                       , PayloadCanonical, PayloadHash, PreviousHash, SequenceNumber
                                       , AuthMethod, DeviceId, IpAddress)
        VALUES (@EmployeeId, @ActorUserId, @SignatureType, @EntityType, @EntityId
              , @PayloadCanonical, @PayloadHash, @PreviousHash, @Sequence
              , @AuthMethod, @DeviceId, @IpAddress);

        SET @SignatureRecordId = SCOPE_IDENTITY();

        IF @OwnsTran = 1 COMMIT TRANSACTION;

        SELECT @SignatureRecordId AS SignatureId, @Sequence AS SequenceNumber
             , CONVERT(NVARCHAR(64), @PayloadHash, 2) AS PayloadHashHex;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @OwnsTran = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'aud.usp_Signature_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   aud.usp_Signature_Verify

   Recorre las cadenas y reporta el primer eslabon roto de cada empleado.
   Dos comprobaciones independientes por fila:
     1. Recalcular SHA-256 del payload y compararlo con PayloadHash
        -> detecta edicion del contenido firmado.
     2. Comparar PreviousHash con el PayloadHash de la firma anterior
        -> detecta insercion, borrado o reordenamiento de filas.

   Este resultset va dentro del paquete de auditoria (rpt.usp_AuditEvidence_
   GeneratePackage). Es la diferencia entre un reporte y una prueba.
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_Signature_Verify
      @ActorUserId INT          = NULL
    , @EmployeeId  INT          = NULL
    , @FromUtc     DATETIME2(3) = NULL
    , @ToUtc       DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SET @FromUtc = ISNULL(@FromUtc, '1900-01-01');
        SET @ToUtc   = ISNULL(@ToUtc, SYSUTCDATETIME());

        ;WITH Chain AS (
            SELECT  s.SignatureId
                  , s.EmployeeId
                  , s.SequenceNumber
                  , s.EntityType
                  , s.EntityId
                  , s.SignedAtUtc
                  , s.PayloadHash
                  , s.PreviousHash
                  , RecomputedHash = HASHBYTES('SHA2_256', s.PayloadCanonical)
                  , ExpectedPrevious = LAG(s.PayloadHash) OVER (PARTITION BY s.EmployeeId
                                                                ORDER BY s.SequenceNumber)
                  , ExpectedSequence = ROW_NUMBER() OVER (PARTITION BY s.EmployeeId
                                                          ORDER BY s.SequenceNumber)
            FROM aud.SignatureRecord s
            WHERE (@EmployeeId IS NULL OR s.EmployeeId = @EmployeeId)
        )
        , Checked AS (
            SELECT  c.*
                  , IsPayloadIntact = CASE WHEN c.RecomputedHash = c.PayloadHash THEN 1 ELSE 0 END
                  , IsLinkIntact = CASE
                        WHEN c.SequenceNumber = 1 AND c.PreviousHash IS NULL THEN 1
                        WHEN c.PreviousHash = c.ExpectedPrevious THEN 1
                        ELSE 0 END
                  , IsSequenceIntact = CASE WHEN c.SequenceNumber = c.ExpectedSequence THEN 1 ELSE 0 END
            FROM Chain c
        )
        /* Resultset 1: resumen por empleado */
        SELECT  ch.EmployeeId
              , e.EmployeeCode
              , e.FullName
              , COUNT(*)                                                  AS SignatureCount
              , MIN(ch.SignedAtUtc)                                       AS FirstSignedAtUtc
              , MAX(ch.SignedAtUtc)                                       AS LastSignedAtUtc
              , SUM(CASE WHEN ch.IsPayloadIntact = 0 THEN 1 ELSE 0 END)   AS TamperedPayloads
              , SUM(CASE WHEN ch.IsLinkIntact = 0 THEN 1 ELSE 0 END)      AS BrokenLinks
              , SUM(CASE WHEN ch.IsSequenceIntact = 0 THEN 1 ELSE 0 END)  AS SequenceAnomalies
              , MIN(CASE WHEN ch.IsPayloadIntact = 0 OR ch.IsLinkIntact = 0
                         THEN ch.SequenceNumber END)                      AS FirstBrokenSequence
              , CASE WHEN SUM(CASE WHEN ch.IsPayloadIntact = 0 OR ch.IsLinkIntact = 0
                                        OR ch.IsSequenceIntact = 0 THEN 1 ELSE 0 END) = 0
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END          AS IsChainValid
        INTO #ChainSummary
        FROM Checked ch
        JOIN org.Employee e ON e.EmployeeId = ch.EmployeeId
        GROUP BY ch.EmployeeId, e.EmployeeCode, e.FullName;

        SELECT * FROM #ChainSummary ORDER BY IsChainValid, EmployeeCode;

        /* Resultset 2: veredicto global del periodo */
        SELECT  COUNT(*)                                              AS ChainsVerified
              , SUM(CASE WHEN IsChainValid = 1 THEN 1 ELSE 0 END)     AS ValidChains
              , SUM(CASE WHEN IsChainValid = 0 THEN 1 ELSE 0 END)     AS CompromisedChains
              , SUM(SignatureCount)                                   AS TotalSignatures
              , CASE WHEN SUM(CASE WHEN IsChainValid = 0 THEN 1 ELSE 0 END) = 0
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END      AS AllChainsValid
              , SYSUTCDATETIME()                                      AS VerifiedAtUtc
              , @FromUtc AS PeriodFromUtc, @ToUtc AS PeriodToUtc
        FROM #ChainSummary;

        /* Resultset 3: detalle de las firmas rotas, si las hay.
           Si esto trae filas, alguien toco la base por fuera de la
           aplicacion y hay que investigarlo, no explicarlo. */
        SELECT TOP (500)
                s.SignatureId, s.EmployeeId, e.EmployeeCode, e.FullName
              , s.SequenceNumber, s.EntityType, s.EntityId, s.SignedAtUtc
              , CASE WHEN HASHBYTES('SHA2_256', s.PayloadCanonical) = s.PayloadHash
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsPayloadIntact
              , CONVERT(NVARCHAR(64), s.PayloadHash, 2)  AS StoredHashHex
              , CONVERT(NVARCHAR(64), s.PreviousHash, 2) AS PreviousHashHex
        FROM aud.SignatureRecord s
        JOIN org.Employee e ON e.EmployeeId = s.EmployeeId
        JOIN #ChainSummary cs ON cs.EmployeeId = s.EmployeeId AND cs.IsChainValid = 0
        WHERE HASHBYTES('SHA2_256', s.PayloadCanonical) <> s.PayloadHash
           OR s.SequenceNumber >= ISNULL(cs.FirstBrokenSequence, 2147483647)
        ORDER BY s.EmployeeId, s.SequenceNumber;

        DROP TABLE #ChainSummary;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#ChainSummary') IS NOT NULL DROP TABLE #ChainSummary;
        EXEC aud.usp_Error_Log @ProcedureName = N'aud.usp_Signature_Verify', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE aud.usp_Signature_Get
      @ActorUserId INT, @SignatureId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT  s.SignatureId, s.PublicId, s.EmployeeId, e.EmployeeCode, e.FullName
          , u.DisplayName AS SignedByName
          , s.SignatureType, s.EntityType, s.EntityId
          , s.PayloadCanonical
          , CONVERT(NVARCHAR(64), s.PayloadHash, 2)  AS PayloadHashHex
          , CONVERT(NVARCHAR(64), s.PreviousHash, 2) AS PreviousHashHex
          , s.SequenceNumber, s.AuthMethod, s.SignedAtUtc, s.DeviceId, s.IpAddress
          , CASE WHEN HASHBYTES('SHA2_256', s.PayloadCanonical) = s.PayloadHash
                 THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsPayloadIntact
    FROM aud.SignatureRecord s
    JOIN org.Employee e ON e.EmployeeId = s.EmployeeId
    LEFT JOIN sec.[User] u ON u.UserId = s.UserId
    WHERE s.SignatureId = @SignatureId;
    RETURN 0;
END;
GO

/* =====================================================================
   aud.usp_DataAccess_Log

   Quien miro el expediente de quien. Si no hay sujeto identificable
   (consultas agregadas como la matriz completa), se registra como
   evento en vez de forzar una fila sin sujeto.
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_DataAccess_Log
      @ActorUserId       INT
    , @AccessType        TINYINT       = 1
    , @EntityType        NVARCHAR(60)  = NULL
    , @SubjectEmployeeId INT           = NULL
    , @RecordCount       INT           = NULL
    , @Purpose           NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @SubjectEmployeeId IS NOT NULL
            INSERT INTO aud.DataAccessLog (ActorUserId, SubjectEmployeeId, AccessType, [Context])
            VALUES (@ActorUserId, @SubjectEmployeeId, @AccessType
                  , LEFT(CONCAT(ISNULL(@EntityType, N''), N' | ', ISNULL(@Purpose, N'')
                              , CASE WHEN @RecordCount IS NULL THEN N''
                                     ELSE N' | registros: ' + CAST(@RecordCount AS NVARCHAR(12)) END), 200));
        ELSE
            EXEC aud.usp_Event_Log
                  @EventType = N'DataAccess.Query'
                , @EntityType = @EntityType
                , @ActorUserId = @ActorUserId
                , @Severity = 3
                , @Summary = @Purpose;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'aud.usp_DataAccess_Log', @ActorUserId = @ActorUserId;
    END CATCH;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE aud.usp_Event_List
      @ActorUserId INT
    , @EntityType  NVARCHAR(60)  = NULL
    , @EntityId    INT           = NULL
    , @EmployeeId  INT           = NULL
    , @Severity    TINYINT       = NULL
    , @FromUtc     DATETIME2(3)  = NULL
    , @ToUtc       DATETIME2(3)  = NULL
    , @PageNumber  INT = 1
    , @PageSize    INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @FromUtc = ISNULL(@FromUtc, DATEADD(DAY, -30, SYSUTCDATETIME()));
    SET @ToUtc   = ISNULL(@ToUtc, SYSUTCDATETIME());

    SELECT  el.EventLogId, el.OccurredAtUtc, el.EntityType, el.EntityId, el.[Action]
          , el.Severity, el.[Description]
          , el.ActorUserId, u.DisplayName AS ActorName
          , el.ActorEmployeeId, e.EmployeeCode
          , el.IpAddress, el.CorrelationId
    FROM aud.EventLog el
    LEFT JOIN sec.[User] u ON u.UserId = el.ActorUserId
    LEFT JOIN org.Employee e ON e.EmployeeId = el.ActorEmployeeId
    WHERE el.OccurredAtUtc BETWEEN @FromUtc AND @ToUtc
      AND (@EntityType IS NULL OR el.EntityType      = @EntityType)
      AND (@EntityId   IS NULL OR el.EntityId        = @EntityId)
      AND (@EmployeeId IS NULL OR el.ActorEmployeeId = @EmployeeId)
      AND (@Severity   IS NULL OR el.Severity       >= @Severity)
    ORDER BY el.OccurredAtUtc DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

/* =====================================================================
   aud.usp_Idempotency_Register

   Reintentos de red no deben crear dos inscripciones ni dos intentos.
   El cliente manda un GUID; si ya se vio, se devuelve el resultado
   anterior en vez de repetir la operacion.
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_Idempotency_Register
      @IdempotencyKey  UNIQUEIDENTIFIER
    , @OperationName   NVARCHAR(150)
    , @ActorUserId     INT = NULL
    , @ResultEntityId  INT = NULL
    , @ResultJson      NVARCHAR(MAX) = NULL
    , @TtlHours        INT = 24
    , @WasAlreadySeen  BIT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SET @WasAlreadySeen = 0;

        SELECT @WasAlreadySeen = 1, @ResultEntityId = ResultEntityId, @ResultJson = ResultJson
        FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey;

        IF @WasAlreadySeen = 0
            INSERT INTO aud.IdempotencyKey (IdempotencyKey, OperationName, ActorUserId
                                          , ResultEntityId, ResultJson, ExpiresAtUtc)
            VALUES (@IdempotencyKey, @OperationName, @ActorUserId
                  , @ResultEntityId, @ResultJson, DATEADD(HOUR, @TtlHours, SYSUTCDATETIME()));

        SELECT @WasAlreadySeen AS WasAlreadySeen, @ResultEntityId AS ResultEntityId, @ResultJson AS ResultJson;
        RETURN 0;
    END TRY
    BEGIN CATCH
        /* Violacion de PK = otra sesion gano la carrera. Eso ES el
           comportamiento idempotente correcto, no un error. */
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            SET @WasAlreadySeen = 1;
            SELECT 1 AS WasAlreadySeen, ResultEntityId, ResultJson
            FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey;
            RETURN 0;
        END;
        EXEC aud.usp_Error_Log @ProcedureName = N'aud.usp_Idempotency_Register', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   ops.usp_Notification_Enqueue

   Encola, no envia. El worker externo hace el envio real.

   @DedupeKey se guarda dentro del PayloadJson y se consulta con
   JSON_VALUE: asi el job de vencimientos puede correr todas las noches
   durante 60 dias sin mandar 60 correos iguales.
   ===================================================================== */
CREATE OR ALTER PROCEDURE ops.usp_Notification_Enqueue
      @TemplateCode        NVARCHAR(80)
    , @RecipientUserId     INT           = NULL
    , @RecipientEmployeeId INT           = NULL
    , @Channel             TINYINT       = NULL
    , @LocaleCode          NVARCHAR(10)  = NULL
    , @ModelJson           NVARCHAR(MAX) = NULL
    , @Priority            TINYINT       = 3
    , @DedupeKey           NVARCHAR(120) = NULL
    , @NotifySupervisor    BIT           = 0
    , @CorrelationId       UNIQUEIDENTIFIER = NULL
    , @NotificationId      BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    /* Errores: 50710 sin destinatario */
    BEGIN TRY
        IF @RecipientUserId IS NULL AND @RecipientEmployeeId IS NULL
            THROW 50710, 'La notificacion necesita un destinatario.', 1;

        /* Completar el par usuario/empleado y el idioma preferido. */
        SELECT TOP (1)
               @RecipientUserId     = COALESCE(@RecipientUserId, u.UserId)
             , @RecipientEmployeeId = COALESCE(@RecipientEmployeeId, u.EmployeeId)
             , @LocaleCode          = COALESCE(@LocaleCode, u.PreferredLocale)
        FROM sec.[User] u
        WHERE (@RecipientUserId IS NOT NULL AND u.UserId = @RecipientUserId)
           OR (@RecipientUserId IS NULL AND u.EmployeeId = @RecipientEmployeeId AND u.IsActive = 1);

        SET @LocaleCode = ISNULL(@LocaleCode, N'es-DO');

        /* Dedupe: si ya hay una notificacion con la misma llave que no
           haya fallado, no se encola otra. */
        IF @DedupeKey IS NOT NULL
           AND EXISTS (SELECT 1 FROM ops.NotificationQueue q
                       WHERE q.TemplateKey = @TemplateCode
                         AND q.[Status] IN (1, 2, 3)
                         AND JSON_VALUE(q.PayloadJson, N'$.dedupeKey') = @DedupeKey)
        BEGIN
            SELECT NULL AS NotificationId, 1 AS WasDeduped;
            RETURN 0;
        END;

        /* Canal por defecto segun el template disponible en ese idioma. */
        IF @Channel IS NULL
            SELECT TOP (1) @Channel = t.Channel
            FROM ops.NotificationTemplate t
            WHERE t.TemplateKey = @TemplateCode AND t.IsActive = 1
              AND t.LocaleCode IN (@LocaleCode, N'es-DO')
            ORDER BY CASE WHEN t.LocaleCode = @LocaleCode THEN 0 ELSE 1 END;

        SET @Channel = ISNULL(@Channel, 1);

        DECLARE @Payload NVARCHAR(MAX) = JSON_MODIFY(
              JSON_MODIFY(ISNULL(NULLIF(@ModelJson, N''), N'{}')
                        , N'$.dedupeKey', @DedupeKey)
            , N'$.recipientEmployeeId', @RecipientEmployeeId);

        INSERT INTO ops.NotificationQueue (TemplateKey, Channel, LocaleCode, RecipientUserId
                                         , RecipientEmployeeId, RecipientAddress, PayloadJson
                                         , Priority, CorrelationId)
        SELECT @TemplateCode, @Channel, @LocaleCode, @RecipientUserId
             , @RecipientEmployeeId
             , (SELECT TOP (1) u.Email FROM sec.[User] u WHERE u.UserId = @RecipientUserId)
             , @Payload, ISNULL(@Priority, 3), @CorrelationId;

        SET @NotificationId = SCOPE_IDENTITY();

        /* Escalamiento al supervisor: se usa para vencimientos criticos y
           re-entrenamiento obligatorio. El supervisor es quien realmente
           puede liberar tiempo del operador para que lo haga. */
        IF @NotifySupervisor = 1 AND @RecipientEmployeeId IS NOT NULL
        BEGIN
            DECLARE @SupervisorEmployeeId INT;
            SELECT @SupervisorEmployeeId = SupervisorEmployeeId
            FROM org.Employee WHERE EmployeeId = @RecipientEmployeeId;

            IF @SupervisorEmployeeId IS NOT NULL
                INSERT INTO ops.NotificationQueue (TemplateKey, Channel, LocaleCode
                                                 , RecipientEmployeeId, PayloadJson, Priority, CorrelationId)
                SELECT @TemplateCode, @Channel, @LocaleCode, @SupervisorEmployeeId
                     , JSON_MODIFY(JSON_MODIFY(@Payload, N'$.isSupervisorCopy', CAST(1 AS BIT))
                                 , N'$.dedupeKey'
                                 , CASE WHEN @DedupeKey IS NULL THEN NULL ELSE @DedupeKey + N'-SUP' END)
                     , ISNULL(@Priority, 3), @CorrelationId;
        END;

        SELECT @NotificationId AS NotificationId, 0 AS WasDeduped;
        RETURN 0;
    END TRY
    BEGIN CATCH
        /* Una notificacion que no sale no puede tumbar una certificacion
           que si se emitio. Se registra y se sigue. */
        EXEC aud.usp_Error_Log @ProcedureName = N'ops.usp_Notification_Enqueue';
        RETURN 0;
    END CATCH;
END;
GO

/* =====================================================================
   ops.usp_Notification_Dequeue

   READPAST + UPDLOCK: varios workers pueden tomar lotes a la vez sin
   pisarse ni bloquearse entre ellos.
   ===================================================================== */
CREATE OR ALTER PROCEDURE ops.usp_Notification_Dequeue
      @BatchSize INT = 50
    , @Channel   TINYINT = NULL
    , @WorkerId  NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @Taken TABLE (NotificationId BIGINT);

        UPDATE TOP (@BatchSize) q
        SET q.[Status] = 2                       -- Processing
          , q.AttemptCount = q.AttemptCount + 1
        OUTPUT inserted.NotificationId INTO @Taken
        FROM ops.NotificationQueue q WITH (READPAST, UPDLOCK, ROWLOCK)
        WHERE q.[Status] = 1
          AND q.NextAttemptAtUtc <= SYSUTCDATETIME()
          AND (@Channel IS NULL OR q.Channel = @Channel);

        SELECT  q.NotificationId, q.TemplateKey, q.Channel, q.LocaleCode
              , q.RecipientUserId, q.RecipientEmployeeId
              , COALESCE(q.RecipientAddress, u.Email, e.Email) AS RecipientAddress
              , COALESCE(e.FullName, u.DisplayName) AS RecipientName
              , q.PayloadJson, q.Priority, q.AttemptCount, q.CorrelationId
              , t.[Subject], t.BodyTemplate
        FROM ops.NotificationQueue q
        JOIN @Taken tk ON tk.NotificationId = q.NotificationId
        LEFT JOIN sec.[User] u ON u.UserId = q.RecipientUserId
        LEFT JOIN org.Employee e ON e.EmployeeId = q.RecipientEmployeeId
        OUTER APPLY (SELECT TOP (1) t2.[Subject], t2.BodyTemplate
                     FROM ops.NotificationTemplate t2
                     WHERE t2.TemplateKey = q.TemplateKey AND t2.Channel = q.Channel
                       AND t2.IsActive = 1
                       AND t2.LocaleCode IN (q.LocaleCode, N'es-DO')
                     ORDER BY CASE WHEN t2.LocaleCode = q.LocaleCode THEN 0 ELSE 1 END) t
        ORDER BY q.Priority, q.EnqueuedAtUtc;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'ops.usp_Notification_Dequeue';
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_Notification_MarkSent
      @NotificationId BIGINT
    , @Success        BIT = 1
    , @ErrorMessage   NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* Backoff exponencial: 2, 4, 8, 16, 32 minutos. Agotados los
       intentos, pasa a DeadLetter para revision humana. */
    UPDATE ops.NotificationQueue
    SET [Status] = CASE WHEN @Success = 1 THEN 3
                        WHEN AttemptCount >= MaxAttempts THEN 5
                        ELSE 1 END
      , SentAtUtc = CASE WHEN @Success = 1 THEN SYSUTCDATETIME() ELSE NULL END
      , LastError = CASE WHEN @Success = 1 THEN NULL ELSE @ErrorMessage END
      , NextAttemptAtUtc = CASE WHEN @Success = 1 THEN NextAttemptAtUtc
                                ELSE DATEADD(MINUTE, POWER(2, AttemptCount), SYSUTCDATETIME()) END
    WHERE NotificationId = @NotificationId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_Notification_GetDeadLetter
      @ActorUserId INT = NULL, @Top INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top)
           q.NotificationId, q.TemplateKey, q.Channel, q.RecipientEmployeeId
         , e.EmployeeCode, e.FullName
         , q.AttemptCount, q.LastError, q.EnqueuedAtUtc, q.PayloadJson
    FROM ops.NotificationQueue q
    LEFT JOIN org.Employee e ON e.EmployeeId = q.RecipientEmployeeId
    WHERE q.[Status] = 5
    ORDER BY q.EnqueuedAtUtc DESC;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_NotificationTemplate_Upsert
      @ActorUserId INT, @TemplateKey NVARCHAR(80), @LocaleCode NVARCHAR(10)
    , @Channel TINYINT, @Subject NVARCHAR(300) = NULL
    , @BodyTemplate NVARCHAR(MAX), @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    MERGE ops.NotificationTemplate AS tgt
    USING (SELECT @TemplateKey AS K, @LocaleCode AS L, @Channel AS C) AS src
    ON tgt.TemplateKey = src.K AND tgt.LocaleCode = src.L AND tgt.Channel = src.C
    WHEN MATCHED THEN UPDATE SET
          [Subject] = @Subject, BodyTemplate = @BodyTemplate
        , IsActive = @IsActive, ModifiedAtUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (TemplateKey, LocaleCode, Channel, [Subject], BodyTemplate, IsActive)
        VALUES (@TemplateKey, @LocaleCode, @Channel, @Subject, @BodyTemplate, @IsActive);
    RETURN 0;
END;
GO

/* =====================================================================
   Configuracion, flags, archivos, jobs
   ===================================================================== */
CREATE OR ALTER PROCEDURE ops.usp_Setting_Get
      @SettingKey NVARCHAR(100) = NULL, @ScopeType TINYINT = 1, @ScopeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* Resolucion por especificidad: departamento gana a sitio, sitio
       gana a global. Un solo query, sin logica en la aplicacion. */
    IF @SettingKey IS NOT NULL
        SELECT TOP (1) SettingKey, SettingValue, DataType, ScopeType, ScopeId
        FROM ops.Setting
        WHERE SettingKey = @SettingKey
          AND (ScopeType = 1 OR (ScopeType = @ScopeType AND ScopeId = @ScopeId))
        ORDER BY CASE WHEN ScopeType = @ScopeType AND ScopeId = @ScopeId THEN 0 ELSE 1 END;
    ELSE
        SELECT SettingKey, SettingValue, DataType, ScopeType, ScopeId, [Description]
        FROM ops.Setting WHERE IsEncrypted = 0 ORDER BY SettingKey;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_Setting_Set
      @ActorUserId INT, @SettingKey NVARCHAR(100), @SettingValue NVARCHAR(MAX)
    , @DataType NVARCHAR(20) = N'string', @ScopeType TINYINT = 1, @ScopeId INT = NULL
    , @Description NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'settings.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para modificar la configuracion.', 1;

    MERGE ops.Setting AS tgt
    USING (SELECT @SettingKey AS K, @ScopeType AS T, @ScopeId AS I) AS src
    ON tgt.SettingKey = src.K AND tgt.ScopeType = src.T
       AND ISNULL(tgt.ScopeId, -1) = ISNULL(src.I, -1)
    WHEN MATCHED THEN UPDATE SET
          SettingValue = @SettingValue, DataType = @DataType
        , [Description] = COALESCE(@Description, [Description])
        , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHEN NOT MATCHED THEN INSERT (SettingKey, ScopeType, ScopeId, SettingValue, DataType
                                , [Description], ModifiedByUserId)
        VALUES (@SettingKey, @ScopeType, @ScopeId, @SettingValue, @DataType
              , @Description, @ActorUserId);

    EXEC aud.usp_Event_Log @EventType = N'Setting.Changed', @EntityType = N'Setting'
       , @ActorUserId = @ActorUserId, @Severity = 3, @Summary = @SettingKey;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_FeatureFlag_IsEnabled
      @FlagKey NVARCHAR(80), @UserId INT = NULL, @IsEnabled BIT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Flag BIT, @AudienceType TINYINT, @AudienceValue NVARCHAR(500);

    SELECT @Flag = IsEnabled, @AudienceType = AudienceType, @AudienceValue = AudienceValue
    FROM ops.FeatureFlag WHERE FlagKey = @FlagKey;

    SET @IsEnabled = CASE
        WHEN @Flag IS NULL OR @Flag = 0 THEN 0
        WHEN @AudienceType = 1 THEN 1                     -- All
        WHEN @UserId IS NULL THEN 0
        WHEN @AudienceType = 5 THEN                       -- lista de usuarios
             CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(@AudienceValue, N',')
                               WHERE TRY_CONVERT(INT, RTRIM(LTRIM([value]))) = @UserId)
                  THEN 1 ELSE 0 END
        WHEN @AudienceType = 2 THEN                       -- por rol
             CASE WHEN EXISTS (SELECT 1 FROM sec.UserRoleAssignment ura
                               JOIN sec.Role r ON r.RoleId = ura.RoleId
                               JOIN STRING_SPLIT(@AudienceValue, N',') s
                                 ON RTRIM(LTRIM(s.[value])) = r.RoleCode
                               WHERE ura.UserId = @UserId)
                  THEN 1 ELSE 0 END
        WHEN @AudienceType = 3 THEN                       -- por departamento
             CASE WHEN EXISTS (SELECT 1 FROM sec.[User] u
                               JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
                               JOIN STRING_SPLIT(@AudienceValue, N',') s
                                 ON TRY_CONVERT(INT, RTRIM(LTRIM(s.[value]))) = e.DepartmentId
                               WHERE u.UserId = @UserId)
                  THEN 1 ELSE 0 END
        WHEN @AudienceType = 4 THEN                       -- por sitio
             CASE WHEN EXISTS (SELECT 1 FROM sec.[User] u
                               JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
                               JOIN STRING_SPLIT(@AudienceValue, N',') s
                                 ON TRY_CONVERT(INT, RTRIM(LTRIM(s.[value]))) = e.SiteId
                               WHERE u.UserId = @UserId)
                  THEN 1 ELSE 0 END
        ELSE 0 END;

    SELECT @IsEnabled AS IsEnabled;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_FileAsset_Register
      @ActorUserId INT, @FileName NVARCHAR(300), @ContentType NVARCHAR(150)
    , @SizeBytes BIGINT, @StorageProvider TINYINT, @StoragePath NVARCHAR(1000)
    , @ContentHash VARBINARY(32) = NULL
    , @OwnerEntityType NVARCHAR(60) = NULL, @OwnerEntityId INT = NULL
    , @IsPublic BIT = 0
    , @FileAssetId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    /* Deduplicacion por hash: la misma WI subida por tres personas
       distintas guarda un solo archivo. */
    IF @ContentHash IS NOT NULL
        SELECT TOP (1) @FileAssetId = FileAssetId
        FROM ops.FileAsset
        WHERE ContentHash = @ContentHash AND IsDeleted = 0
        ORDER BY FileAssetId;

    IF @FileAssetId IS NULL
    BEGIN
        INSERT INTO ops.FileAsset (FileName, ContentType, SizeBytes, StorageProvider, StoragePath
                                 , ContentHash, OwnerEntityType, OwnerEntityId, IsPublic, UploadedByUserId)
        VALUES (@FileName, @ContentType, @SizeBytes, @StorageProvider, @StoragePath
              , @ContentHash, @OwnerEntityType, @OwnerEntityId, @IsPublic, @ActorUserId);
        SET @FileAssetId = SCOPE_IDENTITY();
    END;

    SELECT @FileAssetId AS FileAssetId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_JobRun_Start
      @JobName NVARCHAR(100), @JobRunId BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO ops.JobRun (JobName, [Status]) VALUES (@JobName, 1);
    SET @JobRunId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_JobRun_Finish
      @JobRunId BIGINT, @Status TINYINT = 2
    , @RecordsProcessed INT = 0, @Message NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE ops.JobRun
    SET FinishedAtUtc = SYSUTCDATETIME(), [Status] = @Status
      , RecordsProcessed = @RecordsProcessed
      , DurationMs = DATEDIFF(MILLISECOND, StartedAtUtc, SYSUTCDATETIME())
      , Message = @Message
    WHERE JobRunId = @JobRunId;
    RETURN 0;
END;
GO

/* =====================================================================
   ops.usp_Health_GetStatus

   Lo que se pone en el tablero de IT. Si el sync de empleados lleva mas
   de 3 horas sin correr, o la cola de notificaciones esta creciendo, el
   sistema esta mintiendo aunque la pantalla se vea bien.
   ===================================================================== */
CREATE OR ALTER PROCEDURE ops.usp_Health_GetStatus @ActorUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();

    SELECT
          (SELECT COUNT(*) FROM ops.NotificationQueue WHERE [Status] = 1) AS NotificationsPending
        , (SELECT COUNT(*) FROM ops.NotificationQueue WHERE [Status] = 5) AS NotificationsDeadLetter
        , (SELECT COUNT(*) FROM intg.IntegrationError WHERE IsResolved = 0) AS OpenIntegrationErrors
        , (SELECT MAX(LastSuccessAtUtc) FROM intg.SyncWatermark
           WHERE SourceSystem = N'SPN' AND SourceEntity = N'Employee') AS LastEmployeeSyncUtc
        , (SELECT COUNT(*) FROM aud.ErrorLog WHERE OccurredAtUtc > DATEADD(HOUR, -24, @NowUtc)) AS ErrorsLast24h
        , (SELECT COUNT(*) FROM ops.JobRun
           WHERE [Status] = 4 AND StartedAtUtc > DATEADD(HOUR, -24, @NowUtc)) AS FailedJobsLast24h
        , (SELECT COUNT(*) FROM comp.CompetencyGap
           WHERE ResolvedAtUtc IS NULL AND Severity = 1 AND HasActiveWaiver = 0) AS OpenCriticalGaps
        , (SELECT COUNT(*) FROM asmt.QuizAttempt WHERE [Status] = 1) AS AttemptsInProgress;

    /* Ultimas corridas de cada job */
    SELECT j.JobName, j.[Status], j.StartedAtUtc, j.FinishedAtUtc
         , j.DurationMs, j.RecordsProcessed, j.Message
    FROM ops.JobRun j
    JOIN (SELECT JobName, MAX(JobRunId) AS LastId FROM ops.JobRun GROUP BY JobName) x
      ON x.LastId = j.JobRunId
    ORDER BY j.JobName;
    RETURN 0;
END;
GO

/* =====================================================================
   ops.usp_Retention_Apply

   Retencion diferenciada. Lo operativo se limpia; lo que sostiene una
   certificacion NO se toca nunca.

   Politicas por ops.Setting (dias):
     Retention.EventLog.Days      (default 1095 = 3 anos)
     Retention.AppLog.Days        (default 90)
     Retention.ErrorLog.Days      (default 365)
     Retention.Notification.Days  (default 180, solo enviadas)
     Retention.Staging.Days       (default 30)

   NUNCA se purga: aud.SignatureRecord, comp.Certification,
   comp.CertificationEvidence, comp.DocumentAcknowledgment,
   dlv.Enrollment, asmt.QuizAttempt*, asmt.PracticalAssessment*.
   Esos son el expediente. Se conservan 7 anos como minimo y su borrado
   se maneja como proyecto aparte, con aprobacion de Calidad.
   ===================================================================== */
CREATE OR ALTER PROCEDURE ops.usp_Retention_Apply
      @ActorUserId INT = NULL
    , @DryRun      BIT = 0
    , @BatchSize   INT = 5000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();

        DECLARE @EventDays INT   = TRY_CONVERT(INT, (SELECT TOP (1) SettingValue FROM ops.Setting
                                   WHERE SettingKey = N'Retention.EventLog.Days' AND ScopeType = 1))
              , @AppDays INT     = TRY_CONVERT(INT, (SELECT TOP (1) SettingValue FROM ops.Setting
                                   WHERE SettingKey = N'Retention.AppLog.Days' AND ScopeType = 1))
              , @ErrDays INT     = TRY_CONVERT(INT, (SELECT TOP (1) SettingValue FROM ops.Setting
                                   WHERE SettingKey = N'Retention.ErrorLog.Days' AND ScopeType = 1))
              , @NotifDays INT   = TRY_CONVERT(INT, (SELECT TOP (1) SettingValue FROM ops.Setting
                                   WHERE SettingKey = N'Retention.Notification.Days' AND ScopeType = 1))
              , @StagingDays INT = TRY_CONVERT(INT, (SELECT TOP (1) SettingValue FROM ops.Setting
                                   WHERE SettingKey = N'Retention.Staging.Days' AND ScopeType = 1));

        SET @EventDays   = ISNULL(@EventDays, 1095);
        SET @AppDays     = ISNULL(@AppDays, 90);
        SET @ErrDays     = ISNULL(@ErrDays, 365);
        SET @NotifDays   = ISNULL(@NotifDays, 180);
        SET @StagingDays = ISNULL(@StagingDays, 30);

        DECLARE @Plan TABLE ([Table] NVARCHAR(80), RowsAffected INT);

        IF @DryRun = 1
        BEGIN
            INSERT INTO @Plan
            SELECT N'aud.EventLog', COUNT(*) FROM aud.EventLog
            WHERE OccurredAtUtc < DATEADD(DAY, -@EventDays, @NowUtc) AND Severity = 1
            UNION ALL SELECT N'ops.AppLog', COUNT(*) FROM ops.AppLog
            WHERE LoggedAtUtc < DATEADD(DAY, -@AppDays, @NowUtc)
            UNION ALL SELECT N'aud.ErrorLog', COUNT(*) FROM aud.ErrorLog
            WHERE OccurredAtUtc < DATEADD(DAY, -@ErrDays, @NowUtc)
            UNION ALL SELECT N'ops.NotificationQueue', COUNT(*) FROM ops.NotificationQueue
            WHERE [Status] = 3 AND SentAtUtc < DATEADD(DAY, -@NotifDays, @NowUtc)
            UNION ALL SELECT N'intg.EmployeeStaging', COUNT(*) FROM intg.EmployeeStaging st
            JOIN intg.SyncRun r ON r.SyncRunId = st.SyncRunId
            WHERE r.StartedAtUtc < DATEADD(DAY, -@StagingDays, @NowUtc)
            UNION ALL SELECT N'aud.IdempotencyKey', COUNT(*) FROM aud.IdempotencyKey
            WHERE ExpiresAtUtc < @NowUtc;

            SELECT * FROM @Plan;
            RETURN 0;
        END;

        /* Solo eventos informativos. Severity >= 2 (Notable, Sensible,
           Critico) se conserva: ahi vive el rastro de quien hizo que. */
        DELETE TOP (@BatchSize) FROM aud.EventLog
        WHERE OccurredAtUtc < DATEADD(DAY, -@EventDays, @NowUtc) AND Severity = 1;
        INSERT INTO @Plan VALUES (N'aud.EventLog', @@ROWCOUNT);

        DELETE TOP (@BatchSize) FROM ops.AppLog
        WHERE LoggedAtUtc < DATEADD(DAY, -@AppDays, @NowUtc);
        INSERT INTO @Plan VALUES (N'ops.AppLog', @@ROWCOUNT);

        DELETE TOP (@BatchSize) FROM aud.ErrorLog
        WHERE OccurredAtUtc < DATEADD(DAY, -@ErrDays, @NowUtc);
        INSERT INTO @Plan VALUES (N'aud.ErrorLog', @@ROWCOUNT);

        DELETE TOP (@BatchSize) FROM ops.NotificationQueue
        WHERE [Status] = 3 AND SentAtUtc < DATEADD(DAY, -@NotifDays, @NowUtc);
        INSERT INTO @Plan VALUES (N'ops.NotificationQueue', @@ROWCOUNT);

        DELETE TOP (@BatchSize) st
        FROM intg.EmployeeStaging st
        JOIN intg.SyncRun r ON r.SyncRunId = st.SyncRunId
        WHERE r.StartedAtUtc < DATEADD(DAY, -@StagingDays, @NowUtc);
        INSERT INTO @Plan VALUES (N'intg.EmployeeStaging', @@ROWCOUNT);

        DELETE TOP (@BatchSize) FROM aud.IdempotencyKey WHERE ExpiresAtUtc < @NowUtc;
        INSERT INTO @Plan VALUES (N'aud.IdempotencyKey', @@ROWCOUNT);

        EXEC aud.usp_Event_Log @EventType = N'Retention.Applied', @EntityType = N'Retention'
           , @ActorUserId = @ActorUserId, @Severity = 2
           , @Summary = N'Politica de retencion aplicada.';

        SELECT * FROM @Plan;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'ops.usp_Retention_Apply', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_AppLog_Write
      @Level NVARCHAR(20), @Source NVARCHAR(150) = NULL, @Message NVARCHAR(4000)
    , @ExceptionDetail NVARCHAR(MAX) = NULL, @ActorUserId INT = NULL
    , @CorrelationId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO ops.AppLog ([Level], [Source], Message, ExceptionDetail, ActorUserId, CorrelationId)
    VALUES (@Level, @Source, @Message, @ExceptionDetail, @ActorUserId, @CorrelationId);
    RETURN 0;
END;
GO

PRINT '=== 18_procs_platform.sql completado ===';
GO

/* ############################################################################
   ARCHIVO: database/11_procs_identity.sql
   ############################################################################ */
/* =====================================================================
   Classroom - LMS by Airlink
   11_procs_identity.sql
   Esquemas: sec (identidad, sesiones, roles) y org (empleados, estructura)

   REGLA CERO: la app no toca tablas. Todo entra por aqui.

   Codigos de error de este archivo: 50001-50199
   ===================================================================== */

USE AIRLINK_KMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 11_procs_identity.sql iniciado ===';
GO

/* =====================================================================
   sec.usp_User_AuthenticatePin
   GAP-09: autenticacion de piso sin correo corporativo.

   IMPORTANTE: este SP NO valida el PIN. T-SQL no hace criptografia de
   contrasenas. La API calcula PBKDF2 y compara. Este SP:
     a) devuelve el material de hash para que la API compare, y
     b) registra el intento y aplica el bloqueo.
   El flujo real es de dos pasos:
     1. EXEC sec.usp_User_AuthenticatePin @Phase = 1  -> devuelve hash/salt
     2. La API compara -> EXEC sec.usp_User_AuthenticatePin @Phase = 2
        con @IsMatch para registrar exito/fallo y crear la sesion.
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_User_AuthenticatePin
      @EmployeeCode   NVARCHAR(100)
    , @Phase          TINYINT          = 1        -- 1=GetMaterial 2=RecordResult
    , @IsMatch        BIT              = NULL     -- requerido en fase 2
    , @DeviceId       INT              = NULL
    , @IpAddress      NVARCHAR(45)     = NULL
    , @UserId         INT              = NULL OUTPUT
    , @IsAuthenticated BIT             = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------
       Proposito : autenticar operador por codigo de empleado + PIN.
       Retorna   : fase 1 -> PinHash, PinSalt, Iterations, Algorithm
                   fase 2 -> UserId, DisplayName, permisos, sesion
       Errores   : 50101 usuario no existe / inactivo
                   50102 cuenta bloqueada
                   50103 device no autorizado
                   50104 PIN vencido / debe cambiarse
       --------------------------------------------------------------- */

    BEGIN TRY
        DECLARE @MaxFailed        TINYINT = 5
              , @LockMinutes      INT     = 15
              , @NowUtc           DATETIME2(3) = SYSUTCDATETIME()
              , @LockedUntilUtc   DATETIME2(3)
              , @FailedCount      TINYINT
              , @IsActive         BIT
              , @PinExpiresAtUtc  DATETIME2(3)
              , @MustChange       BIT;

        SET @IsAuthenticated = 0;

        /* El login de piso es SIEMPRE por codigo de empleado, aunque el
           UserName sea un UPN (usuarios con Entra ademas del PIN). */
        SELECT  @UserId          = u.UserId
              , @IsActive        = u.IsActive
              , @FailedCount     = c.FailedAttemptCount
              , @LockedUntilUtc  = c.LockedUntilUtc
              , @PinExpiresAtUtc = c.ExpiresAtUtc
              , @MustChange      = c.MustChangeOnNextLogin
        FROM sec.[User] u
        LEFT JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
        LEFT JOIN sec.UserCredential c ON c.UserId = u.UserId
        WHERE (u.UserName = @EmployeeCode OR e.EmployeeCode = @EmployeeCode)
          AND u.IsDeleted = 0
          AND u.AuthMethod IN (2, 3);

        /* Usuario inexistente: se registra el intento pero el mensaje al
           cliente es generico. No confirmamos si el codigo existe. */
        IF @UserId IS NULL
        BEGIN
            INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, FailureReason, IpAddress)
            VALUES (@EmployeeCode, NULL, @DeviceId, 0, 1, @IpAddress);
            THROW 50101, 'Codigo o PIN incorrecto.', 1;
        END;

        IF @IsActive = 0
        BEGIN
            INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, FailureReason, IpAddress)
            VALUES (@EmployeeCode, @UserId, @DeviceId, 0, 4, @IpAddress);
            THROW 50101, 'Codigo o PIN incorrecto.', 1;
        END;

        IF @LockedUntilUtc IS NOT NULL AND @LockedUntilUtc > @NowUtc
        BEGIN
            INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, FailureReason, IpAddress)
            VALUES (@EmployeeCode, @UserId, @DeviceId, 0, 3, @IpAddress);
            THROW 50102, 'Cuenta bloqueada temporalmente. Contacte a su supervisor.', 1;
        END;

        /* El kiosko exige DeviceToken valido. Sin device registrado no se
           autentica por PIN, aunque el PIN sea correcto. */
        IF @DeviceId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM sec.DeviceRegistration d
                           WHERE d.DeviceId = @DeviceId AND d.IsActive = 1 AND d.RevokedAtUtc IS NULL)
        BEGIN
            INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, FailureReason, IpAddress)
            VALUES (@EmployeeCode, @UserId, @DeviceId, 0, 5, @IpAddress);
            THROW 50103, 'Terminal no autorizada.', 1;
        END;

        /* ---------- FASE 1: entregar material de hash ---------- */
        IF @Phase = 1
        BEGIN
            SELECT  c.PinHash
                  , c.PinSalt
                  , c.Iterations
                  , c.Algorithm
                  , @UserId AS UserId
            FROM sec.UserCredential c
            WHERE c.UserId = @UserId;
            RETURN 0;
        END;

        /* ---------- FASE 2: registrar resultado ---------- */
        IF @IsMatch IS NULL
            THROW 50010, 'IsMatch es requerido en fase 2.', 1;

        BEGIN TRANSACTION;

        IF @IsMatch = 0
        BEGIN
            UPDATE sec.UserCredential
            SET  FailedAttemptCount = FailedAttemptCount + 1
               , LockedUntilUtc = CASE WHEN FailedAttemptCount + 1 >= @MaxFailed
                                       THEN DATEADD(MINUTE, @LockMinutes, @NowUtc)
                                       ELSE LockedUntilUtc END
            WHERE UserId = @UserId;

            INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, FailureReason, IpAddress)
            VALUES (@EmployeeCode, @UserId, @DeviceId, 0, 2, @IpAddress);

            COMMIT TRANSACTION;
            THROW 50101, 'Codigo o PIN incorrecto.', 1;
        END;

        /* PIN correcto */
        UPDATE sec.UserCredential
        SET FailedAttemptCount = 0, LockedUntilUtc = NULL
        WHERE UserId = @UserId;

        UPDATE sec.[User] SET LastLoginAtUtc = @NowUtc WHERE UserId = @UserId;

        INSERT INTO sec.LoginAttempt (UserName, UserId, DeviceId, IsSuccess, IpAddress)
        VALUES (@EmployeeCode, @UserId, @DeviceId, 1, @IpAddress);

        COMMIT TRANSACTION;

        SET @IsAuthenticated = 1;

        SELECT  u.UserId
              , u.PublicId
              , u.EmployeeId
              , u.DisplayName
              , u.PreferredLocale
              , @MustChange      AS MustChangePin
              , CASE WHEN @PinExpiresAtUtc IS NOT NULL AND @PinExpiresAtUtc <= @NowUtc
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsPinExpired
        FROM sec.[User] u
        WHERE u.UserId = @UserId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_AuthenticatePin';
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   sec.usp_User_GetPermissions
   Devuelve permisos efectivos con su alcance. La API lo cachea 5 min.
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_User_GetPermissions
      @UserId INT
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SELECT DISTINCT
                p.PermissionCode
              , p.Domain
              , ura.ScopeType
              , ura.ScopeId
        FROM sec.UserRoleAssignment ura
        JOIN sec.RolePermission rp ON rp.RoleId = ura.RoleId
        JOIN sec.Permission     p  ON p.PermissionId = rp.PermissionId
        WHERE ura.UserId = @UserId
          AND ura.IsActive = 1
          AND ura.RevokedAtUtc IS NULL
        ORDER BY p.Domain, p.PermissionCode;

        /* Segundo resultset: contexto organizacional del usuario, para que
           la API resuelva "mi departamento" sin otra llamada. */
        SELECT  u.UserId
              , u.EmployeeId
              , e.SiteId
              , e.DepartmentId
              , e.AreaId
              , e.SupervisorEmployeeId
        FROM sec.[User] u
        LEFT JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
        WHERE u.UserId = @UserId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_GetPermissions', @ActorUserId = @UserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   sec.usp_Session_Create / Validate / Revoke
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_Session_Create
      @UserId         INT
    , @SessionType    TINYINT       = 1
    , @DeviceId       INT           = NULL
    , @IpAddress      NVARCHAR(45)  = NULL
    , @UserAgent      NVARCHAR(400) = NULL
    , @TtlMinutes     INT           = 480
    , @SessionId      UNIQUEIDENTIFIER = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Kiosko: TTL corto por seguridad de piso (turno compartido). */
    BEGIN TRY
        IF @SessionType = 2 AND @TtlMinutes > 60 SET @TtlMinutes = 60;

        SET @SessionId = NEWID();

        INSERT INTO sec.UserSession (SessionId, UserId, DeviceId, SessionType, IpAddress, UserAgent, ExpiresAtUtc)
        VALUES (@SessionId, @UserId, @DeviceId, @SessionType, @IpAddress, @UserAgent,
                DATEADD(MINUTE, @TtlMinutes, SYSUTCDATETIME()));

        IF @DeviceId IS NOT NULL
            UPDATE sec.DeviceRegistration
            SET LastSeenAtUtc = SYSUTCDATETIME(), LastIpAddress = @IpAddress
            WHERE DeviceId = @DeviceId;

        SELECT @SessionId AS SessionId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_Session_Create', @ActorUserId = @UserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Session_Validate
      @SessionId UNIQUEIDENTIFIER
    , @SlideExpiration BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();

        IF @SlideExpiration = 1
            UPDATE sec.UserSession
            SET LastSeenAtUtc = @NowUtc
            WHERE SessionId = @SessionId AND EndedAtUtc IS NULL AND ExpiresAtUtc > @NowUtc;

        SELECT  s.SessionId
              , s.UserId
              , s.DeviceId
              , s.SessionType
              , s.ExpiresAtUtc
              , u.DisplayName
              , u.EmployeeId
              , u.PreferredLocale
              , CASE WHEN s.EndedAtUtc IS NULL AND s.ExpiresAtUtc > @NowUtc AND u.IsActive = 1
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsValid
        FROM sec.UserSession s
        JOIN sec.[User] u ON u.UserId = s.UserId
        WHERE s.SessionId = @SessionId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_Session_Validate';
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Session_Revoke
      @SessionId UNIQUEIDENTIFIER
    , @EndReason TINYINT = 3
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE sec.UserSession
    SET EndedAtUtc = SYSUTCDATETIME(), EndReason = @EndReason
    WHERE SessionId = @SessionId AND EndedAtUtc IS NULL;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Session_RevokeAllForUser
      @ActorUserId INT
    , @UserId      INT
    , @EndReason   TINYINT = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0 AND @ActorUserId <> @UserId
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        UPDATE sec.UserSession
        SET EndedAtUtc = SYSUTCDATETIME(), EndReason = @EndReason
        WHERE UserId = @UserId AND EndedAtUtc IS NULL;

        EXEC aud.usp_Event_Log
              @EventType    = N'Session.RevokedAll'
            , @EntityType   = N'User'
            , @EntityId     = @UserId
            , @ActorUserId  = @ActorUserId
            , @Summary      = N'Todas las sesiones del usuario fueron revocadas.';

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_Session_RevokeAllForUser', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   sec.usp_User_SetPin
   La API pasa hash + salt ya calculados. Este SP nunca ve el PIN.
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_User_SetPin
      @ActorUserId    INT
    , @UserId         INT
    , @PinHash        VARBINARY(64)
    , @PinSalt        VARBINARY(32)
    , @Iterations     INT           = 210000
    , @Algorithm      NVARCHAR(40)  = N'PBKDF2-HMACSHA256'
    , @MustChange     BIT           = 0
    , @ExpiresInDays  INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF @ActorUserId <> @UserId
           AND sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF DATALENGTH(@PinHash) = 0 OR DATALENGTH(@PinSalt) = 0
            THROW 50010, 'PinHash y PinSalt son requeridos.', 1;

        BEGIN TRANSACTION;

        MERGE sec.UserCredential AS tgt
        USING (SELECT @UserId AS UserId) AS src ON tgt.UserId = src.UserId
        WHEN MATCHED THEN UPDATE SET
              PinHash = @PinHash, PinSalt = @PinSalt
            , Iterations = @Iterations, Algorithm = @Algorithm
            , MustChangeOnNextLogin = @MustChange
            , ExpiresAtUtc = CASE WHEN @ExpiresInDays IS NULL THEN NULL
                                  ELSE DATEADD(DAY, @ExpiresInDays, SYSUTCDATETIME()) END
            , FailedAttemptCount = 0, LockedUntilUtc = NULL
            , LastChangedAtUtc = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT
              (UserId, PinHash, PinSalt, Iterations, Algorithm, MustChangeOnNextLogin, ExpiresAtUtc)
            VALUES (@UserId, @PinHash, @PinSalt, @Iterations, @Algorithm, @MustChange,
                    CASE WHEN @ExpiresInDays IS NULL THEN NULL
                         ELSE DATEADD(DAY, @ExpiresInDays, SYSUTCDATETIME()) END);

        /* Cambiar el PIN cierra las sesiones abiertas. */
        UPDATE sec.UserSession
        SET EndedAtUtc = SYSUTCDATETIME(), EndReason = 3
        WHERE UserId = @UserId AND EndedAtUtc IS NULL;

        EXEC aud.usp_Event_Log
              @EventType   = N'User.PinChanged'
            , @EntityType  = N'User'
            , @EntityId    = @UserId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'PIN de acceso actualizado.';

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_SetPin', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   sec.usp_UserRole_Assign / Revoke
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_UserRole_Assign
      @ActorUserId INT
    , @UserId      INT
    , @RoleId      INT
    , @ScopeType   TINYINT = 1
    , @ScopeId     INT     = NULL
    , @UserRoleAssignmentId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50110 rol no existe, 50111 asignacion duplicada,
                50112 violacion de segregacion de funciones (SoD)        */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'role.assign') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF NOT EXISTS (SELECT 1 FROM sec.Role WHERE RoleId = @RoleId AND IsActive = 1)
            THROW 50110, 'El rol indicado no existe o esta inactivo.', 1;

        IF EXISTS (SELECT 1 FROM sec.UserRoleAssignment
                   WHERE UserId = @UserId AND RoleId = @RoleId
                     AND ISNULL(ScopeType,0) = ISNULL(@ScopeType,0)
                     AND ISNULL(ScopeId,-1)  = ISNULL(@ScopeId,-1)
                     AND IsActive = 1)
            THROW 50111, 'El usuario ya tiene ese rol en ese alcance.', 1;

        /* SoD: quien aprueba contenido no puede ser quien lo autoriza a
           produccion. Ver doc 06 seccion 5. */
        IF EXISTS (
            SELECT 1
            FROM sec.UserRoleAssignment ura
            JOIN sec.Role r ON r.RoleId = ura.RoleId
            WHERE ura.UserId = @UserId AND ura.IsActive = 1
              AND (
                    (r.RoleCode = N'CONTENT_AUTHOR'  AND @RoleId IN (SELECT RoleId FROM sec.Role WHERE RoleCode = N'QUALITY_APPROVER'))
                 OR (r.RoleCode = N'QUALITY_APPROVER' AND @RoleId IN (SELECT RoleId FROM sec.Role WHERE RoleCode = N'CONTENT_AUTHOR'))
              )
        )
            THROW 50112, 'Conflicto de segregacion de funciones: autor de contenido y aprobador de calidad no pueden ser la misma persona.', 1;

        BEGIN TRANSACTION;

        INSERT INTO sec.UserRoleAssignment (UserId, RoleId, ScopeType, ScopeId, AssignedByUserId)
        VALUES (@UserId, @RoleId, @ScopeType, @ScopeId, @ActorUserId);

        SET @UserRoleAssignmentId = SCOPE_IDENTITY();

        EXEC aud.usp_Event_Log
              @EventType   = N'UserRole.Assigned'
            , @EntityType  = N'User'
            , @EntityId    = @UserId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Rol asignado al usuario.';

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_UserRole_Assign', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_UserRole_Revoke
      @ActorUserId INT
    , @UserRoleAssignmentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'role.assign') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        UPDATE sec.UserRoleAssignment
        SET IsActive = 0, RevokedAtUtc = SYSUTCDATETIME(), RevokedByUserId = @ActorUserId
        WHERE UserRoleAssignmentId = @UserRoleAssignmentId AND IsActive = 1;

        IF @@ROWCOUNT = 0 THROW 50001, 'Asignacion de rol no encontrada o ya revocada.', 1;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_UserRole_Revoke', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   org.usp_Employee_Get
   ===================================================================== */
CREATE OR ALTER PROCEDURE org.usp_Employee_Get
      @ActorUserId  INT
    , @EmployeeId   INT = NULL
    , @EmployeeCode NVARCHAR(30) = NULL
    , @PublicId     UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF @EmployeeId IS NULL AND @EmployeeCode IS NULL AND @PublicId IS NULL
            THROW 50010, 'Debe indicar EmployeeId, EmployeeCode o PublicId.', 1;

        SELECT @EmployeeId = COALESCE(@EmployeeId, e.EmployeeId)
        FROM org.Employee e
        WHERE (@EmployeeCode IS NOT NULL AND e.EmployeeCode = @EmployeeCode)
           OR (@PublicId     IS NOT NULL AND e.PublicId     = @PublicId);

        IF @EmployeeId IS NULL THROW 50120, 'Empleado no encontrado.', 1;

        /* Un supervisor solo ve su equipo; RH y Calidad ven todo. */
        IF sec.fn_UserHasPermission(@ActorUserId, N'employee.read.all') = 0
           AND NOT EXISTS (
                SELECT 1 FROM sec.[User] u
                CROSS APPLY org.fn_GetTeamEmployeeIds(u.EmployeeId, 1) t
                WHERE u.UserId = @ActorUserId AND t.EmployeeId = @EmployeeId)
           AND NOT EXISTS (SELECT 1 FROM sec.[User] u WHERE u.UserId = @ActorUserId AND u.EmployeeId = @EmployeeId)
            THROW 50002, 'El usuario no tiene permiso para ver este empleado.', 1;

        SELECT  e.EmployeeId, e.PublicId, e.EmployeeCode
              , e.FirstName, e.LastName, e.FullName
              , e.Email, e.SiteId, e.DepartmentId, e.AreaId
              , e.SupervisorEmployeeId, e.HireDateUtc, e.TerminationDateUtc
              , e.EmploymentType, e.IsActive
              , s.[Name]  AS SiteName
              , d.[Name]  AS DepartmentName
              , a.[Name]  AS AreaName
        FROM org.Employee e
        LEFT JOIN org.Site       s ON s.SiteId       = e.SiteId
        LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
        LEFT JOIN org.Area       a ON a.AreaId       = e.AreaId
        WHERE e.EmployeeId = @EmployeeId;

        /* Posiciones vigentes */
        SELECT  ep.EmployeePositionId, ep.PositionId, p.PositionCode, p.[Name] AS PositionName
              , ep.IsPrimary, ep.EffectiveFromUtc, ep.EffectiveToUtc
        FROM org.EmployeePosition ep
        JOIN org.[Position] p ON p.PositionId = ep.PositionId
        WHERE ep.EmployeeId = @EmployeeId AND ep.EffectiveToUtc IS NULL
        ORDER BY ep.IsPrimary DESC, p.[Name];

        EXEC aud.usp_DataAccess_Log
              @ActorUserId = @ActorUserId
            , @AccessType  = 1
            , @EntityType  = N'Employee'
            , @SubjectEmployeeId = @EmployeeId
            , @RecordCount = 1;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_Employee_Get', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   org.usp_Employee_List  -- listado paginado con filtros opcionales
   ===================================================================== */
CREATE OR ALTER PROCEDURE org.usp_Employee_List
      @ActorUserId   INT
    , @SearchText    NVARCHAR(100) = NULL
    , @SiteId        INT           = NULL
    , @DepartmentId  INT           = NULL
    , @AreaId        INT           = NULL
    , @PositionId    INT           = NULL
    , @SupervisorEmployeeId INT    = NULL
    , @IsActive      BIT           = 1
    , @PageNumber    INT           = 1
    , @PageSize      INT           = 50
    , @SortBy        NVARCHAR(50)  = N'FullName'
    , @SortDir       CHAR(4)       = 'ASC'
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF @PageSize  > 200 SET @PageSize  = 200;
        IF @PageSize  < 1   SET @PageSize  = 50;
        IF @PageNumber < 1  SET @PageNumber = 1;
        IF @SortDir NOT IN ('ASC','DESC') SET @SortDir = 'ASC';

        /* Whitelist de ordenamiento. Nada de concatenar el @SortBy. */
        IF @SortBy NOT IN (N'FullName', N'EmployeeCode', N'HireDateUtc', N'DepartmentName')
            SET @SortBy = N'FullName';

        DECLARE @ActorEmployeeId INT
              , @SeeAll BIT = sec.fn_UserHasPermission(@ActorUserId, N'employee.read.all');

        SELECT @ActorEmployeeId = EmployeeId FROM sec.[User] WHERE UserId = @ActorUserId;

        ;WITH Filtered AS (
            SELECT  e.EmployeeId, e.PublicId, e.EmployeeCode, e.FullName
                  , e.Email, e.SiteId, e.DepartmentId, e.AreaId
                  , e.SupervisorEmployeeId, e.HireDateUtc, e.IsActive
                  , d.[Name] AS DepartmentName
                  , a.[Name] AS AreaName
            FROM org.Employee e
            LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
            LEFT JOIN org.Area       a ON a.AreaId       = e.AreaId
            WHERE (@IsActive     IS NULL OR e.IsActive     = @IsActive)
              AND (@SiteId       IS NULL OR e.SiteId       = @SiteId)
              AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
              AND (@AreaId       IS NULL OR e.AreaId       = @AreaId)
              AND (@SupervisorEmployeeId IS NULL OR e.SupervisorEmployeeId = @SupervisorEmployeeId)
              AND (@SearchText   IS NULL OR e.FullName LIKE N'%' + @SearchText + N'%'
                                         OR e.EmployeeCode LIKE @SearchText + N'%')
              AND (@PositionId   IS NULL OR EXISTS (
                        SELECT 1 FROM org.EmployeePosition ep
                        WHERE ep.EmployeeId = e.EmployeeId AND ep.PositionId = @PositionId
                          AND ep.EffectiveToUtc IS NULL))
              AND (@SeeAll = 1
                   OR e.EmployeeId = @ActorEmployeeId
                   OR EXISTS (SELECT 1 FROM org.fn_GetTeamEmployeeIds(@ActorEmployeeId, 1) t
                              WHERE t.EmployeeId = e.EmployeeId))
        )
        SELECT *
        FROM Filtered
        ORDER BY
              CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'FullName'       THEN FullName       END ASC
            , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'FullName'       THEN FullName       END DESC
            , CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'EmployeeCode'   THEN EmployeeCode   END ASC
            , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'EmployeeCode'   THEN EmployeeCode   END DESC
            , CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'HireDateUtc'    THEN HireDateUtc    END ASC
            , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'HireDateUtc'    THEN HireDateUtc    END DESC
            , CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'DepartmentName' THEN DepartmentName END ASC
            , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'DepartmentName' THEN DepartmentName END DESC
            , EmployeeId
        OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
        OPTION (RECOMPILE);

        /* Segundo resultset: total */
        SELECT COUNT(*) AS TotalCount
        FROM org.Employee e
        WHERE (@IsActive     IS NULL OR e.IsActive     = @IsActive)
          AND (@SiteId       IS NULL OR e.SiteId       = @SiteId)
          AND (@DepartmentId IS NULL OR e.DepartmentId = @DepartmentId)
          AND (@AreaId       IS NULL OR e.AreaId       = @AreaId)
          AND (@SupervisorEmployeeId IS NULL OR e.SupervisorEmployeeId = @SupervisorEmployeeId)
          AND (@SearchText   IS NULL OR e.FullName LIKE N'%' + @SearchText + N'%'
                                     OR e.EmployeeCode LIKE @SearchText + N'%')
          AND (@SeeAll = 1
               OR e.EmployeeId = @ActorEmployeeId
               OR EXISTS (SELECT 1 FROM org.fn_GetTeamEmployeeIds(@ActorEmployeeId, 1) t
                          WHERE t.EmployeeId = e.EmployeeId))
        OPTION (RECOMPILE);

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_Employee_List', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   org.usp_EmployeePosition_Assign
   Cambiar de posicion dispara recalculo de gaps: el requisito nuevo
   aplica de inmediato. Por eso llama a comp.usp_Gap_RecalculateForEmployee.
   ===================================================================== */
CREATE OR ALTER PROCEDURE org.usp_EmployeePosition_Assign
      @ActorUserId  INT
    , @EmployeeId   INT
    , @PositionId   INT
    , @IsPrimary    BIT = 1
    , @EffectiveFromUtc DATETIME2(3) = NULL
    , @EmployeePositionId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'employee.position.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        SET @EffectiveFromUtc = ISNULL(@EffectiveFromUtc, SYSUTCDATETIME());

        BEGIN TRANSACTION;

        /* Si es primaria, cerrar la primaria anterior. */
        IF @IsPrimary = 1
            UPDATE org.EmployeePosition
            SET EffectiveToUtc = @EffectiveFromUtc
            WHERE EmployeeId = @EmployeeId AND IsPrimary = 1 AND EffectiveToUtc IS NULL;

        INSERT INTO org.EmployeePosition (EmployeeId, PositionId, IsPrimary, EffectiveFromUtc, AssignedByUserId)
        VALUES (@EmployeeId, @PositionId, @IsPrimary, @EffectiveFromUtc, @ActorUserId);

        /* Espejo denormalizado en org.Employee para joins baratos. */
        IF @IsPrimary = 1
            UPDATE org.Employee
            SET PrimaryPositionId = @PositionId, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
            WHERE EmployeeId = @EmployeeId;

        SET @EmployeePositionId = SCOPE_IDENTITY();

        EXEC aud.usp_Event_Log
              @EventType   = N'EmployeePosition.Assigned'
            , @EntityType  = N'Employee'
            , @EntityId    = @EmployeeId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Posicion asignada al empleado.';

        COMMIT TRANSACTION;

        /* Fuera de la transaccion: el recalculo puede ser pesado y no
           debe alargar el lock sobre EmployeePosition. */
        EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_EmployeePosition_Assign', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Resto del esquema sec/org: contratos declarados.
   Implementacion en Fase 1 semana 2-3. Se dejan como CREATE para que el
   deploy no falle y la capa Infrastructure pueda compilar contra ellos.
   ===================================================================== */

CREATE OR ALTER PROCEDURE sec.usp_User_Create
      @ActorUserId INT, @EmployeeId INT = NULL, @UserName NVARCHAR(100)
    , @DisplayName NVARCHAR(200), @Email NVARCHAR(256) = NULL
    , @ExternalObjectId NVARCHAR(100) = NULL, @AuthMethod TINYINT = 1
    , @PreferredLocale NVARCHAR(10) = N'es-DO'
    , @UserId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50105 UserName duplicado, 50106 empleado ya tiene usuario */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF EXISTS (SELECT 1 FROM sec.[User] WHERE UserName = @UserName AND IsDeleted = 0)
            THROW 50105, 'Ya existe un usuario con ese nombre de usuario.', 1;
        IF @EmployeeId IS NOT NULL AND EXISTS (SELECT 1 FROM sec.[User] WHERE EmployeeId = @EmployeeId AND IsDeleted = 0)
            THROW 50106, 'El empleado ya tiene un usuario asociado.', 1;

        INSERT INTO sec.[User] (EmployeeId, UserName, DisplayName, Email, ExternalObjectId, AuthMethod, PreferredLocale, CreatedByUserId)
        VALUES (@EmployeeId, @UserName, @DisplayName, @Email, @ExternalObjectId, @AuthMethod, @PreferredLocale, @ActorUserId);
        SET @UserId = SCOPE_IDENTITY();

        EXEC aud.usp_Event_Log @EventType = N'User.Created', @EntityType = N'User'
           , @EntityId = @UserId, @ActorUserId = @ActorUserId, @Severity = 2
           , @Summary = N'Usuario creado.';
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_User_GetByExternalId
      @ExternalObjectId NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.UserId, u.PublicId, u.EmployeeId, u.UserName, u.DisplayName, u.Email
         , u.PreferredLocale, u.TimeZoneId, u.IsActive
    FROM sec.[User] u
    WHERE u.ExternalObjectId = @ExternalObjectId AND u.IsDeleted = 0;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_User_GetByEmployeeCode
      @EmployeeCode NVARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT u.UserId, u.PublicId, u.EmployeeId, u.UserName, u.DisplayName
         , u.PreferredLocale, u.AuthMethod, u.IsActive
    FROM sec.[User] u
    JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
    WHERE e.EmployeeCode = @EmployeeCode AND u.IsDeleted = 0;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_User_Update
      @ActorUserId INT, @UserId INT
    , @DisplayName NVARCHAR(200) = NULL, @Email NVARCHAR(256) = NULL
    , @PreferredLocale NVARCHAR(10) = NULL, @AuthMethod TINYINT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF @ActorUserId <> @UserId AND sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        UPDATE sec.[User]
        SET  DisplayName     = ISNULL(@DisplayName, DisplayName)
           , Email           = ISNULL(@Email, Email)
           , PreferredLocale = ISNULL(@PreferredLocale, PreferredLocale)
           , AuthMethod      = ISNULL(@AuthMethod, AuthMethod)
           , ModifiedAtUtc   = SYSUTCDATETIME()
           , ModifiedByUserId = @ActorUserId
        WHERE UserId = @UserId AND IsDeleted = 0;
        IF @@ROWCOUNT = 0 THROW 50001, 'Usuario no encontrado.', 1;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_Update', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_User_Deactivate
      @ActorUserId INT, @UserId INT, @Reason NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        BEGIN TRANSACTION;
        UPDATE sec.[User] SET IsActive = 0, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE UserId = @UserId;
        UPDATE sec.UserSession SET EndedAtUtc = SYSUTCDATETIME(), EndReason = 3
        WHERE UserId = @UserId AND EndedAtUtc IS NULL;
        UPDATE sec.UserRoleAssignment SET IsActive = 0, RevokedAtUtc = SYSUTCDATETIME(), RevokedByUserId = @ActorUserId
        WHERE UserId = @UserId AND IsActive = 1;
        EXEC aud.usp_Event_Log @EventType = N'User.Deactivated', @EntityType = N'User'
           , @EntityId = @UserId, @ActorUserId = @ActorUserId, @Severity = 3, @Summary = N'Usuario desactivado.';
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_Deactivate', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_User_List
      @ActorUserId INT, @SearchText NVARCHAR(100) = NULL, @RoleId INT = NULL
    , @IsActive BIT = 1, @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    IF sec.fn_UserHasPermission(@ActorUserId, N'user.read') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

    SELECT u.UserId, u.PublicId, u.UserName, u.DisplayName, u.Email
         , u.EmployeeId, u.AuthMethod, u.IsActive, u.LastLoginAtUtc
    FROM sec.[User] u
    WHERE u.IsDeleted = 0
      AND (@IsActive IS NULL OR u.IsActive = @IsActive)
      AND (@SearchText IS NULL OR u.DisplayName LIKE N'%' + @SearchText + N'%' OR u.UserName LIKE @SearchText + N'%')
      AND (@RoleId IS NULL OR EXISTS (SELECT 1 FROM sec.UserRoleAssignment ura
                                      WHERE ura.UserId = u.UserId AND ura.RoleId = @RoleId AND ura.IsActive = 1))
    ORDER BY u.DisplayName
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    SELECT COUNT(*) AS TotalCount FROM sec.[User] u
    WHERE u.IsDeleted = 0 AND (@IsActive IS NULL OR u.IsActive = @IsActive)
      AND (@SearchText IS NULL OR u.DisplayName LIKE N'%' + @SearchText + N'%' OR u.UserName LIKE @SearchText + N'%')
      AND (@RoleId IS NULL OR EXISTS (SELECT 1 FROM sec.UserRoleAssignment ura
                                      WHERE ura.UserId = u.UserId AND ura.RoleId = @RoleId AND ura.IsActive = 1))
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Role_Create
      @ActorUserId INT, @RoleCode NVARCHAR(50)
    , @DisplayNameEs NVARCHAR(100), @DisplayNameEn NVARCHAR(100)
    , @Description NVARCHAR(400) = NULL, @RoleId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'role.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO sec.Role (RoleCode, DisplayNameEs, DisplayNameEn, [Description], IsSystem, CreatedByUserId)
    VALUES (@RoleCode, @DisplayNameEs, @DisplayNameEn, @Description, 0, @ActorUserId);
    SET @RoleId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

/* Recibe el set completo de permisos via TVP. Reemplaza, no acumula. */
CREATE OR ALTER PROCEDURE sec.usp_Role_SetPermissions
      @ActorUserId INT, @RoleId INT, @PermissionIds ops.IntListType READONLY
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'role.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF EXISTS (SELECT 1 FROM sec.Role WHERE RoleId = @RoleId AND IsSystem = 1)
            THROW 50113, 'No se pueden modificar los permisos de un rol de sistema.', 1;

        BEGIN TRANSACTION;
        DELETE rp FROM sec.RolePermission rp
        WHERE rp.RoleId = @RoleId AND rp.PermissionId NOT IN (SELECT [Value] FROM @PermissionIds);

        INSERT INTO sec.RolePermission (RoleId, PermissionId)
        SELECT @RoleId, p.[Value] FROM @PermissionIds p
        WHERE NOT EXISTS (SELECT 1 FROM sec.RolePermission rp WHERE rp.RoleId = @RoleId AND rp.PermissionId = p.[Value]);

        EXEC aud.usp_Event_Log @EventType = N'Role.PermissionsChanged', @EntityType = N'Role'
           , @EntityId = @RoleId, @ActorUserId = @ActorUserId, @Severity = 3
           , @Summary = N'Permisos del rol actualizados.';
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_Role_SetPermissions', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Device_Register
      @ActorUserId INT, @DeviceName NVARCHAR(100), @DeviceTokenHash VARBINARY(64)
    , @SiteId INT = NULL, @DepartmentId INT = NULL, @AreaId INT = NULL, @StationId INT = NULL
    , @DeviceId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'device.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO sec.DeviceRegistration (DeviceName, DeviceTokenHash, SiteId, DepartmentId, AreaId, StationId, RegisteredByUserId)
    VALUES (@DeviceName, @DeviceTokenHash, @SiteId, @DepartmentId, @AreaId, @StationId, @ActorUserId);
    SET @DeviceId = SCOPE_IDENTITY();
    EXEC aud.usp_Event_Log @EventType = N'Device.Registered', @EntityType = N'Device'
       , @EntityId = @DeviceId, @ActorUserId = @ActorUserId, @Severity = 2, @Summary = N'Terminal registrada.';
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Device_Validate
      @DeviceName NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    /* La API compara el hash del token. Aqui solo devolvemos el material. */
    SELECT d.DeviceId, d.PublicId, d.DeviceTokenHash, d.SiteId, d.DepartmentId
         , d.AreaId, d.StationId, d.IsKiosk, d.IsActive
    FROM sec.DeviceRegistration d
    WHERE d.DeviceName = @DeviceName AND d.IsActive = 1 AND d.RevokedAtUtc IS NULL;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE sec.usp_Device_List
      @ActorUserId INT, @SiteId INT = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'device.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    SELECT d.DeviceId, d.PublicId, d.DeviceName, d.SiteId, d.DepartmentId, d.AreaId
         , d.StationId, d.IsKiosk, d.IsActive, d.LastSeenAtUtc, d.LastIpAddress
    FROM sec.DeviceRegistration d
    WHERE (@SiteId IS NULL OR d.SiteId = @SiteId)
      AND (@IsActive IS NULL OR d.IsActive = @IsActive)
    ORDER BY d.DeviceName
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Employee_GetPositions
      @ActorUserId INT, @EmployeeId INT, @IncludeHistory BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ep.EmployeePositionId, ep.PositionId, p.PositionCode, p.[Name] AS PositionName
         , ep.IsPrimary, ep.EffectiveFromUtc, ep.EffectiveToUtc
    FROM org.EmployeePosition ep
    JOIN org.[Position] p ON p.PositionId = ep.PositionId
    WHERE ep.EmployeeId = @EmployeeId
      AND (@IncludeHistory = 1 OR ep.EffectiveToUtc IS NULL)
    ORDER BY ep.EffectiveFromUtc DESC
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Employee_GetTeam
      @ActorUserId INT, @SupervisorEmployeeId INT, @IncludeIndirect BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT e.EmployeeId, e.EmployeeCode, e.FullName, e.DepartmentId, e.AreaId
         , e.IsActive, t.[Level] AS DepthLevel
    FROM org.fn_GetTeamEmployeeIds(@SupervisorEmployeeId, @IncludeIndirect) t
    JOIN org.Employee e ON e.EmployeeId = t.EmployeeId
    ORDER BY t.[Level], e.FullName
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_EmployeePosition_End
      @ActorUserId INT, @EmployeePositionId INT, @EffectiveToUtc DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'employee.position.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        DECLARE @EmployeeId INT;
        SELECT @EmployeeId = EmployeeId FROM org.EmployeePosition WHERE EmployeePositionId = @EmployeePositionId;
        IF @EmployeeId IS NULL THROW 50001, 'Asignacion de posicion no encontrada.', 1;

        UPDATE org.EmployeePosition
        SET EffectiveToUtc = ISNULL(@EffectiveToUtc, SYSUTCDATETIME())
        WHERE EmployeePositionId = @EmployeePositionId AND EffectiveToUtc IS NULL;

        EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_EmployeePosition_End', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Position_Create
      @ActorUserId INT, @PositionCode NVARCHAR(40), @Name NVARCHAR(150)
    , @NameEn NVARCHAR(150) = NULL, @JobFamily NVARCHAR(80) = NULL
    , @Description NVARCHAR(1000) = NULL
    , @AffectsProductQuality BIT = 0
    , @PositionId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'org.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    /* AffectsProductQuality = 1 marca la posicion como sujeta a ISO 9001
       cl.7.2. Calidad revisa este flag en la matriz de competencias. */
    INSERT INTO org.[Position] (PositionCode, [Name], NameEn, JobFamily, [Description]
                              , AffectsProductQuality, IsMappedFromSource, RequiresReview)
    VALUES (@PositionCode, @Name, @NameEn, @JobFamily, @Description, @AffectsProductQuality, 0, 0);
    SET @PositionId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Site_List @ActorUserId INT, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SiteId, SiteCode, [Name], OrganizationId, TimeZoneId, IsActive
    FROM org.Site WHERE (@IsActive IS NULL OR IsActive = @IsActive) ORDER BY [Name]
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Department_List @ActorUserId INT, @SiteId INT = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT DepartmentId, DepartmentCode, [Name], SiteId, ManagerEmployeeId, IsActive
    FROM org.Department
    WHERE (@SiteId IS NULL OR SiteId = @SiteId) AND (@IsActive IS NULL OR IsActive = @IsActive)
    ORDER BY [Name] OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Area_List @ActorUserId INT, @DepartmentId INT = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT AreaId, AreaCode, [Name], DepartmentId, AreaType, SupervisorEmployeeId, IsActive
    FROM org.Area
    WHERE (@DepartmentId IS NULL OR DepartmentId = @DepartmentId) AND (@IsActive IS NULL OR IsActive = @IsActive)
    ORDER BY [Name] OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Station_List @ActorUserId INT, @AreaId INT = NULL, @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.StationId, s.PublicId, s.StationCode, s.[Name], s.AreaId
         , s.ProcessCode, s.EquipmentName, s.RequiresGating, s.GatingMode, s.IsActive
         , (SELECT COUNT(*) FROM comp.StationCompetency sc WHERE sc.StationId = s.StationId) AS RequirementCount
    FROM org.Station s
    WHERE (@AreaId IS NULL OR s.AreaId = @AreaId) AND (@IsActive IS NULL OR s.IsActive = @IsActive)
    ORDER BY s.[Name] OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE org.usp_Station_Upsert
      @ActorUserId INT, @StationId INT = NULL, @StationCode NVARCHAR(40)
    , @Name NVARCHAR(150), @AreaId INT
    , @ProcessCode NVARCHAR(40) = NULL, @EquipmentName NVARCHAR(150) = NULL
    , @RequiresGating BIT = 0, @GatingMode TINYINT = 1
    , @ResultStationId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'org.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        /* Upsert real: sin @StationId, resolver por StationCode. Un sync
           de estaciones re-ejecutado no debe duplicar. */
        IF @StationId IS NULL
            SELECT @StationId = StationId FROM org.Station WHERE StationCode = @StationCode;

        IF @StationId IS NULL
        BEGIN
            INSERT INTO org.Station (StationCode, [Name], AreaId, ProcessCode, EquipmentName, RequiresGating, GatingMode)
            VALUES (@StationCode, @Name, @AreaId, @ProcessCode, @EquipmentName, @RequiresGating, @GatingMode);
            SET @ResultStationId = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE org.Station
            SET StationCode = @StationCode, [Name] = @Name, AreaId = @AreaId
              , ProcessCode = @ProcessCode, EquipmentName = @EquipmentName
              , RequiresGating = @RequiresGating, GatingMode = @GatingMode
            WHERE StationId = @StationId;
            SET @ResultStationId = @StationId;
        END;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_Station_Upsert', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   org.usp_EmployeeAssignment_Set

   Ubica al empleado: sitio/departamento/area/estacion/turno vigente.
   Cierra la asignacion abierta y abre la nueva (historia, nunca update).
   La estacion es la unidad de gating: cambiarla dispara recalculo de
   brechas de inmediato.

   Errores: 50002 sin permiso, 50110 empleado no existe,
            50111 estacion no existe
   ===================================================================== */
CREATE OR ALTER PROCEDURE org.usp_EmployeeAssignment_Set
      @ActorUserId  INT
    , @EmployeeId   INT
    , @SiteId       INT = NULL
    , @DepartmentId INT = NULL
    , @AreaId       INT = NULL
    , @StationId    INT = NULL
    , @ShiftCode    NVARCHAR(20) = NULL
    , @EffectiveFromUtc DATETIME2(3) = NULL
    , @EmployeeAssignmentId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'employee.position.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF NOT EXISTS (SELECT 1 FROM org.Employee WHERE EmployeeId = @EmployeeId)
            THROW 50110, 'El empleado no existe.', 1;

        IF @StationId IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM org.Station
                           WHERE StationId = @StationId AND IsDeleted = 0)
            THROW 50111, 'La estacion no existe.', 1;

        SET @EffectiveFromUtc = ISNULL(@EffectiveFromUtc, SYSUTCDATETIME());

        BEGIN TRANSACTION;

        UPDATE org.EmployeeAssignment
        SET EffectiveToUtc = @EffectiveFromUtc
        WHERE EmployeeId = @EmployeeId AND EffectiveToUtc IS NULL;

        INSERT INTO org.EmployeeAssignment (EmployeeId, SiteId, DepartmentId, AreaId
                                          , StationId, ShiftCode, EffectiveFromUtc)
        VALUES (@EmployeeId, @SiteId, @DepartmentId, @AreaId
              , @StationId, @ShiftCode, @EffectiveFromUtc);

        SET @EmployeeAssignmentId = SCOPE_IDENTITY();

        /* Espejo denormalizado en org.Employee para joins baratos. */
        UPDATE org.Employee
        SET SiteId = COALESCE(@SiteId, SiteId)
          , DepartmentId = COALESCE(@DepartmentId, DepartmentId)
          , AreaId = COALESCE(@AreaId, AreaId)
          , ShiftCode = COALESCE(@ShiftCode, ShiftCode)
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EmployeeId = @EmployeeId;

        EXEC aud.usp_Event_Log
              @EventType   = N'EmployeeAssignment.Set'
            , @EntityType  = N'Employee'
            , @EntityId    = @EmployeeId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Asignacion de ubicacion/estacion actualizada.';

        COMMIT TRANSACTION;

        /* Fuera de la transaccion: una estacion nueva puede traer
           requisitos nuevos. */
        EXEC comp.usp_Gap_RecalculateForEmployee @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_EmployeeAssignment_Set', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   sec.usp_User_ProvisionForEmployees

   Aprovisionamiento masivo: crea el usuario de aplicacion (AuthMethod=2,
   PIN) para todo empleado activo que no tenga uno. UserName = codigo de
   empleado. Es la base del login universal de piso: no todo el mundo
   tiene correo/Entra.

   Devuelve los usuarios que quedaron SIN credencial y su semilla de PIN
   inicial (ultimos 4 de la cedula, derivados de NationalIdMasked). La
   API hashea la semilla con PBKDF2 y llama a sec.usp_User_SetPin por
   usuario: T-SQL nunca hace criptografia de contrasenas.

   Empleados sin cedula en el origen quedan reportados en el segundo
   resultset: a esos el PIN se les asigna manualmente.

   Errores: 50002 sin permiso
   ===================================================================== */
CREATE OR ALTER PROCEDURE sec.usp_User_ProvisionForEmployees
      @ActorUserId INT
    , @DefaultLocale NVARCHAR(10) = N'es-DO'
    , @UsersCreated INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();
        DECLARE @Created TABLE (UserId INT, EmployeeId INT);

        BEGIN TRANSACTION;

        INSERT INTO sec.[User] (EmployeeId, UserName, DisplayName, Email
                              , AuthMethod, PreferredLocale, IsActive, CreatedByUserId)
        OUTPUT inserted.UserId, inserted.EmployeeId INTO @Created (UserId, EmployeeId)
        SELECT  e.EmployeeId, e.EmployeeCode, e.FullName, e.Email
              , 2 /* Pin */, @DefaultLocale, 1, @ActorUserId
        FROM org.Employee e
        WHERE e.IsActive = 1
          AND NOT EXISTS (SELECT 1 FROM sec.[User] u
                          WHERE u.EmployeeId = e.EmployeeId AND u.IsDeleted = 0);

        SET @UsersCreated = @@ROWCOUNT;

        /* Rol base LEARNER a los recien creados (sus accesos se resuelven
           por pertenencia, no por permisos explicitos). */
        DECLARE @LearnerRoleId INT = (SELECT RoleId FROM sec.Role WHERE RoleCode = N'LEARNER');
        INSERT INTO sec.UserRoleAssignment (UserId, RoleId, ScopeType, AssignedByUserId)
        SELECT c.UserId, @LearnerRoleId, 1, @ActorUserId
        FROM @Created c
        WHERE @LearnerRoleId IS NOT NULL;

        EXEC aud.usp_Event_Log
              @EventType   = N'User.BulkProvisioned'
            , @EntityType  = N'User'
            , @ActorUserId = @ActorUserId
            , @Severity    = 3
            , @Summary     = N'Aprovisionamiento masivo de usuarios de piso.';

        COMMIT TRANSACTION;

        /* Resultset 1: usuarios pendientes de credencial + semilla de PIN
           (ultimos 4 de la cedula). Incluye usuarios de corridas
           anteriores que quedaron sin PIN. */
        SELECT  u.UserId
              , u.UserName AS EmployeeCode
              , u.DisplayName
              , RIGHT(e.NationalIdMasked, 4) AS PinSeed
        FROM sec.[User] u
        JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
        WHERE u.IsActive = 1 AND u.IsDeleted = 0
          AND u.AuthMethod IN (2, 3)
          AND e.NationalIdMasked IS NOT NULL
          AND LEN(e.NationalIdMasked) >= 4
          AND NOT EXISTS (SELECT 1 FROM sec.UserCredential c WHERE c.UserId = u.UserId);

        /* Resultset 2: sin cedula en el origen -> PIN manual */
        SELECT  u.UserId, u.UserName AS EmployeeCode, u.DisplayName
        FROM sec.[User] u
        JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
        WHERE u.IsActive = 1 AND u.IsDeleted = 0
          AND u.AuthMethod IN (2, 3)
          AND (e.NationalIdMasked IS NULL OR LEN(e.NationalIdMasked) < 4)
          AND NOT EXISTS (SELECT 1 FROM sec.UserCredential c WHERE c.UserId = u.UserId);

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'sec.usp_User_ProvisionForEmployees', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   org.usp_EmployeePhoto_Upsert

   Guarda o actualiza la foto del empleado (llega del hub de SPN via el
   login de Power Automate). Si la foto es identica (hash) no escribe:
   el login corre muchas veces al dia.

   Errores: 50002 sin permiso, 50110 empleado no existe
   ===================================================================== */
CREATE OR ALTER PROCEDURE org.usp_EmployeePhoto_Upsert
      @ActorUserId INT
    , @EmployeeId  INT
    , @PhotoBytes  VARBINARY(MAX)
    , @ContentType NVARCHAR(60) = N'image/jpeg'
    , @Source      NVARCHAR(30) = N'SPN_HUB'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        /* El propio empleado (su login refresca su foto) o quien maneja usuarios. */
        IF NOT EXISTS (SELECT 1 FROM sec.[User] WHERE UserId = @ActorUserId AND EmployeeId = @EmployeeId)
           AND sec.fn_UserHasPermission(@ActorUserId, N'user.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF NOT EXISTS (SELECT 1 FROM org.Employee WHERE EmployeeId = @EmployeeId)
            THROW 50110, 'El empleado no existe.', 1;

        IF @PhotoBytes IS NULL OR DATALENGTH(@PhotoBytes) = 0
            THROW 50010, 'PhotoBytes es requerido.', 1;

        /* Sin cambios -> sin escritura. */
        IF EXISTS (SELECT 1 FROM org.EmployeePhoto
                   WHERE EmployeeId = @EmployeeId
                     AND PhotoHash = CAST(HASHBYTES('SHA2_256', @PhotoBytes) AS VARBINARY(32)))
            RETURN 0;

        MERGE org.EmployeePhoto AS tgt
        USING (SELECT @EmployeeId AS EmployeeId) AS src ON tgt.EmployeeId = src.EmployeeId
        WHEN MATCHED THEN UPDATE SET
              PhotoBytes = @PhotoBytes, ContentType = @ContentType
            , [Source] = @Source, UpdatedAtUtc = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (EmployeeId, PhotoBytes, ContentType, [Source])
            VALUES (@EmployeeId, @PhotoBytes, @ContentType, @Source);

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_EmployeePhoto_Upsert', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   org.usp_EmployeePhoto_Get
   Sin @EmployeeId devuelve la foto del propio actor. Ver la de otro
   exige employee.read.all.
   ===================================================================== */
CREATE OR ALTER PROCEDURE org.usp_EmployeePhoto_Get
      @ActorUserId INT
    , @EmployeeId  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        IF @EmployeeId IS NULL
            SELECT @EmployeeId = EmployeeId FROM sec.[User] WHERE UserId = @ActorUserId;

        IF NOT EXISTS (SELECT 1 FROM sec.[User] WHERE UserId = @ActorUserId AND EmployeeId = @EmployeeId)
           AND sec.fn_UserHasPermission(@ActorUserId, N'employee.read.all') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        SELECT ContentType, PhotoBytes, UpdatedAtUtc
        FROM org.EmployeePhoto
        WHERE EmployeeId = @EmployeeId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'org.usp_EmployeePhoto_Get', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

PRINT '=== 11_procs_identity.sql completado ===';
GO

/* ############################################################################
   ARCHIVO: database/12_procs_catalog_content.sql
   ############################################################################ */
/* =====================================================================
   Classroom - LMS by Airlink
   12_procs_catalog_content.sql
   Esquema: lms (cursos, versiones, modulos, items, paginas, traduccion)

   Regla de oro del catalogo: una version publicada NO se edita jamas.
   Editar = crear un draft nuevo desde la publicada. Esto es lo que
   permite contestar "que decia el curso el dia que Fulano lo tomo".

   Codigos de error de este archivo: 50200-50299
   ===================================================================== */

USE AIRLINK_KMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 12_procs_catalog_content.sql iniciado ===';
GO

/* =====================================================================
   lms.usp_Course_Create
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_Course_Create
      @ActorUserId       INT
    , @CourseCode        NVARCHAR(40)
    , @NameEs            NVARCHAR(250)
    , @NameEn            NVARCHAR(250) = NULL
    , @CourseCategoryId  INT           = NULL
    , @DeliveryType      TINYINT       = 1     -- 1=Online 2=ILT 3=Blended 4=OJT
    , @OwnerDepartmentId INT           = NULL
    , @EstimatedMinutes  INT           = NULL
    , @AllowSelfEnrollment BIT         = 0
    , @IsBlueprint       BIT           = 0
    , @IdempotencyKey    UNIQUEIDENTIFIER = NULL
    , @CourseId          INT           = NULL OUTPUT
    , @CourseVersionId   INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------
       Proposito : crear un curso y su version 1 en estado Draft.
       Retorna   : CourseId, CourseVersionId (OUTPUT) + fila del curso.
       Errores   : 50201 codigo duplicado
       --------------------------------------------------------------- */

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.create') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF @IdempotencyKey IS NOT NULL
           AND EXISTS (SELECT 1 FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey)
        BEGIN
            SELECT @CourseId = ResultEntityId FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey;
            RETURN 0;
        END;

        IF EXISTS (SELECT 1 FROM lms.Course WHERE CourseCode = @CourseCode AND IsDeleted = 0)
            THROW 50201, 'Ya existe un curso con ese codigo.', 1;

        BEGIN TRANSACTION;

        INSERT INTO lms.Course (CourseCode, NameEs, NameEn, CourseCategoryId, DeliveryType
                              , OwnerDepartmentId, OwnerUserId, EstimatedMinutes
                              , IsBlueprint, AllowSelfEnrollment, [Status], CreatedByUserId)
        VALUES (@CourseCode, @NameEs, @NameEn, @CourseCategoryId, @DeliveryType
              , @OwnerDepartmentId, @ActorUserId, @EstimatedMinutes
              , @IsBlueprint, @AllowSelfEnrollment, 1, @ActorUserId);

        SET @CourseId = SCOPE_IDENTITY();

        INSERT INTO lms.CourseVersion (CourseId, VersionNumber, VersionLabel, [Status], CreatedByUserId)
        VALUES (@CourseId, 1, N'Rev.0', 1, @ActorUserId);

        SET @CourseVersionId = SCOPE_IDENTITY();

        /* Locale base siempre disponible. El ingles arranca pendiente. */
        INSERT INTO lms.CourseVersionLocale (CourseVersionId, LocaleCode, TranslationStatus, CompletionPercent, IsAvailable)
        VALUES (@CourseVersionId, N'es-DO', 3, 100.00, 1)
             , (@CourseVersionId, N'en-US', 1,   0.00, 0);

        IF @IdempotencyKey IS NOT NULL
            INSERT INTO aud.IdempotencyKey (IdempotencyKey, OperationName, ActorUserId, ResultEntityId)
            VALUES (@IdempotencyKey, N'lms.usp_Course_Create', @ActorUserId, @CourseId);

        EXEC aud.usp_Event_Log
              @EventType   = N'Course.Created'
            , @EntityType  = N'Course'
            , @EntityId    = @CourseId
            , @ActorUserId = @ActorUserId
            , @Summary     = N'Curso creado en estado borrador.';

        COMMIT TRANSACTION;

        SELECT c.CourseId, c.PublicId, c.CourseCode, c.NameEs, c.NameEn, c.[Status]
             , @CourseVersionId AS CourseVersionId
        FROM lms.Course c WHERE c.CourseId = @CourseId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Course_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   lms.usp_CourseVersion_CreateDraft
   Clona la version publicada completa (modulos, items, paginas) en una
   version nueva editable. Es la unica forma de "editar" un curso vivo.
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_CourseVersion_CreateDraft
      @ActorUserId     INT
    , @CourseId        INT
    , @SourceVersionId INT           = NULL   -- NULL = clona la vigente
    , @ChangeSummary   NVARCHAR(1000) = NULL
    , @NewVersionId    INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50202 ya existe un draft abierto, 50203 version origen invalida */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF EXISTS (SELECT 1 FROM lms.CourseVersion WHERE CourseId = @CourseId AND [Status] IN (1,2))
            THROW 50202, 'Ya existe un borrador o una version en revision para este curso. Publiquela o descartela primero.', 1;

        SELECT @SourceVersionId = COALESCE(@SourceVersionId, c.CurrentVersionId)
        FROM lms.Course c WHERE c.CourseId = @CourseId;

        IF @SourceVersionId IS NULL
            THROW 50203, 'No hay version de origen para clonar.', 1;

        DECLARE @NextNumber INT;
        SELECT @NextNumber = ISNULL(MAX(VersionNumber), 0) + 1
        FROM lms.CourseVersion WHERE CourseId = @CourseId;

        BEGIN TRANSACTION;

        INSERT INTO lms.CourseVersion (CourseId, VersionNumber, VersionLabel, [Status]
                                     , DescriptionEs, DescriptionEn, ObjectivesEs, ObjectivesEn
                                     , PassingScore, MaxAttempts, EnforceSequence, EnforceMinimumTime
                                     , RequiresRetraining, ChangeSummary, CreatedByUserId)
        SELECT  @CourseId, @NextNumber, N'Rev.' + CAST(@NextNumber - 1 AS NVARCHAR(10)), 1
              , v.DescriptionEs, v.DescriptionEn, v.ObjectivesEs, v.ObjectivesEn
              , v.PassingScore, v.MaxAttempts, v.EnforceSequence, v.EnforceMinimumTime
              , 0, @ChangeSummary, @ActorUserId
        FROM lms.CourseVersion v WHERE v.CourseVersionId = @SourceVersionId;

        SET @NewVersionId = SCOPE_IDENTITY();

        /* Paginas primero: los items apuntan a ellas. Guardamos el mapeo
           viejo->nuevo para reapuntar ModuleItem.TargetId. */
        DECLARE @PageMap TABLE (OldId INT PRIMARY KEY, NewId INT NOT NULL);

        MERGE lms.Page AS tgt
        USING (SELECT PageId, TitleEs, TitleEn, BodyHtmlEs, BodyHtmlEn, EstimatedMinutes
               FROM lms.Page WHERE CourseVersionId = @SourceVersionId AND IsDeleted = 0) AS src
        ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (CourseVersionId, TitleEs, TitleEn, BodyHtmlEs, BodyHtmlEn, EstimatedMinutes, CreatedByUserId)
            VALUES (@NewVersionId, src.TitleEs, src.TitleEn, src.BodyHtmlEs, src.BodyHtmlEn, src.EstimatedMinutes, @ActorUserId)
        OUTPUT src.PageId, inserted.PageId INTO @PageMap (OldId, NewId);

        /* Modulos */
        DECLARE @ModuleMap TABLE (OldId INT PRIMARY KEY, NewId INT NOT NULL);

        MERGE lms.CourseModule AS tgt
        USING (SELECT CourseModuleId, TitleEs, TitleEn, SortOrder, CompletionRule
                    , MinimumScore, IsRequired
               FROM lms.CourseModule WHERE CourseVersionId = @SourceVersionId AND IsDeleted = 0) AS src
        ON 1 = 0
        WHEN NOT MATCHED THEN
            INSERT (CourseVersionId, TitleEs, TitleEn, SortOrder, CompletionRule, MinimumScore, IsRequired, CreatedByUserId)
            VALUES (@NewVersionId, src.TitleEs, src.TitleEn, src.SortOrder, src.CompletionRule
                  , src.MinimumScore, src.IsRequired, @ActorUserId)
        OUTPUT src.CourseModuleId, inserted.CourseModuleId INTO @ModuleMap (OldId, NewId);

        /* Prerrequisitos de modulo: reapuntar al modulo clonado. */
        UPDATE nm
        SET PrerequisiteModuleId = pm.NewId
        FROM lms.CourseModule nm
        JOIN @ModuleMap mm ON mm.NewId = nm.CourseModuleId
        JOIN lms.CourseModule om ON om.CourseModuleId = mm.OldId
        JOIN @ModuleMap pm ON pm.OldId = om.PrerequisiteModuleId
        WHERE nm.CourseVersionId = @NewVersionId;

        /* Items. ItemType 1=Page se reapunta via @PageMap; los demas tipos
           (Quiz, Video, Documento controlado) se reapuntan en su propio
           bloque o quedan apuntando al recurso compartido. */
        INSERT INTO lms.ModuleItem (CourseModuleId, ItemType, TargetId, TitleEs, TitleEn
                                  , SortOrder, Indent, IsRequiredForCompletion, CompletionCriteria
                                  , MinimumScore, MinimumSeconds, Points, CreatedByUserId)
        SELECT  mm.NewId
              , i.ItemType
              , CASE WHEN i.ItemType = 1 THEN pm.NewId ELSE i.TargetId END
              , i.TitleEs, i.TitleEn, i.SortOrder, i.Indent
              , i.IsRequiredForCompletion, i.CompletionCriteria
              , i.MinimumScore, i.MinimumSeconds, i.Points, @ActorUserId
        FROM lms.ModuleItem i
        JOIN @ModuleMap mm ON mm.OldId = i.CourseModuleId
        LEFT JOIN @PageMap pm ON pm.OldId = i.TargetId AND i.ItemType = 1
        WHERE i.IsDeleted = 0;

        /* Locales */
        INSERT INTO lms.CourseVersionLocale (CourseVersionId, LocaleCode, TranslationStatus, CompletionPercent, IsAvailable)
        SELECT @NewVersionId, LocaleCode, TranslationStatus, CompletionPercent, IsAvailable
        FROM lms.CourseVersionLocale WHERE CourseVersionId = @SourceVersionId;

        EXEC aud.usp_Event_Log
              @EventType   = N'CourseVersion.DraftCreated'
            , @EntityType  = N'CourseVersion'
            , @EntityId    = @NewVersionId
            , @ActorUserId = @ActorUserId
            , @Summary     = N'Borrador creado a partir de una version existente.';

        COMMIT TRANSACTION;

        SELECT @NewVersionId AS CourseVersionId, @NextNumber AS VersionNumber;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_CourseVersion_CreateDraft', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   lms.usp_CourseVersion_SubmitForReview
   Crea las filas de aprobacion. SoD: el autor no puede ser el aprobador
   de calidad (validado tambien en sec.usp_UserRole_Assign).
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_CourseVersion_SubmitForReview
      @ActorUserId        INT
    , @CourseVersionId    INT
    , @TechnicalReviewerUserId INT
    , @QualityApproverUserId   INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50204 version no esta en Draft
                50205 conflicto de segregacion de funciones
                50206 curso sin contenido evaluable */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.submit') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        DECLARE @AuthorUserId INT, @Status TINYINT;
        SELECT @Status = [Status], @AuthorUserId = CreatedByUserId
        FROM lms.CourseVersion WHERE CourseVersionId = @CourseVersionId;

        IF @Status IS NULL THROW 50001, 'Version de curso no encontrada.', 1;
        IF @Status <> 1 THROW 50204, 'Solo una version en borrador puede enviarse a revision.', 1;

        IF @QualityApproverUserId IN (@AuthorUserId, @ActorUserId)
            THROW 50205, 'El aprobador de calidad no puede ser el autor ni quien envia a revision.', 1;

        IF NOT EXISTS (SELECT 1 FROM lms.CourseModule m
                       JOIN lms.ModuleItem i ON i.CourseModuleId = m.CourseModuleId AND i.IsDeleted = 0
                       WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0)
            THROW 50206, 'La version no tiene contenido. Agregue al menos un modulo con items.', 1;

        BEGIN TRANSACTION;

        UPDATE lms.CourseVersion
        SET [Status] = 2, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE CourseVersionId = @CourseVersionId;

        DELETE FROM lms.CourseApproval WHERE CourseVersionId = @CourseVersionId AND DecidedAtUtc IS NULL;

        INSERT INTO lms.CourseApproval (CourseVersionId, ApprovalRole, ApproverUserId)
        VALUES (@CourseVersionId, 2, @TechnicalReviewerUserId)
             , (@CourseVersionId, 3, @QualityApproverUserId);

        EXEC ops.usp_Notification_Enqueue
              @TemplateCode = N'Course.ReviewRequested'
            , @RecipientUserId = @TechnicalReviewerUserId
            , @Priority = 1
            , @DedupeKey = NULL;

        EXEC aud.usp_Event_Log
              @EventType   = N'CourseVersion.SubmittedForReview'
            , @EntityType  = N'CourseVersion'
            , @EntityId    = @CourseVersionId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Version enviada a revision tecnica y aprobacion de calidad.';

        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_CourseVersion_SubmitForReview', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   lms.usp_CourseVersion_Publish

   Punto de control mas delicado del catalogo. Al publicar:
     1. valida que todas las aprobaciones esten en Approved,
     2. retira la version anterior,
     3. deja firma electronica de la publicacion,
     4. si RequiresRetraining = 1, marca las certificaciones apoyadas en
        la version anterior como RetrainingRequired (GAP-02/GAP-03).

   Las inscripciones EN CURSO no se mueven de version: quien empezo con
   Rev.1 la termina con Rev.1. El retraining se maneja como inscripcion
   nueva, no como cambio de piso bajo los pies del operador.
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_CourseVersion_Publish
      @ActorUserId     INT
    , @CourseVersionId INT
    , @EffectiveAtUtc  DATETIME2(3) = NULL
    , @SignatureMeaning NVARCHAR(60) = N'Approved'
    , @PayloadCanonical NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50207 aprobaciones incompletas
                50208 version no esta en revision                       */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.publish') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        DECLARE @CourseId INT, @Status TINYINT, @RequiresRetraining BIT, @PreviousVersionId INT;

        SELECT @CourseId = CourseId, @Status = [Status], @RequiresRetraining = RequiresRetraining
        FROM lms.CourseVersion WHERE CourseVersionId = @CourseVersionId;

        IF @CourseId IS NULL THROW 50001, 'Version de curso no encontrada.', 1;
        IF @Status <> 2 THROW 50208, 'Solo una version en revision puede publicarse.', 1;

        IF EXISTS (SELECT 1 FROM lms.CourseApproval
                   WHERE CourseVersionId = @CourseVersionId
                     AND (Decision IS NULL OR Decision <> 1))
            THROW 50207, 'Faltan aprobaciones. Todas deben estar en Aprobado antes de publicar.', 1;

        SET @EffectiveAtUtc = ISNULL(@EffectiveAtUtc, SYSUTCDATETIME());
        SELECT @PreviousVersionId = CurrentVersionId FROM lms.Course WHERE CourseId = @CourseId;

        BEGIN TRANSACTION;

        UPDATE lms.CourseVersion
        SET [Status] = 3, PublishedAtUtc = @EffectiveAtUtc, PublishedByUserId = @ActorUserId
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE CourseVersionId = @CourseVersionId;

        IF @PreviousVersionId IS NOT NULL AND @PreviousVersionId <> @CourseVersionId
            UPDATE lms.CourseVersion
            SET [Status] = 4, RetiredAtUtc = @EffectiveAtUtc
            WHERE CourseVersionId = @PreviousVersionId;

        UPDATE lms.Course
        SET CurrentVersionId = @CourseVersionId, [Status] = 2
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE CourseId = @CourseId;

        /* Firma de la publicacion: evidencia de aprobacion formal. */
        DECLARE @SignatureId BIGINT;
        SET @PayloadCanonical = ISNULL(@PayloadCanonical,
            (SELECT CourseVersionId = @CourseVersionId, CourseId = @CourseId
                  , PublishedAtUtc = @EffectiveAtUtc
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER));

        EXEC aud.usp_Signature_Create
              @ActorUserId      = @ActorUserId
            , @SignatureMeaning = @SignatureMeaning
            , @EntityType       = N'CourseVersion'
            , @EntityId         = @CourseVersionId
            , @PayloadCanonical = @PayloadCanonical
            , @AuthMethod       = 1
            , @SignatureRecordId = @SignatureId OUTPUT;

        COMMIT TRANSACTION;

        /* Retraining: fuera de la transaccion de publicacion porque puede
           tocar miles de certificaciones. Idempotente. */
        IF @RequiresRetraining = 1 AND @PreviousVersionId IS NOT NULL
            EXEC comp.usp_Certification_FlagRetrainingForCourseVersion
                  @ActorUserId       = @ActorUserId
                , @PreviousVersionId = @PreviousVersionId
                , @NewVersionId      = @CourseVersionId;

        EXEC aud.usp_Event_Log
              @EventType   = N'CourseVersion.Published'
            , @EntityType  = N'CourseVersion'
            , @EntityId    = @CourseVersionId
            , @ActorUserId = @ActorUserId
            , @Severity    = 3
            , @Summary     = N'Version publicada y puesta como vigente.';

        SELECT @CourseVersionId AS CourseVersionId, @SignatureId AS SignatureRecordId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_CourseVersion_Publish', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   lms.usp_CourseVersion_GetForLearner
   Devuelve el arbol completo del curso en el idioma del aprendiz, con
   fallback a es-DO si la traduccion no esta disponible (GAP-10).
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_CourseVersion_GetForLearner
      @ActorUserId     INT
    , @EnrollmentId    INT
    , @LocaleCode      NVARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @CourseVersionId INT, @EmployeeId INT, @UseEn BIT = 0;

        SELECT @CourseVersionId = e.CourseVersionId, @EmployeeId = e.EmployeeId
        FROM dlv.Enrollment e WHERE e.EnrollmentId = @EnrollmentId;

        IF @CourseVersionId IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;

        /* El aprendiz solo ve sus propias inscripciones. */
        IF NOT EXISTS (SELECT 1 FROM sec.[User] u WHERE u.UserId = @ActorUserId AND u.EmployeeId = @EmployeeId)
           AND sec.fn_UserHasPermission(@ActorUserId, N'enrollment.read.all') = 0
            THROW 50002, 'El usuario no tiene permiso para ver esta inscripcion.', 1;

        SELECT @LocaleCode = ISNULL(@LocaleCode, u.PreferredLocale)
        FROM sec.[User] u WHERE u.UserId = @ActorUserId;

        /* Fallback: si en-US no esta disponible en esta version, se sirve es-DO. */
        IF @LocaleCode = N'en-US'
           AND EXISTS (SELECT 1 FROM lms.CourseVersionLocale
                       WHERE CourseVersionId = @CourseVersionId AND LocaleCode = N'en-US' AND IsAvailable = 1)
            SET @UseEn = 1;

        /* Resultset 1: cabecera */
        SELECT  v.CourseVersionId, v.CourseId, v.VersionNumber, v.VersionLabel
              , CASE WHEN @UseEn = 1 THEN ISNULL(c.NameEn, c.NameEs) ELSE c.NameEs END AS CourseName
              , CASE WHEN @UseEn = 1 THEN ISNULL(v.DescriptionEn, v.DescriptionEs) ELSE v.DescriptionEs END AS [Description]
              , CASE WHEN @UseEn = 1 THEN ISNULL(v.ObjectivesEn, v.ObjectivesEs) ELSE v.ObjectivesEs END AS Objectives
              , v.PassingScore, v.MaxAttempts, v.EnforceSequence, v.EnforceMinimumTime
              , c.DeliveryType, c.EstimatedMinutes
              , @UseEn AS IsEnglish
        FROM lms.CourseVersion v
        JOIN lms.Course c ON c.CourseId = v.CourseId
        WHERE v.CourseVersionId = @CourseVersionId;

        /* Resultset 2: modulos con progreso */
        SELECT  m.CourseModuleId
              , CASE WHEN @UseEn = 1 THEN ISNULL(m.TitleEn, m.TitleEs) ELSE m.TitleEs END AS Title
              , m.SortOrder, m.PrerequisiteModuleId, m.CompletionRule, m.MinimumScore, m.IsRequired
              , ISNULL(mp.[Status], 1) AS ProgressStatus
              , ISNULL(mp.ProgressPercent, 0) AS ProgressPercent
        FROM lms.CourseModule m
        LEFT JOIN dlv.ModuleProgress mp ON mp.CourseModuleId = m.CourseModuleId AND mp.EnrollmentId = @EnrollmentId
        WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0
        ORDER BY m.SortOrder;

        /* Resultset 3: items con progreso */
        SELECT  i.ModuleItemId, i.CourseModuleId, i.ItemType, i.TargetId
              , CASE WHEN @UseEn = 1 THEN ISNULL(i.TitleEn, i.TitleEs) ELSE i.TitleEs END AS Title
              , i.SortOrder, i.Indent, i.IsRequiredForCompletion, i.CompletionCriteria
              , i.MinimumScore, i.MinimumSeconds, i.Points
              , ISNULL(ip.[Status], 1) AS ProgressStatus
              , ip.ScorePercent, ip.TimeSpentSeconds, ip.VideoPositionSeconds, ip.CompletedAtUtc
        FROM lms.ModuleItem i
        JOIN lms.CourseModule m ON m.CourseModuleId = i.CourseModuleId
        LEFT JOIN dlv.ItemProgress ip ON ip.ModuleItemId = i.ModuleItemId AND ip.EnrollmentId = @EnrollmentId
        WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0 AND i.IsDeleted = 0
        ORDER BY m.SortOrder, i.SortOrder;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_CourseVersion_GetForLearner', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Catalogo: lectura y mantenimiento
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_Course_Get
      @ActorUserId INT, @CourseId INT = NULL, @CourseCode NVARCHAR(40) = NULL
    , @PublicId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @CourseId = COALESCE(@CourseId, c.CourseId)
    FROM lms.Course c
    WHERE (@CourseCode IS NOT NULL AND c.CourseCode = @CourseCode)
       OR (@PublicId   IS NOT NULL AND c.PublicId   = @PublicId);

    IF @CourseId IS NULL THROW 50001, 'Curso no encontrado.', 1;

    SELECT c.CourseId, c.PublicId, c.CourseCode, c.NameEs, c.NameEn
         , c.CourseCategoryId, c.DeliveryType, c.OwnerDepartmentId, c.OwnerUserId
         , c.EstimatedMinutes, c.IsBlueprint, c.AllowSelfEnrollment
         , c.CurrentVersionId, c.[Status], c.CreatedAtUtc
    FROM lms.Course c WHERE c.CourseId = @CourseId AND c.IsDeleted = 0;

    SELECT v.CourseVersionId, v.VersionNumber, v.VersionLabel, v.[Status]
         , v.PassingScore, v.MaxAttempts, v.RequiresRetraining
         , v.PublishedAtUtc, v.RetiredAtUtc, v.ChangeSummary
    FROM lms.CourseVersion v WHERE v.CourseId = @CourseId
    ORDER BY v.VersionNumber DESC;

    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Course_List
      @ActorUserId INT, @SearchText NVARCHAR(100) = NULL
    , @CourseCategoryId INT = NULL, @DeliveryType TINYINT = NULL
    , @Status TINYINT = NULL, @OwnerDepartmentId INT = NULL
    , @PageNumber INT = 1, @PageSize INT = 50
    , @SortBy NVARCHAR(50) = N'NameEs', @SortDir CHAR(4) = 'ASC'
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    IF @SortDir NOT IN ('ASC','DESC') SET @SortDir = 'ASC';
    IF @SortBy NOT IN (N'NameEs', N'CourseCode', N'CreatedAtUtc') SET @SortBy = N'NameEs';

    SELECT  c.CourseId, c.PublicId, c.CourseCode, c.NameEs, c.NameEn
          , c.DeliveryType, c.[Status], c.CurrentVersionId, c.EstimatedMinutes
          , cat.NameEs AS CategoryName
          , (SELECT COUNT(*) FROM dlv.Enrollment e
             WHERE e.CourseId = c.CourseId AND e.[Status] IN (1,2)) AS ActiveEnrollments
    FROM lms.Course c
    LEFT JOIN lms.CourseCategory cat ON cat.CourseCategoryId = c.CourseCategoryId
    WHERE c.IsDeleted = 0
      AND (@SearchText       IS NULL OR c.NameEs LIKE N'%' + @SearchText + N'%' OR c.CourseCode LIKE @SearchText + N'%')
      AND (@CourseCategoryId IS NULL OR c.CourseCategoryId = @CourseCategoryId)
      AND (@DeliveryType     IS NULL OR c.DeliveryType     = @DeliveryType)
      AND (@Status           IS NULL OR c.[Status]         = @Status)
      AND (@OwnerDepartmentId IS NULL OR c.OwnerDepartmentId = @OwnerDepartmentId)
    ORDER BY
          CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'NameEs'       THEN c.NameEs       END ASC
        , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'NameEs'       THEN c.NameEs       END DESC
        , CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'CourseCode'   THEN c.CourseCode   END ASC
        , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'CourseCode'   THEN c.CourseCode   END DESC
        , CASE WHEN @SortDir = 'ASC'  AND @SortBy = N'CreatedAtUtc' THEN c.CreatedAtUtc END ASC
        , CASE WHEN @SortDir = 'DESC' AND @SortBy = N'CreatedAtUtc' THEN c.CreatedAtUtc END DESC
        , c.CourseId
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    SELECT COUNT(*) AS TotalCount FROM lms.Course c
    WHERE c.IsDeleted = 0
      AND (@SearchText       IS NULL OR c.NameEs LIKE N'%' + @SearchText + N'%' OR c.CourseCode LIKE @SearchText + N'%')
      AND (@CourseCategoryId IS NULL OR c.CourseCategoryId = @CourseCategoryId)
      AND (@DeliveryType     IS NULL OR c.DeliveryType     = @DeliveryType)
      AND (@Status           IS NULL OR c.[Status]         = @Status)
      AND (@OwnerDepartmentId IS NULL OR c.OwnerDepartmentId = @OwnerDepartmentId)
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Course_Update
      @ActorUserId INT, @CourseId INT
    , @NameEs NVARCHAR(250) = NULL, @NameEn NVARCHAR(250) = NULL
    , @CourseCategoryId INT = NULL, @OwnerDepartmentId INT = NULL
    , @EstimatedMinutes INT = NULL, @AllowSelfEnrollment BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    UPDATE lms.Course
    SET  NameEs = ISNULL(@NameEs, NameEs)
       , NameEn = ISNULL(@NameEn, NameEn)
       , CourseCategoryId = ISNULL(@CourseCategoryId, CourseCategoryId)
       , OwnerDepartmentId = ISNULL(@OwnerDepartmentId, OwnerDepartmentId)
       , EstimatedMinutes = ISNULL(@EstimatedMinutes, EstimatedMinutes)
       , AllowSelfEnrollment = ISNULL(@AllowSelfEnrollment, AllowSelfEnrollment)
       , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE CourseId = @CourseId AND IsDeleted = 0;
    IF @@ROWCOUNT = 0 THROW 50001, 'Curso no encontrado.', 1;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Course_Retire
      @ActorUserId INT, @CourseId INT, @Reason NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50209 el curso satisface requisitos activos */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.retire') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF EXISTS (SELECT 1 FROM comp.RequirementSatisfier rs
                   JOIN comp.CompetencyRequirement r ON r.RequirementId = rs.RequirementId AND r.[Status] = 1
                   WHERE rs.SatisfierType = 1 AND rs.SatisfierId = @CourseId)
            THROW 50209, 'No se puede retirar: el curso satisface requisitos de competencia activos. Reemplacelo primero.', 1;

        BEGIN TRANSACTION;
        UPDATE lms.Course SET [Status] = 3, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE CourseId = @CourseId;

        EXEC aud.usp_Event_Log @EventType = N'Course.Retired', @EntityType = N'Course'
           , @EntityId = @CourseId, @ActorUserId = @ActorUserId, @Severity = 3
           , @Summary = N'Curso retirado del catalogo.';
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Course_Retire', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_CourseVersion_Get
      @ActorUserId INT, @CourseVersionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT v.*, c.CourseCode, c.NameEs AS CourseNameEs
    FROM lms.CourseVersion v JOIN lms.Course c ON c.CourseId = v.CourseId
    WHERE v.CourseVersionId = @CourseVersionId;

    SELECT m.CourseModuleId, m.TitleEs, m.TitleEn, m.SortOrder, m.PrerequisiteModuleId
         , m.CompletionRule, m.MinimumScore, m.IsRequired
    FROM lms.CourseModule m
    WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0 ORDER BY m.SortOrder;

    SELECT i.ModuleItemId, i.CourseModuleId, i.ItemType, i.TargetId, i.TitleEs, i.TitleEn
         , i.SortOrder, i.Indent, i.IsRequiredForCompletion, i.CompletionCriteria
         , i.MinimumScore, i.MinimumSeconds, i.Points
    FROM lms.ModuleItem i
    JOIN lms.CourseModule m ON m.CourseModuleId = i.CourseModuleId
    WHERE m.CourseVersionId = @CourseVersionId AND i.IsDeleted = 0
    ORDER BY m.SortOrder, i.SortOrder;

    SELECT a.CourseApprovalId, a.ApprovalRole, a.ApproverUserId, u.DisplayName AS ApproverName
         , a.Decision, a.Comments, a.RequestedAtUtc, a.DecidedAtUtc
    FROM lms.CourseApproval a
    LEFT JOIN sec.[User] u ON u.UserId = a.ApproverUserId
    WHERE a.CourseVersionId = @CourseVersionId ORDER BY a.ApprovalRole;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Module_Add
      @ActorUserId INT, @CourseVersionId INT
    , @TitleEs NVARCHAR(250), @TitleEn NVARCHAR(250) = NULL
    , @SortOrder INT = NULL, @PrerequisiteModuleId INT = NULL
    , @CompletionRule TINYINT = 1, @MinimumScore DECIMAL(5,2) = NULL
    , @IsRequired BIT = 1, @CourseModuleId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50210 no se puede editar una version publicada */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF EXISTS (SELECT 1 FROM lms.CourseVersion WHERE CourseVersionId = @CourseVersionId AND [Status] NOT IN (1,2))
            THROW 50210, 'No se puede modificar una version publicada o retirada. Cree un borrador nuevo.', 1;

        IF @SortOrder IS NULL
            SELECT @SortOrder = ISNULL(MAX(SortOrder), 0) + 10
            FROM lms.CourseModule WHERE CourseVersionId = @CourseVersionId;

        INSERT INTO lms.CourseModule (CourseVersionId, TitleEs, TitleEn, SortOrder, PrerequisiteModuleId
                                    , CompletionRule, MinimumScore, IsRequired, CreatedByUserId)
        VALUES (@CourseVersionId, @TitleEs, @TitleEn, @SortOrder, @PrerequisiteModuleId
              , @CompletionRule, @MinimumScore, @IsRequired, @ActorUserId);
        SET @CourseModuleId = SCOPE_IDENTITY();
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Module_Add', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Module_SetRequirements
      @ActorUserId INT, @CourseModuleId INT
    , @CompletionRule TINYINT, @MinimumScore DECIMAL(5,2) = NULL
    , @IsRequired BIT = 1, @PrerequisiteModuleId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    UPDATE lms.CourseModule
    SET CompletionRule = @CompletionRule, MinimumScore = @MinimumScore
      , IsRequired = @IsRequired, PrerequisiteModuleId = @PrerequisiteModuleId
      , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE CourseModuleId = @CourseModuleId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_ModuleItem_Add
      @ActorUserId INT, @CourseModuleId INT, @ItemType TINYINT, @TargetId INT = NULL
    , @TitleEs NVARCHAR(250), @TitleEn NVARCHAR(250) = NULL
    , @SortOrder INT = NULL, @Indent TINYINT = 0
    , @IsRequiredForCompletion BIT = 1, @CompletionCriteria TINYINT = 1
    , @MinimumScore DECIMAL(5,2) = NULL, @MinimumSeconds INT = NULL
    , @Points DECIMAL(9,2) = NULL, @ModuleItemId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50211 TargetId requerido para este ItemType */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        /* ItemType 7 = SubHeader es el unico que admite TargetId NULL. */
        IF @ItemType <> 7 AND @TargetId IS NULL
            THROW 50211, 'TargetId es requerido para este tipo de item.', 1;

        IF @SortOrder IS NULL
            SELECT @SortOrder = ISNULL(MAX(SortOrder), 0) + 10
            FROM lms.ModuleItem WHERE CourseModuleId = @CourseModuleId;

        INSERT INTO lms.ModuleItem (CourseModuleId, ItemType, TargetId, TitleEs, TitleEn, SortOrder, Indent
                                  , IsRequiredForCompletion, CompletionCriteria, MinimumScore, MinimumSeconds
                                  , Points, CreatedByUserId)
        VALUES (@CourseModuleId, @ItemType, @TargetId, @TitleEs, @TitleEn, @SortOrder, @Indent
              , @IsRequiredForCompletion, @CompletionCriteria, @MinimumScore, @MinimumSeconds
              , @Points, @ActorUserId);
        SET @ModuleItemId = SCOPE_IDENTITY();
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_ModuleItem_Add', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_ModuleItem_Update
      @ActorUserId INT, @ModuleItemId INT
    , @TitleEs NVARCHAR(250) = NULL, @TitleEn NVARCHAR(250) = NULL
    , @SortOrder INT = NULL, @Indent TINYINT = NULL
    , @IsRequiredForCompletion BIT = NULL, @CompletionCriteria TINYINT = NULL
    , @MinimumScore DECIMAL(5,2) = NULL, @MinimumSeconds INT = NULL, @Points DECIMAL(9,2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    UPDATE lms.ModuleItem
    SET  TitleEs = ISNULL(@TitleEs, TitleEs), TitleEn = ISNULL(@TitleEn, TitleEn)
       , SortOrder = ISNULL(@SortOrder, SortOrder), Indent = ISNULL(@Indent, Indent)
       , IsRequiredForCompletion = ISNULL(@IsRequiredForCompletion, IsRequiredForCompletion)
       , CompletionCriteria = ISNULL(@CompletionCriteria, CompletionCriteria)
       , MinimumScore = ISNULL(@MinimumScore, MinimumScore)
       , MinimumSeconds = ISNULL(@MinimumSeconds, MinimumSeconds)
       , Points = ISNULL(@Points, Points)
       , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE ModuleItemId = @ModuleItemId AND IsDeleted = 0;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Page_Upsert
      @ActorUserId INT, @CourseVersionId INT, @PageId INT = NULL
    , @TitleEs NVARCHAR(250), @TitleEn NVARCHAR(250) = NULL
    , @BodyHtmlEs NVARCHAR(MAX) = NULL, @BodyHtmlEn NVARCHAR(MAX) = NULL
    , @EstimatedMinutes INT = NULL, @ResultPageId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    /* El HTML llega ya sanitizado por la API. T-SQL no sanitiza HTML. */
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

    IF @PageId IS NULL
    BEGIN
        INSERT INTO lms.Page (CourseVersionId, TitleEs, TitleEn, BodyHtmlEs, BodyHtmlEn, EstimatedMinutes, CreatedByUserId)
        VALUES (@CourseVersionId, @TitleEs, @TitleEn, @BodyHtmlEs, @BodyHtmlEn, @EstimatedMinutes, @ActorUserId);
        SET @ResultPageId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE lms.Page
        SET TitleEs = @TitleEs, TitleEn = @TitleEn, BodyHtmlEs = @BodyHtmlEs, BodyHtmlEn = @BodyHtmlEn
          , EstimatedMinutes = @EstimatedMinutes, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE PageId = @PageId AND IsDeleted = 0;
        SET @ResultPageId = @PageId;
    END;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Page_Get
      @ActorUserId INT, @PageId INT, @LocaleCode NVARCHAR(10) = N'es-DO'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.PageId, p.PublicId, p.CourseVersionId
         , CASE WHEN @LocaleCode = N'en-US' THEN ISNULL(p.TitleEn, p.TitleEs) ELSE p.TitleEs END AS Title
         , CASE WHEN @LocaleCode = N'en-US' THEN ISNULL(p.BodyHtmlEn, p.BodyHtmlEs) ELSE p.BodyHtmlEs END AS BodyHtml
         , p.EstimatedMinutes
    FROM lms.Page p WHERE p.PageId = @PageId AND p.IsDeleted = 0;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Category_Upsert
      @ActorUserId INT, @CourseCategoryId INT = NULL, @CategoryCode NVARCHAR(40)
    , @NameEs NVARCHAR(150), @NameEn NVARCHAR(150) = NULL
    , @ParentCategoryId INT = NULL, @SortOrder INT = 0
    , @ResultCategoryId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.edit') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    IF @CourseCategoryId IS NULL
    BEGIN
        INSERT INTO lms.CourseCategory (CategoryCode, NameEs, NameEn, ParentCategoryId, SortOrder)
        VALUES (@CategoryCode, @NameEs, @NameEn, @ParentCategoryId, @SortOrder);
        SET @ResultCategoryId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE lms.CourseCategory
        SET CategoryCode = @CategoryCode, NameEs = @NameEs, NameEn = @NameEn
          , ParentCategoryId = @ParentCategoryId, SortOrder = @SortOrder
        WHERE CourseCategoryId = @CourseCategoryId;
        SET @ResultCategoryId = @CourseCategoryId;
    END;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Program_Create
      @ActorUserId INT, @ProgramCode NVARCHAR(40), @NameEs NVARCHAR(250)
    , @NameEn NVARCHAR(250) = NULL, @DescriptionEs NVARCHAR(MAX) = NULL
    , @EnforceSequence BIT = 1, @ProgramId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'program.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO lms.Program (ProgramCode, NameEs, NameEn, DescriptionEs, EnforceSequence, [Status], CreatedByUserId)
    VALUES (@ProgramCode, @NameEs, @NameEn, @DescriptionEs, @EnforceSequence, 1, @ActorUserId);
    SET @ProgramId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

/* =====================================================================
   Traduccion (GAP-10)
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_Translation_Upsert
      @ActorUserId INT, @EntityType TINYINT, @EntityId INT
    , @LocaleCode NVARCHAR(10), @FieldName NVARCHAR(50), @TranslatedText NVARCHAR(MAX)
    , @IsReview BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.translate') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        MERGE lms.ContentTranslation AS tgt
        USING (SELECT @EntityType AS EntityType, @EntityId AS EntityId
                    , @LocaleCode AS LocaleCode, @FieldName AS FieldName) AS src
        ON  tgt.EntityType = src.EntityType AND tgt.EntityId = src.EntityId
        AND tgt.LocaleCode = src.LocaleCode AND tgt.FieldName = src.FieldName
        WHEN MATCHED THEN UPDATE SET
              TranslatedText = @TranslatedText
            , TranslatedByUserId = CASE WHEN @IsReview = 0 THEN @ActorUserId ELSE tgt.TranslatedByUserId END
            , ReviewedByUserId   = CASE WHEN @IsReview = 1 THEN @ActorUserId ELSE tgt.ReviewedByUserId END
            , ModifiedAtUtc = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT
              (EntityType, EntityId, LocaleCode, FieldName, TranslatedText, TranslatedByUserId)
            VALUES (@EntityType, @EntityId, @LocaleCode, @FieldName, @TranslatedText, @ActorUserId);
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Translation_Upsert', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE lms.usp_Translation_GetStatus
      @ActorUserId INT, @CourseVersionId INT
AS
BEGIN
    SET NOCOUNT ON;
    /* Cuenta campos traducibles vs traducidos por locale. Alimenta el
       semaforo de "listo para publicar en ingles". */
    ;WITH Translatable AS (
        SELECT 1 AS EntityType, p.PageId AS EntityId, N'Title' AS FieldName, p.TitleEn AS Existing
        FROM lms.Page p WHERE p.CourseVersionId = @CourseVersionId AND p.IsDeleted = 0
        UNION ALL
        SELECT 1, p.PageId, N'Body', p.BodyHtmlEn
        FROM lms.Page p WHERE p.CourseVersionId = @CourseVersionId AND p.IsDeleted = 0
        UNION ALL
        SELECT 2, m.CourseModuleId, N'Title', m.TitleEn
        FROM lms.CourseModule m WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0
        UNION ALL
        SELECT 3, i.ModuleItemId, N'Title', i.TitleEn
        FROM lms.ModuleItem i
        JOIN lms.CourseModule m ON m.CourseModuleId = i.CourseModuleId
        WHERE m.CourseVersionId = @CourseVersionId AND i.IsDeleted = 0
    )
    SELECT  COUNT(*) AS TotalFields
          , SUM(CASE WHEN Existing IS NOT NULL AND LEN(Existing) > 0 THEN 1 ELSE 0 END) AS TranslatedFields
          , CAST(100.0 * SUM(CASE WHEN Existing IS NOT NULL AND LEN(Existing) > 0 THEN 1 ELSE 0 END)
                 / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS CompletionPercent
    FROM Translatable;

    SELECT LocaleCode, TranslationStatus, CompletionPercent, IsAvailable
    FROM lms.CourseVersionLocale WHERE CourseVersionId = @CourseVersionId;
    RETURN 0;
END;
GO

/* =====================================================================
   Blueprint (cursos maestros replicados por sitio)
   ===================================================================== */
CREATE OR ALTER PROCEDURE lms.usp_Blueprint_Link
      @ActorUserId INT, @BlueprintCourseId INT, @DerivedCourseId INT
    , @SyncContent BIT = 1, @SyncSettings BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'course.blueprint') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    IF @BlueprintCourseId = @DerivedCourseId
        THROW 50212, 'Un curso no puede ser blueprint de si mismo.', 1;

    INSERT INTO lms.CourseBlueprintLink (BlueprintCourseId, DerivedCourseId, SyncContent, SyncSettings)
    VALUES (@BlueprintCourseId, @DerivedCourseId, @SyncContent, @SyncSettings);
    RETURN 0;
END;
GO

/* Fase 3. Empuja la version publicada del blueprint a los derivados que
   tengan SyncContent = 1, creando un draft en cada uno. */
CREATE OR ALTER PROCEDURE lms.usp_Blueprint_PushUpdates
      @ActorUserId INT, @BlueprintCourseId INT, @AutoPublish BIT = 0
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'course.blueprint') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        DECLARE @SourceVersionId INT;
        SELECT @SourceVersionId = CurrentVersionId FROM lms.Course WHERE CourseId = @BlueprintCourseId;
        IF @SourceVersionId IS NULL THROW 50213, 'El blueprint no tiene una version publicada.', 1;

        DECLARE @DerivedCourseId INT, @NewVersionId INT;
        DECLARE derived CURSOR LOCAL FAST_FORWARD FOR
            SELECT DerivedCourseId FROM lms.CourseBlueprintLink
            WHERE BlueprintCourseId = @BlueprintCourseId AND SyncContent = 1;

        OPEN derived;
        FETCH NEXT FROM derived INTO @DerivedCourseId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                EXEC lms.usp_CourseVersion_CreateDraft
                      @ActorUserId = @ActorUserId, @CourseId = @DerivedCourseId
                    , @SourceVersionId = @SourceVersionId
                    , @ChangeSummary = N'Sincronizacion desde blueprint.'
                    , @NewVersionId = @NewVersionId OUTPUT;

                UPDATE lms.CourseBlueprintLink
                SET LastSyncedAtUtc = SYSUTCDATETIME(), LastSyncedVersionId = @SourceVersionId
                WHERE BlueprintCourseId = @BlueprintCourseId AND DerivedCourseId = @DerivedCourseId;
            END TRY
            BEGIN CATCH
                /* Un derivado con draft abierto no detiene al resto. */
                EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Blueprint_PushUpdates', @ActorUserId = @ActorUserId;
            END CATCH;
            FETCH NEXT FROM derived INTO @DerivedCourseId;
        END;
        CLOSE derived; DEALLOCATE derived;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Blueprint_PushUpdates', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

PRINT '=== 12_procs_catalog_content.sql completado ===';
GO

/* ############################################################################
   ARCHIVO: database/13_procs_delivery_progress.sql
   ############################################################################ */
/* =====================================================================
   Classroom - LMS by Airlink
   13_procs_delivery_progress.sql
   Esquema: dlv (inscripciones, progreso, cohortes, ILT presencial)

   GAP-04: la sesion presencial es ciudadano de primera clase. ~70% del
   entrenamiento real de Airlink pasa en el piso con un instructor, no
   frente a una pantalla. Todo lo que aplica a un curso online aplica
   igual a una sesion ILT: evidencia, firma, y credito de competencia.

   Codigos de error de este archivo: 50300-50399
   ===================================================================== */

USE AIRLINK_KMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 13_procs_delivery_progress.sql iniciado ===';
GO

/* =====================================================================
   dlv.usp_Enrollment_Create

   Congela CourseVersionId al inscribir. Si el curso se republica manana,
   este operador sigue viendo lo que se le asigno hoy.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Create
      @ActorUserId    INT
    , @EmployeeId     INT
    , @CourseId       INT
    , @Source         TINYINT          = 2
    , @SourceRequirementId INT         = NULL
    , @CohortId       INT              = NULL
    , @ProgramId      INT              = NULL
    , @DueAtUtc       DATETIME2(3)     = NULL
    , @AllowDuplicate BIT              = 0
    , @IdempotencyKey UNIQUEIDENTIFIER = NULL
    , @EnrollmentId   INT              = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------
       Proposito : inscribir un empleado en la version vigente de un curso.
       Retorna   : EnrollmentId (OUTPUT) + fila de la inscripcion.
       Errores   : 50301 curso sin version publicada
                   50302 ya existe inscripcion activa
                   50303 empleado inactivo
                   50304 prerrequisito de programa no cumplido
       --------------------------------------------------------------- */

    BEGIN TRY
        IF @ActorUserId IS NULL THROW 50010, 'ActorUserId es requerido.', 1;

        /* Auto-inscripcion permitida solo si el curso lo habilita. */
        DECLARE @IsSelf BIT = CASE WHEN EXISTS (SELECT 1 FROM sec.[User] u
                                                WHERE u.UserId = @ActorUserId AND u.EmployeeId = @EmployeeId)
                                   THEN 1 ELSE 0 END;

        IF @IsSelf = 0 AND sec.fn_UserHasPermission(@ActorUserId, N'enrollment.assign') = 0
            THROW 50002, 'El usuario no tiene permiso para inscribir a otros empleados.', 1;

        IF @IsSelf = 1 AND @Source = 3
           AND NOT EXISTS (SELECT 1 FROM lms.Course WHERE CourseId = @CourseId AND AllowSelfEnrollment = 1)
            THROW 50002, 'Este curso no admite auto-inscripcion.', 1;

        IF @IdempotencyKey IS NOT NULL
           AND EXISTS (SELECT 1 FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey)
        BEGIN
            SELECT @EnrollmentId = ResultEntityId FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey;
            RETURN 0;
        END;

        IF NOT EXISTS (SELECT 1 FROM org.Employee WHERE EmployeeId = @EmployeeId AND IsActive = 1)
            THROW 50303, 'El empleado no existe o esta inactivo.', 1;

        DECLARE @CourseVersionId INT, @PreviousEnrollmentId INT, @AttemptNumber TINYINT = 1;

        SELECT @CourseVersionId = CurrentVersionId FROM lms.Course
        WHERE CourseId = @CourseId AND IsDeleted = 0 AND [Status] = 2;

        IF @CourseVersionId IS NULL
            THROW 50301, 'El curso no tiene una version publicada vigente.', 1;

        IF @AllowDuplicate = 0
           AND EXISTS (SELECT 1 FROM dlv.Enrollment
                       WHERE EmployeeId = @EmployeeId AND CourseId = @CourseId AND [Status] IN (1,2))
            THROW 50302, 'El empleado ya tiene una inscripcion activa en este curso.', 1;

        /* Reintento: nunca se sobreescribe la inscripcion anterior. */
        SELECT TOP (1) @PreviousEnrollmentId = EnrollmentId, @AttemptNumber = AttemptNumber + 1
        FROM dlv.Enrollment
        WHERE EmployeeId = @EmployeeId AND CourseId = @CourseId
        ORDER BY EnrollmentId DESC;

        SET @AttemptNumber = ISNULL(@AttemptNumber, 1);

        /* Prerrequisitos de programa con secuencia forzada. */
        IF @ProgramId IS NOT NULL
           AND EXISTS (SELECT 1 FROM lms.Program WHERE ProgramId = @ProgramId AND EnforceSequence = 1)
           AND EXISTS (
                SELECT 1
                FROM lms.ProgramCourse pc
                JOIN lms.ProgramCourse prereq ON prereq.ProgramCourseId = pc.PrerequisiteProgramCourseId
                WHERE pc.ProgramId = @ProgramId AND pc.CourseId = @CourseId
                  AND NOT EXISTS (
                        SELECT 1 FROM dlv.Enrollment e
                        WHERE e.EmployeeId = @EmployeeId AND e.CourseId = prereq.CourseId
                          AND e.[Status] = 3 AND e.IsPassed = 1))
            THROW 50304, 'Falta completar el curso prerrequisito del programa.', 1;

        BEGIN TRANSACTION;

        INSERT INTO dlv.Enrollment (EmployeeId, CourseId, CourseVersionId, CohortId, ProgramId
                                  , [Source], SourceRequirementId, [Status], AttemptNumber
                                  , AssignedByUserId, DueAtUtc, PreviousEnrollmentId)
        VALUES (@EmployeeId, @CourseId, @CourseVersionId, @CohortId, @ProgramId
              , @Source, @SourceRequirementId, 1, @AttemptNumber
              , @ActorUserId, @DueAtUtc, @PreviousEnrollmentId);

        SET @EnrollmentId = SCOPE_IDENTITY();

        /* Sembrar el progreso: modulos y items del arbol congelado.
           Hacerlo ahora evita nulls y hace baratos los reportes. */
        INSERT INTO dlv.ModuleProgress (EnrollmentId, CourseModuleId, [Status], ItemsTotal, UnlockedAtUtc)
        SELECT  @EnrollmentId
              , m.CourseModuleId
              , CASE WHEN m.PrerequisiteModuleId IS NULL THEN 2 ELSE 1 END   -- 2=Available 1=Locked
              , (SELECT COUNT(*) FROM lms.ModuleItem i
                 WHERE i.CourseModuleId = m.CourseModuleId AND i.IsDeleted = 0 AND i.IsRequiredForCompletion = 1)
              , CASE WHEN m.PrerequisiteModuleId IS NULL THEN SYSUTCDATETIME() ELSE NULL END
        FROM lms.CourseModule m
        WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0;

        INSERT INTO dlv.ItemProgress (EnrollmentId, ModuleItemId, [Status])
        SELECT @EnrollmentId, i.ModuleItemId, 1
        FROM lms.ModuleItem i
        JOIN lms.CourseModule m ON m.CourseModuleId = i.CourseModuleId
        WHERE m.CourseVersionId = @CourseVersionId AND m.IsDeleted = 0 AND i.IsDeleted = 0;

        IF @IdempotencyKey IS NOT NULL
            INSERT INTO aud.IdempotencyKey (IdempotencyKey, OperationName, ActorUserId, ResultEntityId)
            VALUES (@IdempotencyKey, N'dlv.usp_Enrollment_Create', @ActorUserId, @EnrollmentId);

        EXEC aud.usp_Event_Log
              @EventType   = N'Enrollment.Created'
            , @EntityType  = N'Enrollment'
            , @EntityId    = @EnrollmentId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Summary     = N'Inscripcion creada.';

        COMMIT TRANSACTION;

        EXEC ops.usp_Notification_Enqueue
              @TemplateCode = N'Enrollment.Assigned'
            , @RecipientEmployeeId = @EmployeeId
            , @Priority = 2
            , @DedupeKey = NULL;

        SELECT e.EnrollmentId, e.PublicId, e.EmployeeId, e.CourseId, e.CourseVersionId
             , e.[Status], e.AttemptNumber, e.DueAtUtc, e.AssignedAtUtc
        FROM dlv.Enrollment e WHERE e.EnrollmentId = @EnrollmentId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Progress_CompleteItem

   Marca un item como completado, recalcula el modulo, desbloquea el
   siguiente si aplica, recalcula la inscripcion y — si todo cerro —
   dispara la evaluacion de certificacion.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Progress_CompleteItem
      @ActorUserId      INT
    , @EnrollmentId     INT
    , @ModuleItemId     INT
    , @ScorePercent     DECIMAL(5,2) = NULL
    , @TimeSpentSeconds INT          = NULL
    , @VideoWatchedPercent DECIMAL(5,2) = NULL
    , @IdempotencyKey   UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50310 item bloqueado por secuencia
                50311 tiempo minimo no cumplido (anti-skip)
                50312 porcentaje de video insuficiente
                50313 puntaje bajo el minimo del item                    */
    BEGIN TRY
        DECLARE @EmployeeId INT, @CourseVersionId INT, @CourseId INT
              , @CourseModuleId INT, @EnrollmentStatus TINYINT
              , @EnforceSequence BIT, @EnforceMinimumTime BIT
              , @MinimumSeconds INT, @MinimumScore DECIMAL(5,2)
              , @ItemRequired BIT, @ModuleStatus TINYINT
              , @RequiredWatch DECIMAL(5,2), @ItemType TINYINT, @TargetId INT;

        SELECT  @EmployeeId = e.EmployeeId, @CourseVersionId = e.CourseVersionId
              , @CourseId = e.CourseId, @EnrollmentStatus = e.[Status]
              , @EnforceSequence = v.EnforceSequence, @EnforceMinimumTime = v.EnforceMinimumTime
        FROM dlv.Enrollment e
        JOIN lms.CourseVersion v ON v.CourseVersionId = e.CourseVersionId
        WHERE e.EnrollmentId = @EnrollmentId;

        IF @EmployeeId IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;
        IF @EnrollmentStatus NOT IN (1,2) THROW 50305, 'La inscripcion no esta activa.', 1;

        IF NOT EXISTS (SELECT 1 FROM sec.[User] u WHERE u.UserId = @ActorUserId AND u.EmployeeId = @EmployeeId)
           AND sec.fn_UserHasPermission(@ActorUserId, N'progress.override') = 0
            THROW 50002, 'El usuario no tiene permiso para modificar este progreso.', 1;

        SELECT  @CourseModuleId = i.CourseModuleId, @MinimumSeconds = i.MinimumSeconds
              , @MinimumScore = i.MinimumScore, @ItemRequired = i.IsRequiredForCompletion
              , @ItemType = i.ItemType, @TargetId = i.TargetId
        FROM lms.ModuleItem i WHERE i.ModuleItemId = @ModuleItemId;

        IF @CourseModuleId IS NULL THROW 50001, 'Item no encontrado.', 1;

        SELECT @ModuleStatus = mp.[Status]
        FROM dlv.ModuleProgress mp
        WHERE mp.EnrollmentId = @EnrollmentId AND mp.CourseModuleId = @CourseModuleId;

        IF @EnforceSequence = 1 AND @ModuleStatus = 1
            THROW 50310, 'El modulo esta bloqueado. Complete el modulo prerrequisito.', 1;

        IF @EnforceMinimumTime = 1 AND @MinimumSeconds IS NOT NULL
           AND ISNULL(@TimeSpentSeconds, 0) < @MinimumSeconds
            THROW 50311, 'No se cumplio el tiempo minimo de lectura del contenido.', 1;

        IF @ItemType = 3 AND @TargetId IS NOT NULL   -- 3 = Video
        BEGIN
            SELECT @RequiredWatch = RequiredWatchPercent FROM lms.VideoAsset WHERE VideoAssetId = @TargetId;
            IF @RequiredWatch IS NOT NULL AND ISNULL(@VideoWatchedPercent, 0) < @RequiredWatch
                THROW 50312, 'No se alcanzo el porcentaje minimo de reproduccion del video.', 1;
        END;

        IF @MinimumScore IS NOT NULL AND ISNULL(@ScorePercent, 0) < @MinimumScore
            THROW 50313, 'El puntaje obtenido esta por debajo del minimo requerido para este item.', 1;

        BEGIN TRANSACTION;

        UPDATE dlv.ItemProgress
        SET  [Status] = 3
           , ScorePercent = COALESCE(@ScorePercent, ScorePercent)
           , TimeSpentSeconds = TimeSpentSeconds + ISNULL(@TimeSpentSeconds, 0)
           , VideoWatchedPercent = COALESCE(@VideoWatchedPercent, VideoWatchedPercent)
           , ViewCount = ViewCount + 1
           , FirstAccessedAtUtc = ISNULL(FirstAccessedAtUtc, SYSUTCDATETIME())
           , LastAccessedAtUtc = SYSUTCDATETIME()
           , CompletedAtUtc = ISNULL(CompletedAtUtc, SYSUTCDATETIME())
        WHERE EnrollmentId = @EnrollmentId AND ModuleItemId = @ModuleItemId;

        IF @@ROWCOUNT = 0
            INSERT INTO dlv.ItemProgress (EnrollmentId, ModuleItemId, [Status], ScorePercent
                                        , TimeSpentSeconds, VideoWatchedPercent, ViewCount
                                        , FirstAccessedAtUtc, LastAccessedAtUtc, CompletedAtUtc)
            VALUES (@EnrollmentId, @ModuleItemId, 3, @ScorePercent, ISNULL(@TimeSpentSeconds,0)
                  , @VideoWatchedPercent, 1, SYSUTCDATETIME(), SYSUTCDATETIME(), SYSUTCDATETIME());

        /* Recalcular el modulo */
        DECLARE @ItemsTotal INT, @ItemsDone INT;

        SELECT  @ItemsTotal = COUNT(*)
              , @ItemsDone  = SUM(CASE WHEN ip.[Status] = 3 THEN 1 ELSE 0 END)
        FROM lms.ModuleItem i
        LEFT JOIN dlv.ItemProgress ip ON ip.ModuleItemId = i.ModuleItemId AND ip.EnrollmentId = @EnrollmentId
        WHERE i.CourseModuleId = @CourseModuleId AND i.IsDeleted = 0 AND i.IsRequiredForCompletion = 1;

        UPDATE dlv.ModuleProgress
        SET  ItemsTotal = @ItemsTotal
           , ItemsCompleted = ISNULL(@ItemsDone, 0)
           , ProgressPercent = CAST(100.0 * ISNULL(@ItemsDone,0) / NULLIF(@ItemsTotal, 0) AS DECIMAL(5,2))
           , [Status] = CASE WHEN @ItemsTotal > 0 AND ISNULL(@ItemsDone,0) >= @ItemsTotal THEN 4 ELSE 3 END
           , CompletedAtUtc = CASE WHEN @ItemsTotal > 0 AND ISNULL(@ItemsDone,0) >= @ItemsTotal
                                   THEN ISNULL(CompletedAtUtc, SYSUTCDATETIME()) ELSE NULL END
           , ModifiedAtUtc = SYSUTCDATETIME()
        WHERE EnrollmentId = @EnrollmentId AND CourseModuleId = @CourseModuleId;

        /* Desbloquear los modulos que tenian este como prerrequisito */
        IF @ItemsTotal > 0 AND ISNULL(@ItemsDone,0) >= @ItemsTotal
            UPDATE mp
            SET mp.[Status] = 2, mp.UnlockedAtUtc = SYSUTCDATETIME(), mp.ModifiedAtUtc = SYSUTCDATETIME()
            FROM dlv.ModuleProgress mp
            JOIN lms.CourseModule m ON m.CourseModuleId = mp.CourseModuleId
            WHERE mp.EnrollmentId = @EnrollmentId
              AND m.PrerequisiteModuleId = @CourseModuleId
              AND mp.[Status] = 1;

        UPDATE dlv.Enrollment
        SET  [Status] = CASE WHEN [Status] = 1 THEN 2 ELSE [Status] END
           , StartedAtUtc = ISNULL(StartedAtUtc, SYSUTCDATETIME())
           , LastAccessedAtUtc = SYSUTCDATETIME()
           , LastAccessedItemId = @ModuleItemId
           , TotalTimeSpentSeconds = TotalTimeSpentSeconds + ISNULL(@TimeSpentSeconds, 0)
           , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EnrollmentId = @EnrollmentId;

        COMMIT TRANSACTION;

        EXEC dlv.usp_Progress_Recalculate @ActorUserId = @ActorUserId, @EnrollmentId = @EnrollmentId;

        SELECT ProgressPercent, [Status] FROM dlv.Enrollment WHERE EnrollmentId = @EnrollmentId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Progress_CompleteItem', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Progress_Recalculate
   Recalcula el porcentaje total y cierra la inscripcion si corresponde.
   Idempotente: se puede llamar cuantas veces sea.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Progress_Recalculate
      @ActorUserId  INT
    , @EnrollmentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @Total INT, @Done INT, @Percent DECIMAL(5,2)
              , @PassingScore DECIMAL(5,2), @AvgScore DECIMAL(5,2)
              , @CurrentStatus TINYINT, @EmployeeId INT;

        SELECT @CurrentStatus = e.[Status], @PassingScore = v.PassingScore, @EmployeeId = e.EmployeeId
        FROM dlv.Enrollment e
        JOIN lms.CourseVersion v ON v.CourseVersionId = e.CourseVersionId
        WHERE e.EnrollmentId = @EnrollmentId;

        IF @CurrentStatus IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;
        IF @CurrentStatus NOT IN (1,2) RETURN 0;   -- ya cerrada, nada que hacer

        SELECT  @Total = COUNT(*)
              , @Done  = SUM(CASE WHEN ip.[Status] = 3 THEN 1 ELSE 0 END)
        FROM lms.ModuleItem i
        JOIN lms.CourseModule m ON m.CourseModuleId = i.CourseModuleId
        JOIN dlv.Enrollment e   ON e.CourseVersionId = m.CourseVersionId AND e.EnrollmentId = @EnrollmentId
        LEFT JOIN dlv.ItemProgress ip ON ip.ModuleItemId = i.ModuleItemId AND ip.EnrollmentId = @EnrollmentId
        WHERE i.IsDeleted = 0 AND m.IsDeleted = 0 AND i.IsRequiredForCompletion = 1;

        SET @Percent = CAST(100.0 * ISNULL(@Done, 0) / NULLIF(@Total, 0) AS DECIMAL(5,2));

        /* Puntaje del curso: promedio ponderado de los items con puntaje.
           Si no hay ninguno (curso solo de lectura), queda NULL y el paso
           lo define la completitud. */
        SELECT @AvgScore = CAST(AVG(ip.ScorePercent) AS DECIMAL(5,2))
        FROM dlv.ItemProgress ip
        WHERE ip.EnrollmentId = @EnrollmentId AND ip.ScorePercent IS NOT NULL;

        BEGIN TRANSACTION;

        UPDATE dlv.Enrollment
        SET  ProgressPercent = ISNULL(@Percent, 0)
           , ScorePercent    = @AvgScore
           , ModifiedAtUtc   = SYSUTCDATETIME()
        WHERE EnrollmentId = @EnrollmentId;

        COMMIT TRANSACTION;

        /* Cierre automatico */
        IF @Total > 0 AND ISNULL(@Done,0) >= @Total
        BEGIN
            DECLARE @IsPassed BIT =
                CASE WHEN @AvgScore IS NULL THEN 1
                     WHEN @AvgScore >= @PassingScore THEN 1
                     ELSE 0 END;

            IF @IsPassed = 1
                EXEC dlv.usp_Enrollment_Complete @ActorUserId = @ActorUserId, @EnrollmentId = @EnrollmentId;
            ELSE
                EXEC dlv.usp_Enrollment_Fail @ActorUserId = @ActorUserId, @EnrollmentId = @EnrollmentId
                   , @Reason = N'Puntaje final por debajo del minimo aprobatorio.';
        END;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Progress_Recalculate', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Enrollment_Complete
   Cierra la inscripcion y le pasa la bola al motor de compliance.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Complete
      @ActorUserId  INT
    , @EnrollmentId INT
    , @ScorePercent DECIMAL(5,2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @EmployeeId INT, @CourseId INT, @Status TINYINT;

        SELECT @EmployeeId = EmployeeId, @CourseId = CourseId, @Status = [Status]
        FROM dlv.Enrollment WHERE EnrollmentId = @EnrollmentId;

        IF @EmployeeId IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;
        IF @Status = 3 RETURN 0;   -- ya completada, idempotente

        BEGIN TRANSACTION;

        UPDATE dlv.Enrollment
        SET  [Status] = 3
           , IsPassed = 1
           , ProgressPercent = 100.00
           , ScorePercent = COALESCE(@ScorePercent, ScorePercent)
           , CompletedAtUtc = SYSUTCDATETIME()
           , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EnrollmentId = @EnrollmentId;

        EXEC aud.usp_Event_Log
              @EventType   = N'Enrollment.Completed'
            , @EntityType  = N'Enrollment'
            , @EntityId    = @EnrollmentId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Inscripcion completada satisfactoriamente.';

        COMMIT TRANSACTION;

        /* Aqui es donde el LMS se gana el sueldo: completar un curso puede
           cerrar un requisito de competencia y emitir certificacion. */
        EXEC comp.usp_Certification_EvaluateAndIssue
              @ActorUserId = @ActorUserId
            , @EmployeeId  = @EmployeeId
            , @TriggerType = 1                 -- 1=EnrollmentCompleted
            , @TriggerId   = @EnrollmentId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_Complete', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Fail
      @ActorUserId INT, @EnrollmentId INT, @Reason NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @EmployeeId INT, @CourseId INT, @Attempt TINYINT, @MaxAttempts TINYINT;
        SELECT @EmployeeId = e.EmployeeId, @CourseId = e.CourseId
             , @Attempt = e.AttemptNumber, @MaxAttempts = v.MaxAttempts
        FROM dlv.Enrollment e JOIN lms.CourseVersion v ON v.CourseVersionId = e.CourseVersionId
        WHERE e.EnrollmentId = @EnrollmentId;

        IF @EmployeeId IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;

        BEGIN TRANSACTION;
        UPDATE dlv.Enrollment
        SET [Status] = 4, IsPassed = 0, CompletedAtUtc = SYSUTCDATETIME()
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EnrollmentId = @EnrollmentId;

        EXEC aud.usp_Event_Log @EventType = N'Enrollment.Failed', @EntityType = N'Enrollment'
           , @EntityId = @EnrollmentId, @EmployeeId = @EmployeeId, @ActorUserId = @ActorUserId
           , @Severity = 3, @Summary = N'Inscripcion no aprobada.';
        COMMIT TRANSACTION;

        /* Reintento automatico mientras queden intentos. Si se agotaron,
           el supervisor recibe aviso para intervencion presencial. */
        IF @Attempt < @MaxAttempts
        BEGIN
            DECLARE @NewEnrollmentId INT;
            EXEC dlv.usp_Enrollment_Create
                  @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId, @CourseId = @CourseId
                , @Source = 2, @AllowDuplicate = 1, @EnrollmentId = @NewEnrollmentId OUTPUT;
        END
        ELSE
            EXEC ops.usp_Notification_Enqueue
                  @TemplateCode = N'Enrollment.AttemptsExhausted'
                , @RecipientEmployeeId = @EmployeeId
                , @Priority = 1
                , @NotifySupervisor = 1;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_Fail', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Enrollment_CreateFromRequirement
   Llamado por el motor de gaps: inscribe al empleado en el satisfactor
   mandatorio de tipo Course del requisito.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_CreateFromRequirement
      @ActorUserId   INT
    , @EmployeeId    INT
    , @RequirementId INT
    , @DueInDays     INT = 30
    , @EnrollmentId  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @CourseId INT;

        /* Se toma el satisfactor mandatorio de menor SortOrder. Si el
           requisito solo se satisface con evaluacion practica o firma de
           documento, no hay curso que inscribir y se sale limpio. */
        SELECT TOP (1) @CourseId = rs.SatisfierId
        FROM comp.RequirementSatisfier rs
        WHERE rs.RequirementId = @RequirementId
          AND rs.SatisfierType = 1
          AND rs.IsMandatory = 1
          AND rs.SatisfierId IS NOT NULL
        ORDER BY rs.SortOrder, rs.RequirementSatisfierId;

        IF @CourseId IS NULL RETURN 0;

        IF EXISTS (SELECT 1 FROM dlv.Enrollment
                   WHERE EmployeeId = @EmployeeId AND CourseId = @CourseId AND [Status] IN (1,2))
            RETURN 0;   -- ya esta inscrito, no duplicamos

        EXEC dlv.usp_Enrollment_Create
              @ActorUserId = @ActorUserId
            , @EmployeeId  = @EmployeeId
            , @CourseId    = @CourseId
            , @Source      = 1                       -- CompetencyRequired
            , @SourceRequirementId = @RequirementId
            , @DueAtUtc    = NULL
            , @EnrollmentId = @EnrollmentId OUTPUT;

        IF @EnrollmentId IS NOT NULL AND @DueInDays IS NOT NULL
            UPDATE dlv.Enrollment
            SET DueAtUtc = DATEADD(DAY, @DueInDays, SYSUTCDATETIME())
            WHERE EnrollmentId = @EnrollmentId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_CreateFromRequirement', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Enrollment_CreateBulk  -- asignacion masiva por TVP
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_CreateBulk
      @ActorUserId INT
    , @Requests    dlv.EnrollmentRequestType READONLY
    , @Source      TINYINT = 4
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Fila mala no tumba el lote. Se devuelve un resultset con el
       resultado por fila para que el usuario vea que fallo y por que. */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'enrollment.assign') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        DECLARE @Results TABLE (
              EmployeeCode NVARCHAR(30), CourseCode NVARCHAR(40)
            , EnrollmentId INT NULL, IsSuccess BIT, [Message] NVARCHAR(400));

        DECLARE @EmployeeCode NVARCHAR(30), @CourseCode NVARCHAR(40)
              , @CohortId INT, @DueAtUtc DATETIME2(3)
              , @EmployeeId INT, @CourseId INT, @NewId INT;

        DECLARE bulk_cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT EmployeeCode, CourseCode, CohortId, DueAtUtc FROM @Requests;

        OPEN bulk_cur;
        FETCH NEXT FROM bulk_cur INTO @EmployeeCode, @CourseCode, @CohortId, @DueAtUtc;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @NewId = NULL;
            BEGIN TRY
                SELECT @EmployeeId = EmployeeId FROM org.Employee WHERE EmployeeCode = @EmployeeCode AND IsActive = 1;
                SELECT @CourseId   = CourseId   FROM lms.Course   WHERE CourseCode   = @CourseCode   AND IsDeleted = 0;

                IF @EmployeeId IS NULL THROW 50303, 'Empleado no encontrado o inactivo.', 1;
                IF @CourseId   IS NULL THROW 50001, 'Curso no encontrado.', 1;

                EXEC dlv.usp_Enrollment_Create
                      @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId, @CourseId = @CourseId
                    , @Source = @Source, @CohortId = @CohortId, @DueAtUtc = @DueAtUtc
                    , @EnrollmentId = @NewId OUTPUT;

                INSERT INTO @Results VALUES (@EmployeeCode, @CourseCode, @NewId, 1, N'OK');
            END TRY
            BEGIN CATCH
                INSERT INTO @Results VALUES (@EmployeeCode, @CourseCode, NULL, 0, LEFT(ERROR_MESSAGE(), 400));
            END CATCH;
            FETCH NEXT FROM bulk_cur INTO @EmployeeCode, @CourseCode, @CohortId, @DueAtUtc;
        END;
        CLOSE bulk_cur; DEALLOCATE bulk_cur;

        SELECT * FROM @Results;
        SELECT SUM(CAST(IsSuccess AS INT)) AS Succeeded
             , SUM(CASE WHEN IsSuccess = 0 THEN 1 ELSE 0 END) AS Failed
        FROM @Results;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_CreateBulk', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Sesiones presenciales (ILT) - GAP-04
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Session_Create
      @ActorUserId INT, @CourseId INT, @SessionCode NVARCHAR(40)
    , @TitleEs NVARCHAR(250), @TitleEn NVARCHAR(250) = NULL
    , @InstructorEmployeeId INT
    , @ScheduledStartUtc DATETIME2(3), @ScheduledEndUtc DATETIME2(3)
    , @LocationType TINYINT = 1, @LocationName NVARCHAR(200) = NULL
    , @SiteId INT = NULL, @AreaId INT = NULL, @StationId INT = NULL
    , @LocaleCode NVARCHAR(10) = N'es-DO'
    , @MinParticipants INT = NULL, @MaxParticipants INT = NULL
    , @RequiredMinutes INT = NULL, @AllowWaitlist BIT = 1
    , @TrainingSessionId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* Errores: 50320 instructor no calificado para el curso
                50321 fechas invalidas
                50322 conflicto de agenda del instructor                 */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'session.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF @ScheduledEndUtc <= @ScheduledStartUtc
            THROW 50321, 'La hora de fin debe ser posterior a la de inicio.', 1;

        DECLARE @CourseVersionId INT;
        SELECT @CourseVersionId = CurrentVersionId FROM lms.Course WHERE CourseId = @CourseId;
        IF @CourseVersionId IS NULL THROW 50301, 'El curso no tiene una version publicada vigente.', 1;

        /* GAP-05: el que evalua tiene que estar calificado para evaluar.
           Un instructor sin EvaluatorQualification vigente no abre sesion. */
        IF NOT EXISTS (
            SELECT 1 FROM comp.EvaluatorQualification eq
            WHERE eq.EmployeeId = @InstructorEmployeeId
              AND eq.IsActive = 1 AND eq.CanTrain = 1
              AND eq.RevokedAtUtc IS NULL
              AND (eq.ExpiresAtUtc IS NULL OR eq.ExpiresAtUtc > SYSUTCDATETIME())
              /* si el curso satisface una competencia concreta, la
                 calificacion del instructor debe cubrir esa competencia */
              AND (NOT EXISTS (SELECT 1 FROM comp.RequirementSatisfier rs
                               JOIN comp.CompetencyRequirement r ON r.RequirementId = rs.RequirementId
                               WHERE rs.SatisfierType = 1 AND rs.SatisfierId = @CourseId)
                   OR eq.CompetencyId IN (SELECT r.CompetencyId FROM comp.RequirementSatisfier rs
                                          JOIN comp.CompetencyRequirement r ON r.RequirementId = rs.RequirementId
                                          WHERE rs.SatisfierType = 1 AND rs.SatisfierId = @CourseId)))
           AND sec.fn_UserHasPermission(@ActorUserId, N'session.override_qualification') = 0
            THROW 50320, 'El instructor no tiene calificacion vigente para impartir este curso.', 1;

        IF EXISTS (
            SELECT 1 FROM dlv.TrainingSession s
            WHERE s.InstructorEmployeeId = @InstructorEmployeeId
              AND s.[Status] NOT IN (6)
              AND s.IsDeleted = 0
              AND s.ScheduledStartUtc < @ScheduledEndUtc
              AND s.ScheduledEndUtc   > @ScheduledStartUtc)
            THROW 50322, 'El instructor ya tiene una sesion agendada en ese horario.', 1;

        INSERT INTO dlv.TrainingSession (CourseId, CourseVersionId, SessionCode, TitleEs, TitleEn
                                       , InstructorEmployeeId, LocationType, LocationName
                                       , SiteId, AreaId, StationId, LocaleCode
                                       , ScheduledStartUtc, ScheduledEndUtc, RequiredMinutes
                                       , MinParticipants, MaxParticipants, AllowWaitlist
                                       , [Status], CreatedByUserId)
        VALUES (@CourseId, @CourseVersionId, @SessionCode, @TitleEs, @TitleEn
              , @InstructorEmployeeId, @LocationType, @LocationName
              , @SiteId, @AreaId, @StationId, @LocaleCode
              , @ScheduledStartUtc, @ScheduledEndUtc, @RequiredMinutes
              , @MinParticipants, @MaxParticipants, @AllowWaitlist
              , 2, @ActorUserId);

        SET @TrainingSessionId = SCOPE_IDENTITY();
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Session_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Attendance_CheckIn
      @ActorUserId INT, @TrainingSessionId INT
    , @EmployeeCode NVARCHAR(30) = NULL, @EmployeeId INT = NULL
    , @CheckInMethod TINYINT = 2, @DeviceId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;

    /* Errores: 50323 sesion no esta en curso, 50324 empleado no inscrito */
    BEGIN TRY
        SELECT @EmployeeId = COALESCE(@EmployeeId, e.EmployeeId)
        FROM org.Employee e WHERE @EmployeeCode IS NOT NULL AND e.EmployeeCode = @EmployeeCode;

        IF @EmployeeId IS NULL THROW 50303, 'Empleado no encontrado.', 1;

        DECLARE @Status TINYINT, @CourseId INT;
        SELECT @Status = [Status], @CourseId = CourseId
        FROM dlv.TrainingSession WHERE TrainingSessionId = @TrainingSessionId;

        IF @Status IS NULL THROW 50001, 'Sesion no encontrada.', 1;
        IF @Status NOT IN (2,3,4) THROW 50323, 'La sesion no admite registro de asistencia en este momento.', 1;

        BEGIN TRANSACTION;

        /* Marcar la sesion como en curso al primer check-in. */
        UPDATE dlv.TrainingSession
        SET [Status] = 4, ActualStartUtc = ISNULL(ActualStartUtc, SYSUTCDATETIME())
        WHERE TrainingSessionId = @TrainingSessionId AND [Status] <> 4;

        MERGE dlv.SessionAttendance AS tgt
        USING (SELECT @TrainingSessionId AS SessionId, @EmployeeId AS EmployeeId) AS src
        ON tgt.TrainingSessionId = src.SessionId AND tgt.EmployeeId = src.EmployeeId
        WHEN MATCHED THEN UPDATE SET
              CheckInAtUtc = ISNULL(tgt.CheckInAtUtc, SYSUTCDATETIME())
            , AttendanceStatus = CASE WHEN tgt.AttendanceStatus = 4 THEN 1 ELSE tgt.AttendanceStatus END
            , CheckInMethod = @CheckInMethod, DeviceId = @DeviceId
        WHEN NOT MATCHED THEN INSERT
              (TrainingSessionId, EmployeeId, AttendanceStatus, CheckInAtUtc, CheckInMethod, DeviceId, RecordedByUserId)
            VALUES (@TrainingSessionId, @EmployeeId, 1, SYSUTCDATETIME(), @CheckInMethod, @DeviceId, @ActorUserId);

        COMMIT TRANSACTION;

        SELECT e.EmployeeCode, e.FullName, a.AttendanceStatus, a.CheckInAtUtc
        FROM dlv.SessionAttendance a
        JOIN org.Employee e ON e.EmployeeId = a.EmployeeId
        WHERE a.TrainingSessionId = @TrainingSessionId AND a.EmployeeId = @EmployeeId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Attendance_CheckIn', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   dlv.usp_Session_Close

   El instructor cierra la sesion y firma el roster. Esa firma es la
   evidencia primaria de que la capacitacion presencial ocurrio: es lo
   que se le ensena al auditor. Al cerrar:
     - se calculan minutos asistidos y se marca Present/Late/Absent,
     - se crea evidencia de inscripcion por participante,
     - se dispara la evaluacion de certificacion de cada uno.
   ===================================================================== */
CREATE OR ALTER PROCEDURE dlv.usp_Session_Close
      @ActorUserId       INT
    , @TrainingSessionId INT
    , @InstructorNotes   NVARCHAR(MAX) = NULL
    , @PayloadCanonical  NVARCHAR(MAX) = NULL
    , @AuthMethod        TINYINT       = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50325 sesion ya cerrada
                50326 quien cierra no es el instructor de la sesion       */
    BEGIN TRY
        DECLARE @Status TINYINT, @InstructorEmployeeId INT, @RequiredMinutes INT
              , @CourseId INT, @ActorEmployeeId INT, @SignatureId BIGINT;

        SELECT @Status = [Status], @InstructorEmployeeId = InstructorEmployeeId
             , @RequiredMinutes = RequiredMinutes, @CourseId = CourseId
        FROM dlv.TrainingSession WHERE TrainingSessionId = @TrainingSessionId;

        IF @Status IS NULL THROW 50001, 'Sesion no encontrada.', 1;
        IF @Status = 5 THROW 50325, 'La sesion ya fue cerrada.', 1;

        SELECT @ActorEmployeeId = EmployeeId FROM sec.[User] WHERE UserId = @ActorUserId;

        IF @ActorEmployeeId <> @InstructorEmployeeId
           AND sec.fn_UserHasPermission(@ActorUserId, N'session.close.any') = 0
            THROW 50326, 'Solo el instructor asignado puede cerrar y firmar esta sesion.', 1;

        BEGIN TRANSACTION;

        UPDATE dlv.TrainingSession
        SET [Status] = 5, ActualEndUtc = ISNULL(ActualEndUtc, SYSUTCDATETIME())
          , InstructorNotes = COALESCE(@InstructorNotes, InstructorNotes)
          , ClosedAtUtc = SYSUTCDATETIME(), ClosedByUserId = @ActorUserId
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE TrainingSessionId = @TrainingSessionId;

        /* Minutos asistidos y estatus final. Quien no marco salida se
           considera presente hasta el fin real de la sesion. */
        UPDATE a
        SET  a.CheckOutAtUtc = ISNULL(a.CheckOutAtUtc, s.ActualEndUtc)
           , a.MinutesAttended = DATEDIFF(MINUTE, a.CheckInAtUtc, ISNULL(a.CheckOutAtUtc, s.ActualEndUtc))
           , a.AttendanceStatus =
                CASE WHEN a.CheckInAtUtc IS NULL THEN 4                                   -- Absent
                     WHEN @RequiredMinutes IS NOT NULL
                      AND DATEDIFF(MINUTE, a.CheckInAtUtc, ISNULL(a.CheckOutAtUtc, s.ActualEndUtc)) < @RequiredMinutes
                     THEN 3                                                                -- LeftEarly
                     WHEN a.CheckInAtUtc > DATEADD(MINUTE, 10, s.ScheduledStartUtc) THEN 2  -- Late
                     ELSE 1 END                                                            -- Present
           , a.ResultCode =
                CASE WHEN a.CheckInAtUtc IS NULL THEN 2
                     WHEN @RequiredMinutes IS NOT NULL
                      AND DATEDIFF(MINUTE, a.CheckInAtUtc, ISNULL(a.CheckOutAtUtc, s.ActualEndUtc)) < @RequiredMinutes
                     THEN 3
                     ELSE 1 END
        FROM dlv.SessionAttendance a
        JOIN dlv.TrainingSession s ON s.TrainingSessionId = a.TrainingSessionId
        WHERE a.TrainingSessionId = @TrainingSessionId;

        /* Firma del roster por el instructor. */
        SET @PayloadCanonical = ISNULL(@PayloadCanonical,
            (SELECT TrainingSessionId = @TrainingSessionId
                  , InstructorEmployeeId = @InstructorEmployeeId
                  , ClosedAtUtc = SYSUTCDATETIME()
                  , Roster = (SELECT a.EmployeeId, a.AttendanceStatus, a.MinutesAttended
                              FROM dlv.SessionAttendance a
                              WHERE a.TrainingSessionId = @TrainingSessionId
                              ORDER BY a.EmployeeId
                              FOR JSON PATH)
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER));

        EXEC aud.usp_Signature_Create
              @ActorUserId      = @ActorUserId
            , @SignatureMeaning = N'Attended'
            , @EntityType       = N'TrainingSession'
            , @EntityId         = @TrainingSessionId
            , @PayloadCanonical = @PayloadCanonical
            , @AuthMethod       = @AuthMethod
            , @SignatureRecordId = @SignatureId OUTPUT;

        UPDATE dlv.TrainingSession SET RosterSignatureId = @SignatureId
        WHERE TrainingSessionId = @TrainingSessionId;

        /* Evidencia por participante aprobado. */
        INSERT INTO dlv.EnrollmentEvidence (EnrollmentId, EvidenceType, EvidenceId, IsPassing, ScorePercent)
        SELECT a.EnrollmentId, 3, a.SessionAttendanceId, 1, NULL
        FROM dlv.SessionAttendance a
        WHERE a.TrainingSessionId = @TrainingSessionId
          AND a.EnrollmentId IS NOT NULL
          AND a.ResultCode = 1
          AND NOT EXISTS (SELECT 1 FROM dlv.EnrollmentEvidence ee
                          WHERE ee.EnrollmentId = a.EnrollmentId AND ee.EvidenceType = 3
                            AND ee.EvidenceId = a.SessionAttendanceId);

        EXEC aud.usp_Event_Log
              @EventType   = N'TrainingSession.Closed'
            , @EntityType  = N'TrainingSession'
            , @EntityId    = @TrainingSessionId
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Sesion presencial cerrada y roster firmado por el instructor.';

        COMMIT TRANSACTION;

        /* Completar inscripciones y evaluar certificacion de cada asistente. */
        DECLARE @EnrollmentId INT, @EmployeeId INT;
        DECLARE roster CURSOR LOCAL FAST_FORWARD FOR
            SELECT a.EnrollmentId, a.EmployeeId
            FROM dlv.SessionAttendance a
            WHERE a.TrainingSessionId = @TrainingSessionId AND a.ResultCode = 1;

        OPEN roster;
        FETCH NEXT FROM roster INTO @EnrollmentId, @EmployeeId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                IF @EnrollmentId IS NOT NULL
                    EXEC dlv.usp_Enrollment_Complete @ActorUserId = @ActorUserId, @EnrollmentId = @EnrollmentId;
                ELSE
                    EXEC comp.usp_Certification_EvaluateAndIssue
                          @ActorUserId = @ActorUserId, @EmployeeId = @EmployeeId
                        , @TriggerType = 3, @TriggerId = @TrainingSessionId;   -- 3=SessionAttendance
            END TRY
            BEGIN CATCH
                EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Session_Close', @ActorUserId = @ActorUserId;
            END CATCH;
            FETCH NEXT FROM roster INTO @EnrollmentId, @EmployeeId;
        END;
        CLOSE roster; DEALLOCATE roster;

        SELECT @SignatureId AS RosterSignatureId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Session_Close', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Resto del esquema dlv
   ===================================================================== */

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Get
      @ActorUserId INT, @EnrollmentId INT = NULL, @PublicId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @EnrollmentId = COALESCE(@EnrollmentId, EnrollmentId)
    FROM dlv.Enrollment WHERE @PublicId IS NOT NULL AND PublicId = @PublicId;
    IF @EnrollmentId IS NULL THROW 50001, 'Inscripcion no encontrada.', 1;

    SELECT e.EnrollmentId, e.PublicId, e.EmployeeId, emp.EmployeeCode, emp.FullName
         , e.CourseId, c.CourseCode, c.NameEs AS CourseName
         , e.CourseVersionId, v.VersionLabel
         , e.[Source], e.SourceRequirementId, e.[Status], e.AttemptNumber
         , e.ProgressPercent, e.ScorePercent, e.IsPassed
         , e.AssignedAtUtc, e.DueAtUtc, e.StartedAtUtc, e.CompletedAtUtc
         , e.LastAccessedAtUtc, e.LastAccessedItemId, e.TotalTimeSpentSeconds
    FROM dlv.Enrollment e
    JOIN org.Employee emp ON emp.EmployeeId = e.EmployeeId
    JOIN lms.Course c ON c.CourseId = e.CourseId
    JOIN lms.CourseVersion v ON v.CourseVersionId = e.CourseVersionId
    WHERE e.EnrollmentId = @EnrollmentId;

    SELECT ee.EnrollmentEvidenceId, ee.EvidenceType, ee.EvidenceId, ee.IsPassing
         , ee.ScorePercent, ee.RecordedAtUtc
    FROM dlv.EnrollmentEvidence ee WHERE ee.EnrollmentId = @EnrollmentId
    ORDER BY ee.RecordedAtUtc;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_ListForEmployee
      @ActorUserId INT, @EmployeeId INT, @Status TINYINT = NULL
    , @IncludeCompleted BIT = 1, @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    SELECT e.EnrollmentId, e.PublicId, e.CourseId, c.CourseCode, c.NameEs AS CourseName
         , c.DeliveryType, e.[Status], e.ProgressPercent, e.ScorePercent
         , e.DueAtUtc, e.StartedAtUtc, e.CompletedAtUtc, e.[Source]
         , CASE WHEN e.DueAtUtc IS NOT NULL AND e.DueAtUtc < SYSUTCDATETIME() AND e.[Status] IN (1,2)
                THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsOverdue
    FROM dlv.Enrollment e
    JOIN lms.Course c ON c.CourseId = e.CourseId
    WHERE e.EmployeeId = @EmployeeId
      AND (@Status IS NULL OR e.[Status] = @Status)
      AND (@IncludeCompleted = 1 OR e.[Status] IN (1,2))
    ORDER BY CASE WHEN e.[Status] IN (1,2) THEN 0 ELSE 1 END, e.DueAtUtc, e.AssignedAtUtc DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_ListForSupervisor
      @ActorUserId INT, @SupervisorEmployeeId INT, @IncludeIndirect BIT = 1
    , @OnlyOverdue BIT = 0, @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    SELECT emp.EmployeeId, emp.EmployeeCode, emp.FullName
         , e.EnrollmentId, c.CourseCode, c.NameEs AS CourseName
         , e.[Status], e.ProgressPercent, e.DueAtUtc
         , CASE WHEN e.DueAtUtc < SYSUTCDATETIME() THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsOverdue
    FROM org.fn_GetTeamEmployeeIds(@SupervisorEmployeeId, @IncludeIndirect) t
    JOIN org.Employee emp ON emp.EmployeeId = t.EmployeeId
    JOIN dlv.Enrollment e ON e.EmployeeId = emp.EmployeeId AND e.[Status] IN (1,2)
    JOIN lms.Course c ON c.CourseId = e.CourseId
    WHERE (@OnlyOverdue = 0 OR (e.DueAtUtc IS NOT NULL AND e.DueAtUtc < SYSUTCDATETIME()))
    ORDER BY e.DueAtUtc, emp.FullName
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_ListForCourse
      @ActorUserId INT, @CourseId INT, @Status TINYINT = NULL
    , @PageNumber INT = 1, @PageSize INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    SELECT e.EnrollmentId, e.EmployeeId, emp.EmployeeCode, emp.FullName
         , d.[Name] AS DepartmentName, e.[Status], e.ProgressPercent
         , e.ScorePercent, e.DueAtUtc, e.CompletedAtUtc
    FROM dlv.Enrollment e
    JOIN org.Employee emp ON emp.EmployeeId = e.EmployeeId
    LEFT JOIN org.Department d ON d.DepartmentId = emp.DepartmentId
    WHERE e.CourseId = @CourseId AND (@Status IS NULL OR e.[Status] = @Status)
    ORDER BY emp.FullName
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    SELECT COUNT(*) AS TotalCount FROM dlv.Enrollment
    WHERE CourseId = @CourseId AND (@Status IS NULL OR [Status] = @Status) OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Withdraw
      @ActorUserId INT, @EnrollmentId INT, @Reason NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'enrollment.withdraw') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF @Reason IS NULL OR LEN(LTRIM(@Reason)) = 0
            THROW 50306, 'La justificacion de retiro es obligatoria.', 1;

        UPDATE dlv.Enrollment
        SET [Status] = 5, WithdrawnAtUtc = SYSUTCDATETIME(), WithdrawnByUserId = @ActorUserId
          , WithdrawReason = @Reason, ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EnrollmentId = @EnrollmentId AND [Status] IN (1,2);
        IF @@ROWCOUNT = 0 THROW 50001, 'Inscripcion no encontrada o ya cerrada.', 1;

        EXEC aud.usp_Event_Log @EventType = N'Enrollment.Withdrawn', @EntityType = N'Enrollment'
           , @EntityId = @EnrollmentId, @ActorUserId = @ActorUserId, @Severity = 2
           , @Summary = N'Inscripcion retirada.';
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_Withdraw', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_ExtendDueDate
      @ActorUserId INT, @EnrollmentId INT, @NewDueAtUtc DATETIME2(3)
    , @Justification NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Toda extension deja rastro. Un auditor pregunta por que un
       requisito critico se movio tres veces; aqui esta la respuesta. */
    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'enrollment.extend') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
        IF @Justification IS NULL OR LEN(LTRIM(@Justification)) < 10
            THROW 50307, 'La justificacion de la extension es obligatoria y debe ser explicita.', 1;

        DECLARE @PreviousDue DATETIME2(3);
        SELECT @PreviousDue = DueAtUtc FROM dlv.Enrollment WHERE EnrollmentId = @EnrollmentId;

        BEGIN TRANSACTION;
        INSERT INTO dlv.EnrollmentExtension (EnrollmentId, PreviousDueAtUtc, NewDueAtUtc
                                           , Justification, RequestedByUserId, ApprovedByUserId)
        VALUES (@EnrollmentId, @PreviousDue, @NewDueAtUtc, @Justification, @ActorUserId, @ActorUserId);

        UPDATE dlv.Enrollment SET DueAtUtc = @NewDueAtUtc
          , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
        WHERE EnrollmentId = @EnrollmentId;
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Enrollment_ExtendDueDate', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_Reassign
      @ActorUserId INT, @EnrollmentId INT, @NewEmployeeId INT, @Reason NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    /* Solo aplica a inscripciones sin progreso: mover evidencia entre
       personas seria falsificar el expediente. */
    IF sec.fn_UserHasPermission(@ActorUserId, N'enrollment.assign') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    IF EXISTS (SELECT 1 FROM dlv.Enrollment WHERE EnrollmentId = @EnrollmentId AND ProgressPercent > 0)
        THROW 50308, 'No se puede reasignar una inscripcion con progreso registrado.', 1;

    UPDATE dlv.Enrollment SET EmployeeId = @NewEmployeeId
      , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE EnrollmentId = @EnrollmentId AND [Status] = 1;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Enrollment_ExpireOverdue
      @ActorUserId INT = NULL, @GraceDays INT = 0, @BatchSize INT = 1000
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Job nocturno. Expira, no borra: la inscripcion vencida es evidencia
       de que se asigno y no se completo. */
    DECLARE @Affected INT = 0;
    UPDATE TOP (@BatchSize) dlv.Enrollment
    SET [Status] = 6, ModifiedAtUtc = SYSUTCDATETIME()
    WHERE [Status] IN (1,2)
      AND DueAtUtc IS NOT NULL
      AND DATEADD(DAY, @GraceDays, DueAtUtc) < SYSUTCDATETIME();
    SET @Affected = @@ROWCOUNT;
    SELECT @Affected AS EnrollmentsExpired;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Progress_StartItem
      @ActorUserId INT, @EnrollmentId INT, @ModuleItemId INT
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dlv.ItemProgress AS tgt
    USING (SELECT @EnrollmentId AS EnrollmentId, @ModuleItemId AS ModuleItemId) AS src
    ON tgt.EnrollmentId = src.EnrollmentId AND tgt.ModuleItemId = src.ModuleItemId
    WHEN MATCHED THEN UPDATE SET
          [Status] = CASE WHEN tgt.[Status] = 1 THEN 2 ELSE tgt.[Status] END
        , ViewCount = tgt.ViewCount + 1
        , FirstAccessedAtUtc = ISNULL(tgt.FirstAccessedAtUtc, SYSUTCDATETIME())
        , LastAccessedAtUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
          (EnrollmentId, ModuleItemId, [Status], ViewCount, FirstAccessedAtUtc, LastAccessedAtUtc)
        VALUES (@EnrollmentId, @ModuleItemId, 2, 1, SYSUTCDATETIME(), SYSUTCDATETIME());

    UPDATE dlv.Enrollment
    SET [Status] = CASE WHEN [Status] = 1 THEN 2 ELSE [Status] END
      , StartedAtUtc = ISNULL(StartedAtUtc, SYSUTCDATETIME())
      , LastAccessedAtUtc = SYSUTCDATETIME(), LastAccessedItemId = @ModuleItemId
    WHERE EnrollmentId = @EnrollmentId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Progress_Heartbeat
      @ActorUserId INT, @EnrollmentId INT, @ModuleItemId INT = NULL
    , @SessionId UNIQUEIDENTIFIER = NULL, @IntervalSeconds SMALLINT = 30
    , @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    /* Tiempo real de exposicion al contenido. Sin esto, "cumplio el
       tiempo minimo" es un dato que no se puede defender. */
    INSERT INTO dlv.LearningActivity (EnrollmentId, ModuleItemId, SessionId, IntervalSeconds, IsActive)
    VALUES (@EnrollmentId, @ModuleItemId, @SessionId, @IntervalSeconds, @IsActive);

    IF @IsActive = 1 AND @ModuleItemId IS NOT NULL
        UPDATE dlv.ItemProgress
        SET TimeSpentSeconds = TimeSpentSeconds + @IntervalSeconds, LastAccessedAtUtc = SYSUTCDATETIME()
        WHERE EnrollmentId = @EnrollmentId AND ModuleItemId = @ModuleItemId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Progress_GetForEnrollment
      @ActorUserId INT, @EnrollmentId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT mp.CourseModuleId, m.TitleEs, m.SortOrder, mp.[Status]
         , mp.ItemsTotal, mp.ItemsCompleted, mp.ProgressPercent, mp.CompletedAtUtc
    FROM dlv.ModuleProgress mp
    JOIN lms.CourseModule m ON m.CourseModuleId = mp.CourseModuleId
    WHERE mp.EnrollmentId = @EnrollmentId ORDER BY m.SortOrder;

    SELECT ip.ModuleItemId, i.CourseModuleId, i.TitleEs, i.SortOrder, i.ItemType
         , ip.[Status], ip.ScorePercent, ip.TimeSpentSeconds, ip.CompletedAtUtc
    FROM dlv.ItemProgress ip
    JOIN lms.ModuleItem i ON i.ModuleItemId = ip.ModuleItemId
    WHERE ip.EnrollmentId = @EnrollmentId ORDER BY i.CourseModuleId, i.SortOrder;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Progress_UpsertItem
      @ActorUserId INT, @EnrollmentId INT, @ModuleItemId INT
    , @Status TINYINT = NULL, @ScorePercent DECIMAL(5,2) = NULL
    , @VideoPositionSeconds INT = NULL, @VideoWatchedPercent DECIMAL(5,2) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dlv.ItemProgress
    SET  [Status] = ISNULL(@Status, [Status])
       , ScorePercent = COALESCE(@ScorePercent, ScorePercent)
       , VideoPositionSeconds = COALESCE(@VideoPositionSeconds, VideoPositionSeconds)
       , VideoWatchedPercent = CASE WHEN @VideoWatchedPercent > ISNULL(VideoWatchedPercent, 0)
                                    THEN @VideoWatchedPercent ELSE VideoWatchedPercent END
       , LastAccessedAtUtc = SYSUTCDATETIME()
    WHERE EnrollmentId = @EnrollmentId AND ModuleItemId = @ModuleItemId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Cohort_Create
      @ActorUserId INT, @CourseId INT, @CohortCode NVARCHAR(40), @Name NVARCHAR(200)
    , @InstructorEmployeeId INT = NULL, @ShiftCode NVARCHAR(20) = NULL
    , @LocaleCode NVARCHAR(10) = N'es-DO'
    , @StartsAtUtc DATETIME2(3) = NULL, @EndsAtUtc DATETIME2(3) = NULL
    , @MaxParticipants INT = NULL, @CohortId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'cohort.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    INSERT INTO dlv.Cohort (CourseId, CohortCode, [Name], InstructorEmployeeId, ShiftCode
                          , LocaleCode, StartsAtUtc, EndsAtUtc, MaxParticipants, [Status], CreatedByUserId)
    VALUES (@CourseId, @CohortCode, @Name, @InstructorEmployeeId, @ShiftCode
          , @LocaleCode, @StartsAtUtc, @EndsAtUtc, @MaxParticipants, 1, @ActorUserId);
    SET @CohortId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Session_Get @ActorUserId INT, @TrainingSessionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.*, c.CourseCode, c.NameEs AS CourseName
         , i.FullName AS InstructorName, i.EmployeeCode AS InstructorCode
    FROM dlv.TrainingSession s
    JOIN lms.Course c ON c.CourseId = s.CourseId
    JOIN org.Employee i ON i.EmployeeId = s.InstructorEmployeeId
    WHERE s.TrainingSessionId = @TrainingSessionId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Session_GetRoster @ActorUserId INT, @TrainingSessionId INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT  r.SessionRegistrationId, r.EmployeeId, e.EmployeeCode, e.FullName
          , d.[Name] AS DepartmentName, r.[Status] AS RegistrationStatus, r.WaitlistPosition
          , a.SessionAttendanceId, a.AttendanceStatus, a.CheckInAtUtc, a.CheckOutAtUtc
          , a.MinutesAttended, a.ResultCode, a.ParticipantSignatureId
    FROM dlv.SessionRegistration r
    JOIN org.Employee e ON e.EmployeeId = r.EmployeeId
    LEFT JOIN org.Department d ON d.DepartmentId = e.DepartmentId
    LEFT JOIN dlv.SessionAttendance a ON a.TrainingSessionId = r.TrainingSessionId AND a.EmployeeId = r.EmployeeId
    WHERE r.TrainingSessionId = @TrainingSessionId
    ORDER BY r.[Status], e.FullName;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_SessionRegistration_Add
      @ActorUserId INT, @TrainingSessionId INT, @EmployeeId INT, @EnrollmentId INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    /* Errores: 50327 sesion llena y sin lista de espera */
    BEGIN TRY
        DECLARE @Max INT, @AllowWaitlist BIT, @Registered INT, @NewStatus TINYINT = 1, @WaitPos INT = NULL;
        SELECT @Max = MaxParticipants, @AllowWaitlist = AllowWaitlist
        FROM dlv.TrainingSession WHERE TrainingSessionId = @TrainingSessionId;

        SELECT @Registered = COUNT(*) FROM dlv.SessionRegistration
        WHERE TrainingSessionId = @TrainingSessionId AND [Status] IN (1,3);

        IF @Max IS NOT NULL AND @Registered >= @Max
        BEGIN
            IF @AllowWaitlist = 0 THROW 50327, 'La sesion esta llena y no admite lista de espera.', 1;
            SET @NewStatus = 2;
            SELECT @WaitPos = ISNULL(MAX(WaitlistPosition), 0) + 1
            FROM dlv.SessionRegistration WHERE TrainingSessionId = @TrainingSessionId;
        END;

        INSERT INTO dlv.SessionRegistration (TrainingSessionId, EmployeeId, EnrollmentId
                                           , [Status], WaitlistPosition, RegisteredByUserId)
        VALUES (@TrainingSessionId, @EmployeeId, @EnrollmentId, @NewStatus, @WaitPos, @ActorUserId);

        SELECT SCOPE_IDENTITY() AS SessionRegistrationId, @NewStatus AS [Status], @WaitPos AS WaitlistPosition;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_SessionRegistration_Add', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_SessionRegistration_Cancel
      @ActorUserId INT, @SessionRegistrationId INT, @Reason NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @SessionId INT;
        SELECT @SessionId = TrainingSessionId FROM dlv.SessionRegistration WHERE SessionRegistrationId = @SessionRegistrationId;

        BEGIN TRANSACTION;
        UPDATE dlv.SessionRegistration
        SET [Status] = 4, CancelledAtUtc = SYSUTCDATETIME(), CancelReason = @Reason
        WHERE SessionRegistrationId = @SessionRegistrationId;

        /* Promover al primero de la lista de espera. */
        UPDATE r
        SET r.[Status] = 1, r.WaitlistPosition = NULL, r.PromotedFromWaitlistAtUtc = SYSUTCDATETIME()
        FROM dlv.SessionRegistration r
        WHERE r.SessionRegistrationId = (
            SELECT TOP (1) SessionRegistrationId FROM dlv.SessionRegistration
            WHERE TrainingSessionId = @SessionId AND [Status] = 2
            ORDER BY WaitlistPosition);
        COMMIT TRANSACTION;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_SessionRegistration_Cancel', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Attendance_SetStatus
      @ActorUserId INT, @TrainingSessionId INT, @EmployeeId INT
    , @AttendanceStatus TINYINT, @Notes NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    MERGE dlv.SessionAttendance AS tgt
    USING (SELECT @TrainingSessionId AS S, @EmployeeId AS E) AS src
    ON tgt.TrainingSessionId = src.S AND tgt.EmployeeId = src.E
    WHEN MATCHED THEN UPDATE SET AttendanceStatus = @AttendanceStatus, Notes = @Notes
    WHEN NOT MATCHED THEN INSERT (TrainingSessionId, EmployeeId, AttendanceStatus, Notes, RecordedByUserId)
        VALUES (@TrainingSessionId, @EmployeeId, @AttendanceStatus, @Notes, @ActorUserId);
    RETURN 0;
END;
GO

/* El participante firma su propia asistencia desde el kiosko. Es la
   evidencia mas fuerte de que estuvo: firma suya, no del instructor. */
CREATE OR ALTER PROCEDURE dlv.usp_Attendance_SignParticipant
      @ActorUserId INT, @TrainingSessionId INT, @EmployeeId INT
    , @PayloadCanonical NVARCHAR(MAX) = NULL, @AuthMethod TINYINT = 2
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @SignatureId BIGINT, @AttendanceId INT;
        SELECT @AttendanceId = SessionAttendanceId FROM dlv.SessionAttendance
        WHERE TrainingSessionId = @TrainingSessionId AND EmployeeId = @EmployeeId;
        IF @AttendanceId IS NULL THROW 50324, 'No hay registro de asistencia para este empleado en la sesion.', 1;

        SET @PayloadCanonical = ISNULL(@PayloadCanonical,
            (SELECT TrainingSessionId = @TrainingSessionId, EmployeeId = @EmployeeId
                  , SignedAtUtc = SYSUTCDATETIME()
             FOR JSON PATH, WITHOUT_ARRAY_WRAPPER));

        EXEC aud.usp_Signature_Create
              @ActorUserId = @ActorUserId, @SignatureMeaning = N'Attended'
            , @EntityType = N'SessionAttendance', @EntityId = @AttendanceId
            , @PayloadCanonical = @PayloadCanonical, @AuthMethod = @AuthMethod
            , @SignatureRecordId = @SignatureId OUTPUT;

        UPDATE dlv.SessionAttendance SET ParticipantSignatureId = @SignatureId
        WHERE SessionAttendanceId = @AttendanceId;
        SELECT @SignatureId AS SignatureRecordId;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Attendance_SignParticipant', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Session_GetConflicts
      @ActorUserId INT, @InstructorEmployeeId INT
    , @StartUtc DATETIME2(3), @EndUtc DATETIME2(3), @ExcludeSessionId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT s.TrainingSessionId, s.SessionCode, s.TitleEs, s.ScheduledStartUtc, s.ScheduledEndUtc
    FROM dlv.TrainingSession s
    WHERE s.InstructorEmployeeId = @InstructorEmployeeId
      AND s.IsDeleted = 0 AND s.[Status] <> 6
      AND (@ExcludeSessionId IS NULL OR s.TrainingSessionId <> @ExcludeSessionId)
      AND s.ScheduledStartUtc < @EndUtc AND s.ScheduledEndUtc > @StartUtc
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE dlv.usp_Session_Update
      @ActorUserId INT, @TrainingSessionId INT
    , @TitleEs NVARCHAR(250) = NULL, @LocationName NVARCHAR(200) = NULL
    , @ScheduledStartUtc DATETIME2(3) = NULL, @ScheduledEndUtc DATETIME2(3) = NULL
    , @MaxParticipants INT = NULL, @Status TINYINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'session.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;
    UPDATE dlv.TrainingSession
    SET TitleEs = ISNULL(@TitleEs, TitleEs), LocationName = ISNULL(@LocationName, LocationName)
      , ScheduledStartUtc = ISNULL(@ScheduledStartUtc, ScheduledStartUtc)
      , ScheduledEndUtc = ISNULL(@ScheduledEndUtc, ScheduledEndUtc)
      , MaxParticipants = ISNULL(@MaxParticipants, MaxParticipants)
      , [Status] = ISNULL(@Status, [Status])
      , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHERE TrainingSessionId = @TrainingSessionId AND [Status] <> 5;
    RETURN 0;
END;
GO

/* Serie recurrente: N sesiones con el mismo RecurrenceGroupId. */
CREATE OR ALTER PROCEDURE dlv.usp_Session_CreateRecurring
      @ActorUserId INT, @CourseId INT, @SessionCodePrefix NVARCHAR(30)
    , @TitleEs NVARCHAR(250), @InstructorEmployeeId INT
    , @FirstStartUtc DATETIME2(3), @DurationMinutes INT
    , @IntervalDays INT = 7, @Occurrences INT = 4
    , @LocationName NVARCHAR(200) = NULL, @MaxParticipants INT = NULL
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    BEGIN TRY
        IF @Occurrences < 1 OR @Occurrences > 52
            THROW 50328, 'El numero de ocurrencias debe estar entre 1 y 52.', 1;

        DECLARE @GroupId UNIQUEIDENTIFIER = NEWID(), @i INT = 0, @NewId INT
              , @Start DATETIME2(3), @End DATETIME2(3), @Code NVARCHAR(40);

        WHILE @i < @Occurrences
        BEGIN
            SET @Start = DATEADD(DAY, @i * @IntervalDays, @FirstStartUtc);
            SET @End   = DATEADD(MINUTE, @DurationMinutes, @Start);
            SET @Code  = @SessionCodePrefix + N'-' + RIGHT(N'00' + CAST(@i + 1 AS NVARCHAR(3)), 2);

            EXEC dlv.usp_Session_Create
                  @ActorUserId = @ActorUserId, @CourseId = @CourseId, @SessionCode = @Code
                , @TitleEs = @TitleEs, @InstructorEmployeeId = @InstructorEmployeeId
                , @ScheduledStartUtc = @Start
                , @ScheduledEndUtc = @End
                , @LocationName = @LocationName, @MaxParticipants = @MaxParticipants
                , @TrainingSessionId = @NewId OUTPUT;

            UPDATE dlv.TrainingSession SET RecurrenceGroupId = @GroupId WHERE TrainingSessionId = @NewId;
            SET @i = @i + 1;
        END;

        SELECT @GroupId AS RecurrenceGroupId, @Occurrences AS SessionsCreated;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'dlv.usp_Session_CreateRecurring', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* Alias explicito: firma del roster sin cerrar (sesion multi-dia). */
CREATE OR ALTER PROCEDURE dlv.usp_Attendance_SignRoster
      @ActorUserId INT, @TrainingSessionId INT
    , @PayloadCanonical NVARCHAR(MAX) = NULL, @AuthMethod TINYINT = 1
    , @SignatureRecordId BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @PayloadCanonical = ISNULL(@PayloadCanonical,
        (SELECT TrainingSessionId = @TrainingSessionId, SignedAtUtc = SYSUTCDATETIME()
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER));

    EXEC aud.usp_Signature_Create
          @ActorUserId = @ActorUserId, @SignatureMeaning = N'Reviewed'
        , @EntityType = N'TrainingSession', @EntityId = @TrainingSessionId
        , @PayloadCanonical = @PayloadCanonical, @AuthMethod = @AuthMethod
        , @SignatureRecordId = @SignatureRecordId OUTPUT;

    UPDATE dlv.TrainingSession SET RosterSignatureId = @SignatureRecordId
    WHERE TrainingSessionId = @TrainingSessionId;
    RETURN 0;
END;
GO

PRINT '=== 13_procs_delivery_progress.sql completado ===';
GO

/* ############################################################################
   ARCHIVO: database/14_procs_assessment.sql
   ############################################################################ */
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

USE AIRLINK_KMS;
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

        DECLARE @EventSeverity TINYINT = CASE WHEN @IsPassed = 1 THEN 2 ELSE 3 END;
        EXEC aud.usp_Event_Log
              @EventType   = N'PracticalAssessment.Submitted'
            , @EntityType  = N'PracticalAssessment'
            , @EntityId    = @PracticalAssessmentId
            , @EmployeeId  = @EmployeeId
            , @ActorUserId = @ActorUserId
            , @Severity    = @EventSeverity
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

/* ############################################################################
   ARCHIVO: database/15_procs_compliance.sql
   ############################################################################ */
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

USE AIRLINK_KMS;
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
                LEFT JOIN @Evidence e2 ON e2.SatisfierType = g.SatisfierType
                                      AND e2.SatisfierId = g.SatisfierId
                WHERE g.RequirementId = r.RequirementId AND g.AlternativeGroup IS NOT NULL
                GROUP BY g.AlternativeGroup
                HAVING SUM(CASE WHEN e2.SatisfierId IS NULL THEN 0 ELSE 1 END) = 0)
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

                DECLARE @IssueSummary NVARCHAR(400) = N'Certificacion emitida: ' + @CertNumber;
                EXEC aud.usp_Event_Log
                      @EventType   = N'Certification.Issued'
                    , @EntityType  = N'Certification'
                    , @EntityId    = @CertId
                    , @EmployeeId  = @EmployeeId
                    , @ActorUserId = @ActorUserId
                    , @Severity    = 2
                    , @Summary     = @IssueSummary;

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

        DECLARE @ActivateSummary NVARCHAR(600)
              = N'Revision activada: ' + @DocCode + N' ' + ISNULL(@RevLabel, N'')
              + N'. Certificaciones marcadas para re-entrenamiento: ' + CAST(@Affected AS NVARCHAR(10));
        EXEC aud.usp_Event_Log
              @EventType   = N'DocumentRevision.Activated'
            , @EntityType  = N'ControlledDocumentRevision'
            , @EntityId    = @DocumentRevisionId
            , @ActorUserId = @ActorUserId
            , @Severity    = 4
            , @Summary     = @ActivateSummary;

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

                    DECLARE @RetrainDedupeKey NVARCHAR(60)
                          = N'DOCRETRAIN-' + CAST(@DocumentRevisionId AS NVARCHAR(12))
                          + N'-' + CAST(@EmpId AS NVARCHAR(12));
                    EXEC ops.usp_Notification_Enqueue
                          @TemplateCode = N'Document.RetrainingRequired'
                        , @RecipientEmployeeId = @EmpId
                        , @Priority = 1
                        , @NotifySupervisor = 1
                        , @DedupeKey = @RetrainDedupeKey;
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
            DECLARE @ReqId INT, @NewEnrollmentId INT
                  , @EnrollActorUserId INT = ISNULL(@ActorUserId, 1);
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
                          @ActorUserId = @EnrollActorUserId, @EmployeeId = @EmployeeId
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
            DECLARE @NotifPriority TINYINT = CASE WHEN @NotifDays <= 7 THEN 1 ELSE 2 END
                  , @NotifySupervisor BIT  = CASE WHEN @NotifDays <= 7 THEN 1 ELSE 0 END
                  , @NotifDedupeKey NVARCHAR(60)
                      = N'CERT-EXP-' + CAST(@NotifCertId AS NVARCHAR(12))
                      + N'-' + CAST(@NotifDays AS NVARCHAR(6));
            EXEC ops.usp_Notification_Enqueue
                  @TemplateCode = N'Certification.ExpiringSoon'
                , @RecipientEmployeeId = @NotifEmployeeId
                , @ModelJson = @NotifModel
                , @Priority = @NotifPriority
                , @NotifySupervisor = @NotifySupervisor
                , @DedupeKey = @NotifDedupeKey;

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

        DECLARE @RevokeSummary NVARCHAR(400) = N'Certificacion revocada: ' + @CertNumber;
        EXEC aud.usp_Event_Log @EventType = N'Certification.Revoked', @EntityType = N'Certification'
           , @EntityId = @CertificationId, @EmployeeId = @EmployeeId, @ActorUserId = @ActorUserId
           , @Severity = 4, @Summary = @RevokeSummary;
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

/* =====================================================================
   comp.usp_Station_SetRequirements

   Define que requisitos exige una estacion (reemplaza el set completo).
   JSON: [{"requirementId": 5, "isBlocking": true}, ...]
   IsBlocking = 1 es lo que el gating evalua como bloqueante.

   Errores: 50002 sin permiso, 50560 estacion no existe,
            50561 JSON invalido, 50562 requisito inexistente o inactivo
   ===================================================================== */
CREATE OR ALTER PROCEDURE comp.usp_Station_SetRequirements
      @ActorUserId      INT
    , @StationId        INT
    , @RequirementsJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        IF sec.fn_UserHasPermission(@ActorUserId, N'requirement.manage') = 0
            THROW 50002, 'El usuario no tiene permiso para esta operacion.', 1;

        IF NOT EXISTS (SELECT 1 FROM org.Station WHERE StationId = @StationId AND IsDeleted = 0)
            THROW 50560, 'La estacion no existe.', 1;

        IF ISJSON(@RequirementsJson) <> 1
            THROW 50561, 'RequirementsJson no es JSON valido.', 1;

        DECLARE @Incoming TABLE (RequirementId INT PRIMARY KEY, IsBlocking BIT NOT NULL);
        INSERT INTO @Incoming
        SELECT j.RequirementId, ISNULL(j.IsBlocking, 0)
        FROM OPENJSON(@RequirementsJson) WITH (
              RequirementId INT N'$.requirementId'
            , IsBlocking    BIT N'$.isBlocking'
        ) j;

        IF EXISTS (SELECT 1 FROM @Incoming i
                   WHERE NOT EXISTS (SELECT 1 FROM comp.CompetencyRequirement r
                                     WHERE r.RequirementId = i.RequirementId AND r.[Status] = 1))
            THROW 50562, 'Al menos un requisito no existe o no esta activo.', 1;

        BEGIN TRANSACTION;

        MERGE comp.StationCompetency AS tgt
        USING (SELECT RequirementId, IsBlocking FROM @Incoming) AS src
        ON tgt.StationId = @StationId AND tgt.RequirementId = src.RequirementId
        WHEN MATCHED AND tgt.IsBlocking <> src.IsBlocking THEN
            UPDATE SET IsBlocking = src.IsBlocking
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (StationId, RequirementId, IsBlocking)
            VALUES (@StationId, src.RequirementId, src.IsBlocking)
        WHEN NOT MATCHED BY SOURCE AND tgt.StationId = @StationId THEN
            DELETE;

        EXEC aud.usp_Event_Log
              @EventType   = N'Station.RequirementsSet'
            , @EntityType  = N'Station'
            , @EntityId    = @StationId
            , @ActorUserId = @ActorUserId
            , @Severity    = 3
            , @Summary     = N'Requisitos de competencia de la estacion redefinidos.';

        COMMIT TRANSACTION;

        SELECT sc.StationCompetencyId, sc.RequirementId, sc.IsBlocking
             , r.RequirementCode, r.Criticality
        FROM comp.StationCompetency sc
        JOIN comp.CompetencyRequirement r ON r.RequirementId = sc.RequirementId
        WHERE sc.StationId = @StationId;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'comp.usp_Station_SetRequirements', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

PRINT '=== 15_procs_compliance.sql completado ===';
GO

/* ############################################################################
   ARCHIVO: database/16_procs_reporting.sql
   ############################################################################ */
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

USE AIRLINK_KMS;
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

/* ############################################################################
   ARCHIVO: database/17_procs_integration.sql
   ############################################################################ */
/* =====================================================================
   Classroom - LMS by Airlink
   17_procs_integration.sql
   Esquema: intg (sincronizacion con SPN y AIRLINK)

   Contexto real (ver doc 07):
     - SPN  = base de nomina/empleados. Solo lectura. Es la fuente de
              verdad de quien trabaja aqui.
     - AIRLINK = base de produccion (THOR, IQC, BoxShipping). Solo
              lectura. Da contexto operacional: estaciones, procesos.
     - AlLmsSyncUser es el unico principal con acceso a esas dos bases.

   Principios de este archivo:
     1. El LMS NUNCA escribe en SPN ni en AIRLINK. Jamas.
     2. El sync es idempotente: correrlo dos veces no duplica nada.
     3. El sync NUNCA borra empleados. Un empleado que sale se marca
        inactivo. Su expediente de entrenamiento se conserva 7 anos
        porque el auditor puede preguntar por el.
     4. Una fila mala no tumba la corrida: se manda a
        intg.IntegrationError y el resto sigue.

   Codigos de error de este archivo: 50600-50699
   ===================================================================== */

USE AIRLINK_KMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 17_procs_integration.sql iniciado ===';
GO

/* =====================================================================
   intg.usp_EmployeeSync_LoadStaging

   Carga la landing zone. El SELECT contra SPN se hace con linked server
   o, mejor, con un paquete/agente externo que llama a este SP con un
   TVP. Aqui se acepta JSON para no acoplar el SP a la forma exacta de
   las tablas de SPN, que no controlamos.
   ===================================================================== */
CREATE OR ALTER PROCEDURE intg.usp_EmployeeSync_LoadStaging
      @SyncRunId      BIGINT
    , @EmployeesJson  NVARCHAR(MAX)
    , @RowsLoaded     INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50601 payload invalido */
    BEGIN TRY
        IF ISJSON(@EmployeesJson) <> 1
            THROW 50601, 'El payload de empleados no es JSON valido.', 1;

        /* Staging se limpia por corrida: no es dato de negocio. */
        DELETE FROM intg.EmployeeStaging WHERE SyncRunId = @SyncRunId;

        INSERT INTO intg.EmployeeStaging (SyncRunId, SourceEmployeeCode, FirstName, LastName
                                        , FullNameRaw, NationalId, Email, PositionTitleRaw
                                        , DepartmentRaw, SiteRaw, SupervisorCodeRaw
                                        , HireDate, TerminationDate, EmploymentStatusRaw
                                        , SourceRowHash)
        SELECT  @SyncRunId
              , LTRIM(RTRIM(j.EmployeeCode))
              , NULLIF(LTRIM(RTRIM(j.FirstName)), N'')
              , NULLIF(LTRIM(RTRIM(j.LastName)), N'')
              , NULLIF(LTRIM(RTRIM(j.FullName)), N'')
              , NULLIF(LTRIM(RTRIM(j.NationalId)), N'')
              , NULLIF(LTRIM(RTRIM(j.Email)), N'')
              , NULLIF(LTRIM(RTRIM(j.PositionTitle)), N'')
              , NULLIF(LTRIM(RTRIM(j.Department)), N'')
              , NULLIF(LTRIM(RTRIM(j.Site)), N'')
              , NULLIF(LTRIM(RTRIM(j.SupervisorCode)), N'')
              , j.HireDate
              , j.TerminationDate
              , NULLIF(LTRIM(RTRIM(j.EmploymentStatus)), N'')
              /* Hash de la fila para saltar registros sin cambios reales.
                 Ahorra el 95% del trabajo en el sync incremental. */
              , HASHBYTES('SHA2_256'
                  , CONCAT(ISNULL(j.FirstName, N''), N'|', ISNULL(j.LastName, N''), N'|'
                         , ISNULL(j.Email, N''), N'|', ISNULL(j.PositionTitle, N''), N'|'
                         , ISNULL(j.Department, N''), N'|', ISNULL(j.Site, N''), N'|'
                         , ISNULL(j.SupervisorCode, N''), N'|'
                         , ISNULL(CONVERT(NVARCHAR(10), j.HireDate, 23), N''), N'|'
                         , ISNULL(CONVERT(NVARCHAR(10), j.TerminationDate, 23), N''), N'|'
                         , ISNULL(j.EmploymentStatus, N'')))
        FROM OPENJSON(@EmployeesJson) WITH (
              EmployeeCode     NVARCHAR(30)  N'$.employeeCode'
            , FirstName        NVARCHAR(80)  N'$.firstName'
            , LastName         NVARCHAR(80)  N'$.lastName'
            , FullName         NVARCHAR(200) N'$.fullName'
            , NationalId       NVARCHAR(30)  N'$.nationalId'
            , Email            NVARCHAR(200) N'$.email'
            , PositionTitle    NVARCHAR(150) N'$.positionTitle'
            , Department       NVARCHAR(150) N'$.department'
            , Site             NVARCHAR(100) N'$.site'
            , SupervisorCode   NVARCHAR(30)  N'$.supervisorCode'
            , HireDate         DATE          N'$.hireDate'
            , TerminationDate  DATE          N'$.terminationDate'
            , EmploymentStatus NVARCHAR(50)  N'$.employmentStatus'
        ) j
        WHERE NULLIF(LTRIM(RTRIM(j.EmployeeCode)), N'') IS NOT NULL;

        SET @RowsLoaded = @@ROWCOUNT;

        /* Validacion basica antes del merge. Lo invalido no se descarta:
           se marca, para que alguien lo vea y lo arregle en SPN. */
        UPDATE intg.EmployeeStaging
        SET IsValid = 0, ValidationMessage = N'Falta nombre o apellido y no hay nombre completo.'
        WHERE SyncRunId = @SyncRunId
          AND (FirstName IS NULL OR LastName IS NULL)
          AND FullNameRaw IS NULL;

        UPDATE intg.EmployeeStaging
        SET IsValid = 0, ValidationMessage = N'Codigo de empleado duplicado en el origen.'
        WHERE SyncRunId = @SyncRunId
          AND SourceEmployeeCode IN (
                SELECT SourceEmployeeCode FROM intg.EmployeeStaging
                WHERE SyncRunId = @SyncRunId
                GROUP BY SourceEmployeeCode HAVING COUNT(*) > 1);

        SELECT @RowsLoaded AS RowsLoaded
             , (SELECT COUNT(*) FROM intg.EmployeeStaging WHERE SyncRunId = @SyncRunId AND IsValid = 0) AS InvalidRows;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'intg.usp_EmployeeSync_LoadStaging';
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   intg.usp_EmployeeSync_Merge

   El corazon del sync. Reglas de negocio que costaron discusiones:

   - Match por EmployeeCode. Es la clave natural de SPN y no cambia.
   - Si SPN trae solo "fullName", se parte por el primer espacio. Es
     imperfecto con nombres compuestos dominicanos ("Jose Luis Perez
     Ramirez"), asi que preferimos siempre firstName/lastName separados.
   - Posiciones: SPN maneja titulos de texto libre. Se mapean contra
     org.Position por nombre; lo que no matchea crea una posicion con
     RequiresReview = 1 para que Calidad la revise en vez de perderla.
   - Terminacion: se marca IsActive = 0, se cierran asignaciones y se
     cancelan inscripciones abiertas. NO se borra nada.
   - Reingreso: si un empleado terminado vuelve a aparecer activo, se
     reactiva conservando su historial. Esto pasa mas de lo que uno cree.
   ===================================================================== */
CREATE OR ALTER PROCEDURE intg.usp_EmployeeSync_Merge
      @SyncRunId       BIGINT
    , @ActorUserId     INT = NULL
    , @DryRun          BIT = 0
    , @DeactivateMissing BIT = 0   -- solo tiene sentido en sync full
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME()
              , @Inserted INT = 0, @Updated INT = 0, @Skipped INT = 0
              , @Deactivated INT = 0, @Errored INT = 0;

        /* --- 1. Resolver referencias de texto a IDs ---------------- */
        DECLARE @Resolved TABLE (
              EmployeeStagingId  BIGINT PRIMARY KEY
            , SourceEmployeeCode NVARCHAR(30) NOT NULL
            , FirstName          NVARCHAR(80) NOT NULL
            , LastName           NVARCHAR(80) NOT NULL
            , Email              NVARCHAR(200) NULL
            , NationalIdMasked   NVARCHAR(20) NULL
            , SiteId             INT NULL
            , DepartmentId       INT NULL
            , PositionId         INT NULL
            , SupervisorEmployeeId INT NULL
            , HireDateUtc        DATETIME2(3) NULL
            , TerminationDateUtc DATETIME2(3) NULL
            , IsActive           BIT NOT NULL
            , SourceRowHash      BINARY(32) NULL
        );

        INSERT INTO @Resolved
        SELECT  st.EmployeeStagingId
              , st.SourceEmployeeCode
              , /* nombre */
                ISNULL(st.FirstName,
                       CASE WHEN CHARINDEX(N' ', st.FullNameRaw) > 0
                            THEN LEFT(st.FullNameRaw, CHARINDEX(N' ', st.FullNameRaw) - 1)
                            ELSE st.FullNameRaw END)
              , ISNULL(st.LastName,
                       CASE WHEN CHARINDEX(N' ', st.FullNameRaw) > 0
                            THEN LTRIM(SUBSTRING(st.FullNameRaw, CHARINDEX(N' ', st.FullNameRaw) + 1, 200))
                            ELSE N'.' END)
              , st.Email
              /* PII: solo los ultimos 4 de la cedula quedan visibles. */
              , CASE WHEN st.NationalId IS NULL THEN NULL
                     ELSE N'****' + RIGHT(st.NationalId, 4) END
              , s.SiteId
              , d.DepartmentId
              , p.PositionId
              , sup.EmployeeId
              , CAST(st.HireDate AS DATETIME2(3))
              , CAST(st.TerminationDate AS DATETIME2(3))
              /* Activo = sin fecha de terminacion pasada y estatus no
                 marcado como baja en el origen. */
              , CASE WHEN st.TerminationDate IS NOT NULL AND st.TerminationDate <= CAST(@NowUtc AS DATE) THEN 0
                     WHEN st.EmploymentStatusRaw IN (N'INACTIVO', N'INACTIVE', N'TERMINADO', N'TERMINATED', N'BAJA') THEN 0
                     ELSE 1 END
              , st.SourceRowHash
        FROM intg.EmployeeStaging st
        LEFT JOIN org.Site s        ON s.[Name] = st.SiteRaw OR s.SiteCode = st.SiteRaw
        LEFT JOIN org.Department d  ON d.[Name] = st.DepartmentRaw OR d.DepartmentCode = st.DepartmentRaw
        LEFT JOIN org.[Position] p  ON p.[Name] = st.PositionTitleRaw OR p.PositionCode = st.PositionTitleRaw
        LEFT JOIN org.Employee sup  ON sup.EmployeeCode = st.SupervisorCodeRaw
        WHERE st.SyncRunId = @SyncRunId AND st.IsValid = 1;

        /* --- 2. Posiciones nuevas detectadas en SPN ----------------
           No se pierde el titulo: se crea la posicion marcada para
           revision. Calidad decide despues que competencias exige. */
        IF @DryRun = 0
        BEGIN
            INSERT INTO org.[Position] (PositionCode, [Name], AffectsProductQuality
                                      , IsMappedFromSource, RequiresReview, IsActive)
            SELECT DISTINCT
                   LEFT(N'SPN-' + REPLACE(UPPER(st.PositionTitleRaw), N' ', N'-'), 40)
                 , st.PositionTitleRaw
                 , 0, 1, 1, 1
            FROM intg.EmployeeStaging st
            WHERE st.SyncRunId = @SyncRunId AND st.IsValid = 1
              AND st.PositionTitleRaw IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM org.[Position] p
                              WHERE p.[Name] = st.PositionTitleRaw
                                 OR p.PositionCode = LEFT(N'SPN-' + REPLACE(UPPER(st.PositionTitleRaw), N' ', N'-'), 40));

            /* Reintentar la resolucion con las posiciones recien creadas */
            UPDATE r
            SET r.PositionId = p.PositionId
            FROM @Resolved r
            JOIN intg.EmployeeStaging st ON st.EmployeeStagingId = r.EmployeeStagingId
            JOIN org.[Position] p ON p.[Name] = st.PositionTitleRaw
            WHERE r.PositionId IS NULL;
        END;

        /* --- 3. Errores de resolucion ------------------------------ */
        INSERT INTO intg.IntegrationError (SyncRunId, SourceSystem, SourceEntity, SourceKey
                                         , ErrorCode, ErrorMessage, PayloadJson)
        SELECT  @SyncRunId, N'SPN', N'Employee', r.SourceEmployeeCode
              , N'UNRESOLVED_REFERENCE'
              , N'No se pudo resolver: '
                + CASE WHEN r.SiteId IS NULL THEN N'sitio ' ELSE N'' END
                + CASE WHEN r.DepartmentId IS NULL THEN N'departamento ' ELSE N'' END
                + CASE WHEN r.SupervisorEmployeeId IS NULL THEN N'supervisor ' ELSE N'' END
              , (SELECT st.SiteRaw, st.DepartmentRaw, st.SupervisorCodeRaw, st.PositionTitleRaw
                 FROM intg.EmployeeStaging st WHERE st.EmployeeStagingId = r.EmployeeStagingId
                 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
        FROM @Resolved r
        WHERE r.SiteId IS NULL OR r.DepartmentId IS NULL;

        IF @DryRun = 1
        BEGIN
            SELECT  (SELECT COUNT(*) FROM @Resolved r
                     WHERE NOT EXISTS (SELECT 1 FROM org.Employee e WHERE e.EmployeeCode = r.SourceEmployeeCode)) AS WouldInsert
                  , (SELECT COUNT(*) FROM @Resolved r
                     JOIN org.Employee e ON e.EmployeeCode = r.SourceEmployeeCode
                     WHERE ISNULL(e.SourceHash, 0x) <> ISNULL(r.SourceRowHash, 0x)) AS WouldUpdate
                  , (SELECT COUNT(*) FROM @Resolved r
                     JOIN org.Employee e ON e.EmployeeCode = r.SourceEmployeeCode
                     WHERE ISNULL(e.SourceHash, 0x) = ISNULL(r.SourceRowHash, 0x)) AS WouldSkip;
            SELECT * FROM @Resolved;
            RETURN 0;
        END;

        /* --- 4. MERGE de empleados --------------------------------- */
        DECLARE @Changes TABLE (Action NVARCHAR(10), EmployeeId INT, WasActive BIT, IsActive BIT);

        BEGIN TRANSACTION;

        MERGE org.Employee AS tgt
        USING (SELECT * FROM @Resolved) AS src
        ON tgt.EmployeeCode = src.SourceEmployeeCode

        WHEN MATCHED AND ISNULL(tgt.SourceHash, 0x) <> ISNULL(src.SourceRowHash, 0x) THEN
            UPDATE SET
                  tgt.FirstName        = src.FirstName
                , tgt.LastName         = src.LastName
                , tgt.Email            = COALESCE(src.Email, tgt.Email)
                , tgt.NationalIdMasked = COALESCE(src.NationalIdMasked, tgt.NationalIdMasked)
                , tgt.SiteId           = COALESCE(src.SiteId, tgt.SiteId)
                , tgt.DepartmentId     = COALESCE(src.DepartmentId, tgt.DepartmentId)
                , tgt.SupervisorEmployeeId = COALESCE(src.SupervisorEmployeeId, tgt.SupervisorEmployeeId)
                , tgt.HireDateUtc      = COALESCE(src.HireDateUtc, tgt.HireDateUtc)
                , tgt.TerminationDateUtc = src.TerminationDateUtc
                , tgt.IsActive         = src.IsActive
                , tgt.SourceHash       = src.SourceRowHash
                , tgt.LastSyncedAtUtc  = @NowUtc
                , tgt.ModifiedAtUtc    = @NowUtc
                , tgt.ModifiedByUserId = @ActorUserId

        WHEN NOT MATCHED BY TARGET THEN
            INSERT (EmployeeCode, FirstName, LastName, Email, NationalIdMasked
                  , SiteId, DepartmentId, PrimaryPositionId, SupervisorEmployeeId
                  , HireDateUtc, TerminationDateUtc, IsActive
                  , SourceSystem, SourceHash, LastSyncedAtUtc, CreatedByUserId)
            VALUES (src.SourceEmployeeCode, src.FirstName, src.LastName, src.Email, src.NationalIdMasked
                  , src.SiteId, src.DepartmentId, src.PositionId, src.SupervisorEmployeeId
                  , src.HireDateUtc, src.TerminationDateUtc, src.IsActive
                  , N'SPN', src.SourceRowHash, @NowUtc, @ActorUserId)

        OUTPUT $action, inserted.EmployeeId, deleted.IsActive, inserted.IsActive
        INTO @Changes (Action, EmployeeId, WasActive, IsActive);

        SELECT @Inserted = SUM(CASE WHEN Action = N'INSERT' THEN 1 ELSE 0 END)
             , @Updated  = SUM(CASE WHEN Action = N'UPDATE' THEN 1 ELSE 0 END)
        FROM @Changes;

        SELECT @Skipped = COUNT(*) FROM @Resolved r
        JOIN org.Employee e ON e.EmployeeCode = r.SourceEmployeeCode
        WHERE NOT EXISTS (SELECT 1 FROM @Changes c WHERE c.EmployeeId = e.EmployeeId);

        /* --- 4b. Supervisores: segunda pasada -----------------------
           En la carga inicial (o cuando jefe y subordinado vienen en el
           mismo lote) el supervisor no existia al resolver la fila. Se
           re-resuelve contra org.Employee ya poblado; aplica a TODO el
           staging del lote, no solo a los cambiados. */
        UPDATE e
        SET e.SupervisorEmployeeId = sup.EmployeeId
          , e.ModifiedAtUtc = @NowUtc, e.ModifiedByUserId = @ActorUserId
        FROM org.Employee e
        JOIN intg.EmployeeStaging st ON st.SourceEmployeeCode = e.EmployeeCode
                                    AND st.SyncRunId = @SyncRunId AND st.IsValid = 1
        JOIN org.Employee sup ON sup.EmployeeCode = st.SupervisorCodeRaw
        WHERE ISNULL(e.SupervisorEmployeeId, -1) <> sup.EmployeeId;

        /* --- 5. Posiciones ----------------------------------------- */
        /* Cerrar la posicion primaria anterior si cambio, y abrir la nueva.
           org.EmployeePosition es historia: nunca se sobreescribe. */
        UPDATE ep
        SET ep.EffectiveToUtc = @NowUtc
        FROM org.EmployeePosition ep
        JOIN org.Employee e ON e.EmployeeId = ep.EmployeeId
        JOIN @Resolved r ON r.SourceEmployeeCode = e.EmployeeCode
        WHERE ep.IsPrimary = 1 AND ep.EffectiveToUtc IS NULL
          AND r.PositionId IS NOT NULL AND ep.PositionId <> r.PositionId;

        INSERT INTO org.EmployeePosition (EmployeeId, PositionId, IsPrimary, EffectiveFromUtc, AssignedByUserId, Notes)
        SELECT e.EmployeeId, r.PositionId, 1, @NowUtc, @ActorUserId, N'Sincronizado desde SPN.'
        FROM @Resolved r
        JOIN org.Employee e ON e.EmployeeCode = r.SourceEmployeeCode
        WHERE r.PositionId IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM org.EmployeePosition ep
                          WHERE ep.EmployeeId = e.EmployeeId AND ep.PositionId = r.PositionId
                            AND ep.EffectiveToUtc IS NULL);

        UPDATE e
        SET e.PrimaryPositionId = r.PositionId
        FROM org.Employee e
        JOIN @Resolved r ON r.SourceEmployeeCode = e.EmployeeCode
        WHERE r.PositionId IS NOT NULL AND ISNULL(e.PrimaryPositionId, -1) <> r.PositionId;

        /* --- 6. Bajas ---------------------------------------------- */
        /* Cerrar asignaciones y cancelar inscripciones abiertas de quien
           salio. El expediente completo se conserva. */
        UPDATE ea
        SET ea.EffectiveToUtc = @NowUtc
        FROM org.EmployeeAssignment ea
        JOIN @Changes c ON c.EmployeeId = ea.EmployeeId
        WHERE c.IsActive = 0 AND ISNULL(c.WasActive, 1) = 1 AND ea.EffectiveToUtc IS NULL;

        UPDATE en
        SET en.[Status] = 5, en.WithdrawnAtUtc = @NowUtc
          , en.WithdrawReason = N'Empleado inactivo en el sistema de nomina.'
          , en.ModifiedAtUtc = @NowUtc
        FROM dlv.Enrollment en
        JOIN @Changes c ON c.EmployeeId = en.EmployeeId
        WHERE c.IsActive = 0 AND ISNULL(c.WasActive, 1) = 1 AND en.[Status] IN (1, 2);

        UPDATE u
        SET u.IsActive = 0, u.ModifiedAtUtc = @NowUtc
        FROM sec.[User] u
        JOIN @Changes c ON c.EmployeeId = u.EmployeeId
        WHERE c.IsActive = 0 AND u.IsActive = 1;

        /* Reingreso: el empleado vuelve activo -> su usuario tambien.
           Su historial y certificaciones no vencidas siguen validas. */
        UPDATE u
        SET u.IsActive = 1, u.ModifiedAtUtc = @NowUtc
        FROM sec.[User] u
        JOIN @Changes c ON c.EmployeeId = u.EmployeeId
        WHERE c.IsActive = 1 AND ISNULL(c.WasActive, 1) = 0 AND u.IsActive = 0 AND u.IsDeleted = 0;

        SELECT @Deactivated = COUNT(*) FROM @Changes WHERE IsActive = 0 AND ISNULL(WasActive, 1) = 1;

        /* Sync full: quien ya no aparece en SPN se desactiva. NUNCA se
           borra, y solo aplica en modo full para no matar gente por un
           incremental incompleto. */
        IF @DeactivateMissing = 1
        BEGIN
            UPDATE e
            SET e.IsActive = 0, e.ModifiedAtUtc = @NowUtc, e.ModifiedByUserId = @ActorUserId
            FROM org.Employee e
            WHERE e.SourceSystem = N'SPN' AND e.IsActive = 1
              AND NOT EXISTS (SELECT 1 FROM @Resolved r WHERE r.SourceEmployeeCode = e.EmployeeCode);
            SET @Deactivated = @Deactivated + @@ROWCOUNT;
        END;

        /* --- 7. Cierre de la corrida ------------------------------- */
        UPDATE intg.SyncRun
        SET RowsRead = (SELECT COUNT(*) FROM intg.EmployeeStaging WHERE SyncRunId = @SyncRunId)
          , RowsInserted = ISNULL(@Inserted, 0)
          , RowsUpdated  = ISNULL(@Updated, 0)
          , RowsSkipped  = ISNULL(@Skipped, 0)
          , RowsErrored  = (SELECT COUNT(*) FROM intg.IntegrationError WHERE SyncRunId = @SyncRunId)
          , [Status] = CASE WHEN (SELECT COUNT(*) FROM intg.IntegrationError WHERE SyncRunId = @SyncRunId) > 0
                            THEN 4 ELSE 2 END
          , CompletedAtUtc = @NowUtc
        WHERE SyncRunId = @SyncRunId;

        UPDATE intg.SyncWatermark
        SET WatermarkValue = CONVERT(NVARCHAR(30), @NowUtc, 126)
          , LastSuccessAtUtc = @NowUtc, LastRunAtUtc = @NowUtc
          , LastRowCount = ISNULL(@Inserted, 0) + ISNULL(@Updated, 0)
          , ConsecutiveFailures = 0, ModifiedAtUtc = @NowUtc
        WHERE SourceSystem = N'SPN' AND SourceEntity = N'Employee';

        EXEC aud.usp_Event_Log
              @EventType   = N'EmployeeSync.Completed'
            , @EntityType  = N'SyncRun'
            , @EntityId    = NULL
            , @ActorUserId = @ActorUserId
            , @Severity    = 2
            , @Summary     = N'Sincronizacion de empleados completada.';

        COMMIT TRANSACTION;

        /* --- 8. Recalcular compliance de los que cambiaron ---------
           Fuera de la transaccion. Un empleado que cambio de puesto
           tiene requisitos distintos desde ya. */
        DECLARE @EmpId INT;
        DECLARE ch CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT EmployeeId FROM @Changes WHERE IsActive = 1;
        OPEN ch; FETCH NEXT FROM ch INTO @EmpId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                EXEC comp.usp_Gap_RecalculateForEmployee
                      @ActorUserId = @ActorUserId, @EmployeeId = @EmpId, @AutoEnroll = 1;
            END TRY
            BEGIN CATCH
                EXEC aud.usp_Error_Log @ProcedureName = N'intg.usp_EmployeeSync_Merge', @ActorUserId = @ActorUserId;
            END CATCH;
            FETCH NEXT FROM ch INTO @EmpId;
        END;
        CLOSE ch; DEALLOCATE ch;

        SELECT  ISNULL(@Inserted, 0)    AS RowsInserted
              , ISNULL(@Updated, 0)     AS RowsUpdated
              , ISNULL(@Skipped, 0)     AS RowsSkipped
              , ISNULL(@Deactivated, 0) AS RowsDeactivated
              , (SELECT COUNT(*) FROM intg.IntegrationError WHERE SyncRunId = @SyncRunId) AS RowsErrored;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        UPDATE intg.SyncRun
        SET [Status] = 3, ErrorMessage = ERROR_MESSAGE(), CompletedAtUtc = SYSUTCDATETIME()
        WHERE SyncRunId = @SyncRunId;

        UPDATE intg.SyncWatermark
        SET ConsecutiveFailures = ConsecutiveFailures + 1, LastRunAtUtc = SYSUTCDATETIME()
        WHERE SourceSystem = N'SPN' AND SourceEntity = N'Employee';

        EXEC aud.usp_Error_Log @ProcedureName = N'intg.usp_EmployeeSync_Merge', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   intg.usp_EmployeeSync_Run   -- orquestador (lo llama el job)
   ===================================================================== */
CREATE OR ALTER PROCEDURE intg.usp_EmployeeSync_Run
      @ActorUserId   INT = NULL
    , @RunMode       TINYINT = 1        -- 1=Incremental 2=Full 3=Manual
    , @EmployeesJson NVARCHAR(MAX) = NULL
    , @TriggeredBy   NVARCHAR(100) = N'SqlAgent'
    , @SyncRunId     BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50602 ya hay una corrida en progreso */
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM intg.SyncRun
                   WHERE SourceSystem = N'SPN' AND SourceEntity = N'Employee'
                     AND [Status] = 1
                     AND StartedAtUtc > DATEADD(HOUR, -2, SYSUTCDATETIME()))
            THROW 50602, 'Ya hay una sincronizacion de empleados en progreso.', 1;

        DECLARE @Watermark NVARCHAR(100), @RowsLoaded INT;

        SELECT @Watermark = WatermarkValue FROM intg.SyncWatermark
        WHERE SourceSystem = N'SPN' AND SourceEntity = N'Employee';

        INSERT INTO intg.SyncRun (SourceSystem, SourceEntity, RunMode, [Status]
                                , WatermarkFrom, TriggeredBy)
        VALUES (N'SPN', N'Employee', @RunMode, 1
              , CASE WHEN @RunMode = 2 THEN NULL ELSE @Watermark END, @TriggeredBy);

        SET @SyncRunId = SCOPE_IDENTITY();

        /* Si no viene payload, el agente externo lo entrega llamando a
           LoadStaging con este @SyncRunId. Devolvemos el id y salimos. */
        IF @EmployeesJson IS NULL
        BEGIN
            SELECT @SyncRunId AS SyncRunId, N'Awaiting staging load' AS [Status];
            RETURN 0;
        END;

        EXEC intg.usp_EmployeeSync_LoadStaging
              @SyncRunId = @SyncRunId, @EmployeesJson = @EmployeesJson
            , @RowsLoaded = @RowsLoaded OUTPUT;

        DECLARE @DeactivateMissing BIT = CASE WHEN @RunMode = 2 THEN 1 ELSE 0 END;
        EXEC intg.usp_EmployeeSync_Merge
              @SyncRunId = @SyncRunId, @ActorUserId = @ActorUserId
            , @DeactivateMissing = @DeactivateMissing;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @SyncRunId IS NOT NULL
            UPDATE intg.SyncRun
            SET [Status] = 3, ErrorMessage = ERROR_MESSAGE(), CompletedAtUtc = SYSUTCDATETIME()
            WHERE SyncRunId = @SyncRunId;
        EXEC aud.usp_Error_Log @ProcedureName = N'intg.usp_EmployeeSync_Run', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   intg.usp_ProductionContext_GetForEmployee

   Puente de lectura hacia AIRLINK. Devuelve donde ha estado trabajando
   el empleado segun produccion, para cruzarlo con lo que esta
   certificado para hacer.

   Este SP es el que destapa el hallazgo incomodo: "el operador X lleva
   3 semanas en la estacion RXR-01 y su certificacion vencio hace 40
   dias". Mejor que lo encuentre el sistema y no el auditor.

   NOTA DE IMPLEMENTACION: el acceso a AIRLINK se hace por linked server
   o por vista sinonimo creada con AlLmsSyncUser. Aqui se deja el
   contrato y la logica de cruce; la fuente concreta se conecta en el
   deploy segun como quede configurado el enlace (ver doc 07 seccion 3).
   ===================================================================== */
CREATE OR ALTER PROCEDURE intg.usp_ProductionContext_GetForEmployee
      @ActorUserId INT
    , @EmployeeId  INT
    , @DaysBack    INT = 30
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        DECLARE @FromUtc DATETIME2(3) = DATEADD(DAY, -@DaysBack, SYSUTCDATETIME());

        /* 1. Estaciones donde el LMS sabe que estuvo asignado */
        SELECT  ea.StationId, s.StationCode, s.[Name] AS StationName
              , s.ProcessCode, s.EquipmentName
              , s.RequiresGating, s.GatingMode
              , ea.EffectiveFromUtc, ea.EffectiveToUtc
        FROM org.EmployeeAssignment ea
        JOIN org.Station s ON s.StationId = ea.StationId
        WHERE ea.EmployeeId = @EmployeeId
          AND (ea.EffectiveToUtc IS NULL OR ea.EffectiveToUtc >= @FromUtc)
        ORDER BY ea.EffectiveFromUtc DESC;

        /* 2. Elegibilidad para cada una de esas estaciones */
        SELECT  s.StationId, s.StationCode
              , SUM(CASE WHEN g.CompetencyGapId IS NOT NULL AND sc.IsBlocking = 1
                          AND ISNULL(g.HasActiveWaiver, 0) = 0 THEN 1 ELSE 0 END) AS BlockingGaps
              , SUM(CASE WHEN g.CompetencyGapId IS NOT NULL THEN 1 ELSE 0 END) AS TotalGaps
              , CASE WHEN SUM(CASE WHEN g.CompetencyGapId IS NOT NULL AND sc.IsBlocking = 1
                                    AND ISNULL(g.HasActiveWaiver, 0) = 0 THEN 1 ELSE 0 END) > 0
                     THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS IsEligible
        FROM org.EmployeeAssignment ea
        JOIN org.Station s ON s.StationId = ea.StationId
        LEFT JOIN comp.StationCompetency sc ON sc.StationId = s.StationId
        LEFT JOIN comp.CompetencyGap g ON g.RequirementId = sc.RequirementId
                                      AND g.EmployeeId = @EmployeeId AND g.ResolvedAtUtc IS NULL
        WHERE ea.EmployeeId = @EmployeeId AND ea.EffectiveToUtc IS NULL
        GROUP BY s.StationId, s.StationCode;

        /* 3. Historial de decisiones de gating: la evidencia de si el
              operador estuvo trabajando sin certificacion vigente. */
        SELECT TOP (100)
                gl.EvaluatedAtUtc, gl.StationId, s.StationCode
              , gl.Decision, gl.GatingMode, gl.WasEnforced, gl.RequestSource
        FROM comp.GatingDecisionLog gl
        LEFT JOIN org.Station s ON s.StationId = gl.StationId
        WHERE gl.EmployeeId = @EmployeeId AND gl.EvaluatedAtUtc >= @FromUtc
        ORDER BY gl.EvaluatedAtUtc DESC;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'intg.usp_ProductionContext_GetForEmployee', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   Utilitarios de integracion
   ===================================================================== */
CREATE OR ALTER PROCEDURE intg.usp_Watermark_Get
      @SourceSystem NVARCHAR(50) = NULL, @SourceEntity NVARCHAR(80) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT SyncWatermarkId, SourceSystem, SourceEntity, WatermarkValue
         , LastSuccessAtUtc, LastRunAtUtc, LastRowCount, ConsecutiveFailures, IsEnabled
    FROM intg.SyncWatermark
    WHERE (@SourceSystem IS NULL OR SourceSystem = @SourceSystem)
      AND (@SourceEntity IS NULL OR SourceEntity = @SourceEntity)
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE intg.usp_EmployeeSync_GetLastRun
      @ActorUserId INT = NULL, @Top INT = 10
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top)
           r.SyncRunId, r.RunMode, r.[Status], r.RowsRead, r.RowsInserted
         , r.RowsUpdated, r.RowsSkipped, r.RowsErrored
         , r.StartedAtUtc, r.CompletedAtUtc, r.DurationMs, r.TriggeredBy, r.ErrorMessage
    FROM intg.SyncRun r
    WHERE r.SourceSystem = N'SPN' AND r.SourceEntity = N'Employee'
    ORDER BY r.SyncRunId DESC;

    /* Errores abiertos: lo que un humano tiene que ir a arreglar en SPN. */
    SELECT TOP (100)
           e.IntegrationErrorId, e.SyncRunId, e.SourceKey, e.ErrorCode
         , e.ErrorMessage, e.PayloadJson, e.OccurredAtUtc
    FROM intg.IntegrationError e
    WHERE e.IsResolved = 0 AND e.SourceEntity = N'Employee'
    ORDER BY e.OccurredAtUtc DESC;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE intg.usp_ExternalId_Map
      @ActorUserId INT = NULL, @SourceSystem NVARCHAR(50), @EntityType NVARCHAR(60)
    , @InternalId INT, @ExternalId NVARCHAR(100), @ExternalCode NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    MERGE intg.ExternalIdMap AS tgt
    USING (SELECT @SourceSystem AS S, @EntityType AS E, @ExternalId AS X) AS src
    ON tgt.SourceSystem = src.S AND tgt.EntityType = src.E AND tgt.ExternalId = src.X
    WHEN MATCHED THEN UPDATE SET
          InternalId = @InternalId, ExternalCode = @ExternalCode
        , IsActive = 1, ModifiedAtUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (SourceSystem, EntityType, InternalId, ExternalId, ExternalCode)
        VALUES (@SourceSystem, @EntityType, @InternalId, @ExternalId, @ExternalCode);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE intg.usp_IntegrationError_Log
      @SyncRunId BIGINT = NULL, @SourceSystem NVARCHAR(50), @SourceEntity NVARCHAR(80)
    , @SourceKey NVARCHAR(100) = NULL, @ErrorCode NVARCHAR(40) = NULL
    , @ErrorMessage NVARCHAR(MAX), @PayloadJson NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO intg.IntegrationError (SyncRunId, SourceSystem, SourceEntity, SourceKey
                                     , ErrorCode, ErrorMessage, PayloadJson)
    VALUES (@SyncRunId, @SourceSystem, @SourceEntity, @SourceKey
          , @ErrorCode, @ErrorMessage, @PayloadJson);
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE intg.usp_IntegrationError_Resolve
      @ActorUserId INT, @IntegrationErrorId BIGINT, @ResolutionNote NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE intg.IntegrationError
    SET IsResolved = 1, ResolvedByUserId = @ActorUserId
      , ResolvedAtUtc = SYSUTCDATETIME(), ResolutionNote = @ResolutionNote
    WHERE IntegrationErrorId = @IntegrationErrorId;
    RETURN 0;
END;
GO

PRINT '=== 17_procs_integration.sql completado ===';
GO

/* ############################################################################
   ARCHIVO: database/99_seed_reference_data.sql
   ############################################################################ */
/* =====================================================================
   Classroom - LMS by Airlink
   99_seed_reference_data.sql

   Datos de referencia sin los cuales el sistema no arranca:
   permisos, roles, mapeo de grupos de Entra ID, configuracion,
   feature flags, plantillas de notificacion bilingues y politicas de
   retencion.

   IDEMPOTENTE: se puede correr las veces que haga falta. Todo es MERGE
   por clave natural. No inserta datos de negocio (empleados, cursos,
   competencias): eso lo trae el sync de SPN y lo carga Calidad.

   Los permisos de aqui son EXACTAMENTE los que los stored procedures
   verifican con sec.fn_UserHasPermission. Si se agrega un permiso nuevo
   en un SP, va aqui tambien o el SP niega el acceso a todo el mundo.
   ===================================================================== */

USE AIRLINK_KMS;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
PRINT '=== 99_seed_reference_data.sql iniciado ===';
GO

BEGIN TRANSACTION;

/* =====================================================================
   1. PERMISOS
   ===================================================================== */
DECLARE @Permissions TABLE (
      PermissionCode NVARCHAR(80)
    , Domain         NVARCHAR(40)
    , [Description]  NVARCHAR(400));

INSERT INTO @Permissions VALUES
  /* --- Contenido -------------------------------------------------- */
  (N'course.create',    N'Content', N'Crear cursos nuevos.')
, (N'course.edit',      N'Content', N'Editar borradores de curso y su contenido.')
, (N'course.submit',    N'Content', N'Enviar una version de curso a revision.')
, (N'course.publish',   N'Content', N'Publicar una version de curso. Requiere segregacion de funciones.')
, (N'course.retire',    N'Content', N'Retirar un curso del catalogo activo.')
, (N'course.translate', N'Content', N'Editar traducciones de contenido.')
, (N'course.blueprint', N'Content', N'Gestionar cursos plantilla y propagar cambios.')
, (N'program.manage',   N'Content', N'Crear y modificar programas de formacion.')
, (N'quiz.manage',      N'Content', N'Crear y configurar evaluaciones escritas.')
, (N'question.manage',  N'Content', N'Gestionar bancos y preguntas.')
, (N'rubric.manage',    N'Content', N'Gestionar rubricas de evaluacion.')
, (N'practical.manage', N'Content', N'Gestionar plantillas de evaluacion practica (OJT).')

  /* --- Entrega ----------------------------------------------------- */
, (N'enrollment.assign',    N'Delivery', N'Asignar cursos a empleados.')
, (N'enrollment.withdraw',  N'Delivery', N'Retirar inscripciones.')
, (N'enrollment.extend',    N'Delivery', N'Extender fechas limite de inscripcion.')
, (N'enrollment.read.all',  N'Delivery', N'Ver inscripciones de cualquier empleado.')
, (N'progress.override',    N'Delivery', N'Marcar progreso manualmente. Uso excepcional y auditado.')
, (N'cohort.manage',        N'Delivery', N'Gestionar cohortes.')
, (N'session.manage',       N'Delivery', N'Crear y administrar sesiones presenciales.')
, (N'session.close.any',    N'Delivery', N'Cerrar sesiones de otros instructores.')
, (N'session.override_qualification', N'Delivery'
  , N'Asignar un instructor sin calificacion vigente. Excepcional; queda en la bitacora.')

  /* --- Evaluacion --------------------------------------------------- */
, (N'assessment.grade',    N'Assessment', N'Calificar preguntas abiertas y rubricas.')
, (N'assessment.read.all', N'Assessment', N'Ver intentos de evaluacion de cualquier empleado.')

  /* --- Compliance --------------------------------------------------- */
, (N'competency.manage',        N'Compliance', N'Definir competencias y sus niveles.')
, (N'requirement.manage',       N'Compliance', N'Definir requisitos de competencia y sus satisfactores.')
, (N'certification.revoke',     N'Compliance', N'Revocar certificaciones emitidas.')
, (N'certification.reinstate',  N'Compliance', N'Reinstalar una certificacion revocada.')
, (N'waiver.approve',           N'Compliance', N'Aprobar waivers. No puede aprobar quien solicita.')
, (N'evaluator.manage',         N'Compliance', N'Otorgar y revocar calificacion de evaluador.')
, (N'document.manage',          N'Compliance', N'Crear documentos controlados y sus revisiones.')
, (N'document.activate',        N'Compliance'
  , N'Activar una revision de documento. Dispara invalidacion de certificaciones y re-entrenamiento.')

  /* --- Organizacion e identidad ------------------------------------- */
, (N'user.manage',              N'Identity', N'Crear, editar y desactivar usuarios.')
, (N'user.read',                N'Identity', N'Consultar usuarios del sistema.')
, (N'role.manage',              N'Identity', N'Definir roles y sus permisos.')
, (N'role.assign',              N'Identity', N'Asignar roles a usuarios.')
, (N'device.manage',            N'Identity', N'Registrar y administrar kioscos y tabletas de piso.')
, (N'org.manage',               N'Org',      N'Administrar sitios, departamentos, areas y estaciones.')
, (N'employee.read.all',        N'Org',      N'Ver el directorio completo de empleados.')
, (N'employee.position.manage', N'Org',      N'Asignar y cerrar posiciones de empleados.')
, (N'settings.manage',          N'Platform', N'Modificar la configuracion del sistema.')

  /* --- Reportes ------------------------------------------------------ */
, (N'report.competencymatrix', N'Reporting', N'Ver la matriz de competencias (GAP-01).')
, (N'report.trainingrecord',   N'Reporting', N'Ver el expediente de entrenamiento de otros empleados.')
, (N'report.auditpackage',     N'Reporting', N'Generar el paquete de evidencia de auditoria (GAP-07).')
, (N'report.executive',        N'Reporting', N'Ver el tablero ejecutivo.')
, (N'report.waiverregister',   N'Reporting', N'Ver el registro de waivers.');

/* DisplayName se deriva del codigo: 'course.publish' -> 'Course Publish'.
   Los nombres para pantalla los afina Calidad despues; lo que importa
   para la autorizacion es PermissionCode. */
MERGE sec.Permission AS tgt
USING (SELECT  p.PermissionCode
             , p.Domain
             , p.[Description]
             , DisplayName = UPPER(LEFT(REPLACE(REPLACE(p.PermissionCode, N'.', N' '), N'_', N' '), 1))
                           + SUBSTRING(REPLACE(REPLACE(p.PermissionCode, N'.', N' '), N'_', N' '), 2, 150)
       FROM @Permissions p) AS src
ON tgt.PermissionCode = src.PermissionCode
WHEN MATCHED THEN UPDATE SET
      Domain = src.Domain, [Description] = src.[Description]
    , DisplayNameEs = src.DisplayName, DisplayNameEn = src.DisplayName, IsSystem = 1
WHEN NOT MATCHED THEN INSERT (PermissionCode, Domain, DisplayNameEs, DisplayNameEn, [Description], IsSystem)
    VALUES (src.PermissionCode, src.Domain, src.DisplayName, src.DisplayName, src.[Description], 1);

DECLARE @Cnt_sec_Permission INT = (SELECT COUNT(*) FROM sec.Permission);
PRINT CONCAT('Permisos: ', @Cnt_sec_Permission);
GO

/* =====================================================================
   2. ROLES

   Siete roles. La separacion CONTENT_AUTHOR / QUALITY_APPROVER no es
   burocracia: es la segregacion de funciones que exige ISO 9001 y que
   sec.usp_UserRole_Assign valida. Quien escribe el contenido no lo
   aprueba.
   ===================================================================== */
DECLARE @Roles TABLE (
      RoleCode      NVARCHAR(40)
    , DisplayNameEs NVARCHAR(100)
    , DisplayNameEn NVARCHAR(100)
    , [Description] NVARCHAR(400));

INSERT INTO @Roles VALUES
  (N'LEARNER', N'Colaborador', N'Learner'
 , N'Todo empleado. Ve sus cursos, sus certificaciones y su expediente. No necesita permisos explicitos.')
, (N'INSTRUCTOR', N'Instructor', N'Instructor'
 , N'Imparte sesiones presenciales, evalua practicas y califica. Debe tener calificacion de evaluador vigente.')
, (N'SUPERVISOR', N'Supervisor', N'Supervisor'
 , N'Ve el estado de su equipo, asigna cursos y solicita waivers. No los aprueba.')
, (N'CONTENT_AUTHOR', N'Autor de contenido', N'Content Author'
 , N'Crea y edita cursos, quizzes y bancos de preguntas. NO puede publicar: eso lo hace Calidad.')
, (N'QUALITY_APPROVER', N'Aprobador de calidad', N'Quality Approver'
 , N'Publica versiones de curso, activa revisiones de documentos, define competencias y aprueba waivers.')
, (N'TRAINING_ADMIN', N'Administrador de formacion', N'Training Administrator'
 , N'Administra el catalogo, inscripciones masivas, cohortes y sesiones. Genera reportes de compliance.')
, (N'SYSTEM_ADMIN', N'Administrador del sistema', N'System Administrator'
 , N'Configuracion, usuarios, roles, dispositivos e integraciones. No aprueba contenido ni waivers.');

MERGE sec.Role AS tgt
USING @Roles AS src ON tgt.RoleCode = src.RoleCode
WHEN MATCHED THEN UPDATE SET
      DisplayNameEs = src.DisplayNameEs, DisplayNameEn = src.DisplayNameEn
    , [Description] = src.[Description], IsSystem = 1, IsActive = 1
WHEN NOT MATCHED THEN INSERT (RoleCode, DisplayNameEs, DisplayNameEn, [Description], IsSystem, IsActive)
    VALUES (src.RoleCode, src.DisplayNameEs, src.DisplayNameEn, src.[Description], 1, 1);

DECLARE @Cnt_sec_Role INT = (SELECT COUNT(*) FROM sec.Role);
PRINT CONCAT('Roles: ', @Cnt_sec_Role);
GO

/* =====================================================================
   3. PERMISOS POR ROL
   ===================================================================== */
DECLARE @RolePerms TABLE (RoleCode NVARCHAR(40), PermissionCode NVARCHAR(80));

/* LEARNER: sin permisos explicitos. Lo suyo se resuelve por pertenencia
   (su propio expediente, sus propias inscripciones). Es deliberado: un
   permiso de mas aqui se multiplica por toda la planta. */

INSERT INTO @RolePerms VALUES
  /* INSTRUCTOR */
  (N'INSTRUCTOR', N'assessment.grade')
, (N'INSTRUCTOR', N'assessment.read.all')
, (N'INSTRUCTOR', N'session.manage')
, (N'INSTRUCTOR', N'practical.manage')
, (N'INSTRUCTOR', N'enrollment.read.all')
, (N'INSTRUCTOR', N'report.trainingrecord')
, (N'INSTRUCTOR', N'employee.read.all')

  /* SUPERVISOR */
, (N'SUPERVISOR', N'enrollment.assign')
, (N'SUPERVISOR', N'enrollment.extend')
, (N'SUPERVISOR', N'enrollment.read.all')
, (N'SUPERVISOR', N'employee.read.all')
, (N'SUPERVISOR', N'report.trainingrecord')
, (N'SUPERVISOR', N'report.competencymatrix')

  /* CONTENT_AUTHOR - crea, no publica */
, (N'CONTENT_AUTHOR', N'course.create')
, (N'CONTENT_AUTHOR', N'course.edit')
, (N'CONTENT_AUTHOR', N'course.submit')
, (N'CONTENT_AUTHOR', N'course.translate')
, (N'CONTENT_AUTHOR', N'quiz.manage')
, (N'CONTENT_AUTHOR', N'question.manage')
, (N'CONTENT_AUTHOR', N'rubric.manage')
, (N'CONTENT_AUTHOR', N'practical.manage')
, (N'CONTENT_AUTHOR', N'program.manage')

  /* QUALITY_APPROVER - aprueba, no crea contenido */
, (N'QUALITY_APPROVER', N'course.publish')
, (N'QUALITY_APPROVER', N'course.retire')
, (N'QUALITY_APPROVER', N'course.blueprint')
, (N'QUALITY_APPROVER', N'competency.manage')
, (N'QUALITY_APPROVER', N'requirement.manage')
, (N'QUALITY_APPROVER', N'certification.revoke')
, (N'QUALITY_APPROVER', N'certification.reinstate')
, (N'QUALITY_APPROVER', N'waiver.approve')
, (N'QUALITY_APPROVER', N'evaluator.manage')
, (N'QUALITY_APPROVER', N'document.manage')
, (N'QUALITY_APPROVER', N'document.activate')
, (N'QUALITY_APPROVER', N'report.competencymatrix')
, (N'QUALITY_APPROVER', N'report.trainingrecord')
, (N'QUALITY_APPROVER', N'report.auditpackage')
, (N'QUALITY_APPROVER', N'report.waiverregister')
, (N'QUALITY_APPROVER', N'employee.read.all')
, (N'QUALITY_APPROVER', N'assessment.read.all')

  /* TRAINING_ADMIN */
, (N'TRAINING_ADMIN', N'enrollment.assign')
, (N'TRAINING_ADMIN', N'enrollment.withdraw')
, (N'TRAINING_ADMIN', N'enrollment.extend')
, (N'TRAINING_ADMIN', N'enrollment.read.all')
, (N'TRAINING_ADMIN', N'cohort.manage')
, (N'TRAINING_ADMIN', N'session.manage')
, (N'TRAINING_ADMIN', N'session.close.any')
, (N'TRAINING_ADMIN', N'program.manage')
, (N'TRAINING_ADMIN', N'employee.read.all')
, (N'TRAINING_ADMIN', N'employee.position.manage')
, (N'TRAINING_ADMIN', N'assessment.read.all')
, (N'TRAINING_ADMIN', N'report.competencymatrix')
, (N'TRAINING_ADMIN', N'report.trainingrecord')
, (N'TRAINING_ADMIN', N'report.executive')
, (N'TRAINING_ADMIN', N'report.waiverregister')

  /* SYSTEM_ADMIN - infraestructura, no contenido ni compliance */
, (N'SYSTEM_ADMIN', N'user.manage')
, (N'SYSTEM_ADMIN', N'user.read')
, (N'SYSTEM_ADMIN', N'role.manage')
, (N'SYSTEM_ADMIN', N'role.assign')
, (N'SYSTEM_ADMIN', N'device.manage')
, (N'SYSTEM_ADMIN', N'org.manage')
, (N'SYSTEM_ADMIN', N'settings.manage')
, (N'SYSTEM_ADMIN', N'employee.read.all')
, (N'SYSTEM_ADMIN', N'employee.position.manage');

MERGE sec.RolePermission AS tgt
USING (SELECT r.RoleId, p.PermissionId
       FROM @RolePerms rp
       JOIN sec.Role r       ON r.RoleCode       = rp.RoleCode
       JOIN sec.Permission p ON p.PermissionCode = rp.PermissionCode) AS src
ON tgt.RoleId = src.RoleId AND tgt.PermissionId = src.PermissionId
WHEN NOT MATCHED BY TARGET THEN INSERT (RoleId, PermissionId) VALUES (src.RoleId, src.PermissionId)
WHEN NOT MATCHED BY SOURCE AND EXISTS (SELECT 1 FROM sec.Role r WHERE r.RoleId = tgt.RoleId AND r.IsSystem = 1)
     THEN DELETE;   /* mantiene los roles de sistema exactamente como este archivo los define */

DECLARE @Cnt_sec_RolePermission INT = (SELECT COUNT(*) FROM sec.RolePermission);
PRINT CONCAT('Asignaciones rol-permiso: ', @Cnt_sec_RolePermission);
GO

/* =====================================================================
   4. MAPEO DE GRUPOS DE ENTRA ID

   Los GUIDs son placeholders. Se reemplazan con los ObjectId reales de
   los grupos de seguridad al desplegar. Mientras tengan estos valores,
   el mapeo simplemente no matchea con nada, que es el fallo seguro.
   ===================================================================== */
DECLARE @GroupMap TABLE (GroupName NVARCHAR(200), GroupObjectId NVARCHAR(100), RoleCode NVARCHAR(40));

INSERT INTO @GroupMap VALUES
  (N'AL-LMS-Instructors',     N'00000000-0000-0000-0000-000000000001', N'INSTRUCTOR')
, (N'AL-LMS-Supervisors',     N'00000000-0000-0000-0000-000000000002', N'SUPERVISOR')
, (N'AL-LMS-ContentAuthors',  N'00000000-0000-0000-0000-000000000003', N'CONTENT_AUTHOR')
, (N'AL-LMS-Quality',         N'00000000-0000-0000-0000-000000000004', N'QUALITY_APPROVER')
, (N'AL-LMS-TrainingAdmins',  N'00000000-0000-0000-0000-000000000005', N'TRAINING_ADMIN')
, (N'AL-LMS-SystemAdmins',    N'00000000-0000-0000-0000-000000000006', N'SYSTEM_ADMIN');

MERGE sec.RoleGroupMapping AS tgt
USING (SELECT gm.GroupName, gm.GroupObjectId, r.RoleId
       FROM @GroupMap gm JOIN sec.Role r ON r.RoleCode = gm.RoleCode) AS src
ON tgt.ExternalGroupId = src.GroupObjectId
WHEN MATCHED THEN UPDATE SET
      ExternalGroupName = src.GroupName, RoleId = src.RoleId, IsActive = 1
WHEN NOT MATCHED THEN INSERT (ExternalGroupId, ExternalGroupName, RoleId, ScopeType, IsActive)
    VALUES (src.GroupObjectId, src.GroupName, src.RoleId, 7, 1);   -- 7 = alcance global
GO

/* =====================================================================
   5. CONFIGURACION
   ===================================================================== */
DECLARE @Settings TABLE (
      SettingKey    NVARCHAR(100)
    , SettingValue  NVARCHAR(MAX)
    , DataType      NVARCHAR(20)
    , [Description] NVARCHAR(400));

INSERT INTO @Settings VALUES
  /* --- Identidad y sesion ------------------------------------------ */
  (N'Auth.Pin.MinLength',            N'6',      N'int'
 , N'Longitud minima del PIN de piso. El PIN nunca viaja ni se guarda en claro.')
, (N'Auth.Pin.MaxFailedAttempts',    N'5',      N'int'
 , N'Intentos fallidos antes de bloquear el PIN.')
, (N'Auth.Pin.LockoutMinutes',       N'15',     N'int', N'Duracion del bloqueo por PIN.')
, (N'Auth.Session.TimeoutMinutes',   N'480',    N'int', N'Vigencia de sesion de oficina (8 horas).')
, (N'Auth.Kiosk.TimeoutMinutes',     N'10',     N'int'
 , N'Vigencia de sesion en kiosco. Corta a proposito: la tableta es compartida.')

  /* --- Compliance --------------------------------------------------- */
, (N'Compliance.DefaultAlertWindowDays', N'60,30,7', N'string'
 , N'Ventanas de aviso por defecto para vencimiento de certificaciones.')
, (N'Compliance.DefaultGracePeriodDays', N'0',   N'int'
 , N'Dias de gracia por defecto tras el vencimiento. Cero salvo que el requisito diga otra cosa.')
, (N'Compliance.AutoEnrollOnGap',        N'true', N'bool'
 , N'Auto-inscribir remediacion cuando se detecta una brecha.')
, (N'Compliance.RetentionYears',         N'7',   N'int'
 , N'Anos de conservacion del expediente de entrenamiento.')
, (N'Compliance.CertificateNumberPrefix', N'CERT', N'string', N'Prefijo del numero de certificado.')

  /* --- Entrega ------------------------------------------------------ */
, (N'Delivery.DefaultDueDays',       N'30',     N'int', N'Dias por defecto para completar una asignacion.')
, (N'Delivery.MaxQuizAttempts',      N'3',      N'int', N'Intentos por defecto en evaluaciones escritas.')
, (N'Delivery.SessionWaitlistEnabled', N'true', N'bool', N'Permitir lista de espera en sesiones llenas.')
, (N'Delivery.AttendanceMinimumPercent', N'80', N'int'
 , N'Porcentaje minimo de asistencia para aprobar una sesion presencial.')

  /* --- Localizacion -------------------------------------------------- */
, (N'Locale.Default',                N'es-DO',  N'string', N'Idioma por defecto de la plataforma.')
, (N'Locale.Supported',              N'es-DO,en-US', N'string', N'Idiomas soportados.')
, (N'Locale.TimeZone',               N'America/Santo_Domingo', N'string'
 , N'Zona horaria de presentacion. Todo se almacena en UTC.')

  /* --- Organizacion --------------------------------------------------- */
, (N'Org.CompanyName',               N'Airlink Distribution DR', N'string', N'Razon social para certificados y reportes.')
, (N'Org.ProductName',               N'Classroom', N'string', N'Nombre del producto en la interfaz.')

  /* --- Retencion ------------------------------------------------------ */
, (N'Retention.EventLog.Days',       N'1095',   N'int', N'Retencion de eventos informativos (3 anos).')
, (N'Retention.AppLog.Days',         N'90',     N'int', N'Retencion del log de aplicacion.')
, (N'Retention.ErrorLog.Days',       N'365',    N'int', N'Retencion del log de errores.')
, (N'Retention.Notification.Days',   N'180',    N'int', N'Retencion de notificaciones ya enviadas.')
, (N'Retention.Staging.Days',        N'30',     N'int', N'Retencion del staging de integracion.')

  /* --- Integracion ----------------------------------------------------- */
, (N'Integration.SPN.Enabled',       N'true',   N'bool', N'Sincronizacion de empleados desde SPN.')
, (N'Integration.SPN.SyncIntervalMinutes', N'60', N'int', N'Frecuencia del sync incremental.')
, (N'Integration.Airlink.ReadOnly',  N'true',   N'bool'
 , N'El LMS solo lee de la base de produccion. Nunca escribe. No cambiar.');

MERGE ops.Setting AS tgt
USING @Settings AS src ON tgt.SettingKey = src.SettingKey AND tgt.ScopeType = 1
WHEN MATCHED AND tgt.ModifiedByUserId IS NULL THEN UPDATE SET
      SettingValue = src.SettingValue, DataType = src.DataType
    , [Description] = src.[Description], ModifiedAtUtc = SYSUTCDATETIME()
      /* Si un admin ya lo cambio (ModifiedByUserId no nulo), el seed
         respeta su valor. Re-correr el deploy no debe pisar ajustes. */
WHEN NOT MATCHED THEN INSERT (SettingKey, ScopeType, SettingValue, DataType, [Description])
    VALUES (src.SettingKey, 1, src.SettingValue, src.DataType, src.[Description]);

DECLARE @Cnt_ops_Setting INT = (SELECT COUNT(*) FROM ops.Setting);
PRINT CONCAT('Configuraciones: ', @Cnt_ops_Setting);
GO

/* =====================================================================
   6. FEATURE FLAGS

   Gating.Enforce arranca APAGADO. Siempre. Se enciende despues de
   semanas en modo Shadow y de revisar comp.GatingDecisionLog para
   confirmar que lo que bloquearia son brechas reales y no datos sucios.
   Encenderlo el dia uno para la linea entera.
   ===================================================================== */
DECLARE @Flags TABLE (
      FlagKey       NVARCHAR(80)
    , [Description] NVARCHAR(400)
    , IsEnabled     BIT
    , AudienceType  TINYINT);

INSERT INTO @Flags VALUES
  (N'Gating.Enforce', N'Bloquear de verdad el acceso a estaciones por competencias faltantes. Encender solo tras validar el modo Shadow.', 0, 1)
, (N'Gating.Warn',    N'Mostrar advertencia sin bloquear cuando faltan competencias.', 1, 1)
, (N'Kiosk.Enabled',  N'Habilitar el modo kiosco con codigo de empleado y PIN (GAP-09).', 1, 1)
, (N'Practical.RequireDualSignature', N'Exigir firma del evaluado ademas de la del evaluador en evaluaciones practicas.', 1, 1)
, (N'Notifications.TeamsChannel', N'Enviar notificaciones por Teams ademas de correo.', 0, 1)
, (N'Reports.AuditPackageExport', N'Habilitar la exportacion del paquete de evidencia de auditoria.', 1, 1)
, (N'Content.BilingualRequired',  N'Exigir traduccion al ingles antes de publicar un curso.', 0, 1)
, (N'Integration.ProductionContext', N'Habilitar el puente de lectura hacia la base de produccion AIRLINK.', 0, 1);

MERGE ops.FeatureFlag AS tgt
USING @Flags AS src ON tgt.FlagKey = src.FlagKey
WHEN MATCHED AND tgt.ModifiedByUserId IS NULL THEN UPDATE SET
      [Description] = src.[Description], AudienceType = src.AudienceType
    , ModifiedAtUtc = SYSUTCDATETIME()
      /* IsEnabled NO se pisa en updates: si alguien encendio el gating a
         proposito, el deploy no lo apaga por detras. */
WHEN NOT MATCHED THEN INSERT (FlagKey, [Description], IsEnabled, AudienceType)
    VALUES (src.FlagKey, src.[Description], src.IsEnabled, src.AudienceType);

DECLARE @Cnt_ops_FeatureFlag INT = (SELECT COUNT(*) FROM ops.FeatureFlag);
PRINT CONCAT('Feature flags: ', @Cnt_ops_FeatureFlag);
GO

/* =====================================================================
   7. PLANTILLAS DE NOTIFICACION (bilingues, GAP-10)

   Placeholders {{Variable}} resueltos por el worker de la API contra el
   PayloadJson de la cola. Cada plantilla existe en es-DO y en-US.
   Canal 1 = Email.
   ===================================================================== */
DECLARE @Templates TABLE (
      TemplateKey  NVARCHAR(80)
    , LocaleCode   NVARCHAR(10)
    , Channel      TINYINT
    , [Subject]    NVARCHAR(300)
    , BodyTemplate NVARCHAR(MAX));

INSERT INTO @Templates VALUES

/* --- Curso enviado a revision ---------------------------------------- */
( N'Course.ReviewRequested', N'es-DO', 1
, N'Revision solicitada: {{CourseName}}'
, N'Hola {{ApproverName}},

{{AuthorName}} envio a revision la version {{VersionLabel}} del curso {{CourseCode}} - {{CourseName}}.

Recuerda que quien crea el contenido no puede aprobarlo. Al publicar, la version queda firmada a tu nombre y no se puede modificar: cualquier cambio posterior requiere una version nueva.

Revisar: {{ReviewUrl}}

Classroom - Airlink Distribution DR')

,( N'Course.ReviewRequested', N'en-US', 1
, N'Review requested: {{CourseName}}'
, N'Hello {{ApproverName}},

{{AuthorName}} submitted version {{VersionLabel}} of course {{CourseCode}} - {{CourseName}} for review.

Remember that whoever authors content cannot approve it. Once published, the version is signed under your name and becomes immutable: any later change requires a new version.

Review: {{ReviewUrl}}

Classroom - Airlink Distribution DR')

/* --- Inscripcion asignada -------------------------------------------- */
,( N'Enrollment.Assigned', N'es-DO', 1
, N'Nuevo entrenamiento asignado: {{CourseName}}'
, N'Hola {{EmployeeName}},

Se te asigno el entrenamiento {{CourseName}}.

Fecha limite: {{DueDate}}
Motivo: {{AssignmentReason}}

Comenzar: {{CourseUrl}}

Si no puedes completarlo antes de la fecha limite, habla con tu supervisor.

Classroom - Airlink Distribution DR')

,( N'Enrollment.Assigned', N'en-US', 1
, N'New training assigned: {{CourseName}}'
, N'Hello {{EmployeeName}},

You have been assigned the training {{CourseName}}.

Due date: {{DueDate}}
Reason: {{AssignmentReason}}

Start: {{CourseUrl}}

If you cannot complete it before the due date, please talk to your supervisor.

Classroom - Airlink Distribution DR')

/* --- Intentos agotados ------------------------------------------------ */
,( N'Enrollment.AttemptsExhausted', N'es-DO', 1
, N'Intentos agotados: {{CourseName}}'
, N'Hola {{SupervisorName}},

{{EmployeeName}} ({{EmployeeCode}}) agoto los {{MaxAttempts}} intentos permitidos en {{CourseName}} sin aprobar.

Esto no se resuelve con otro intento. Conviene revisar si hace falta acompanamiento presencial o si el contenido no esta explicando bien el proceso.

Expediente: {{RecordUrl}}

Classroom - Airlink Distribution DR')

,( N'Enrollment.AttemptsExhausted', N'en-US', 1
, N'Attempts exhausted: {{CourseName}}'
, N'Hello {{SupervisorName}},

{{EmployeeName}} ({{EmployeeCode}}) has used all {{MaxAttempts}} allowed attempts on {{CourseName}} without passing.

Another attempt is unlikely to fix this. Consider whether hands-on coaching is needed, or whether the content is failing to explain the process.

Record: {{RecordUrl}}

Classroom - Airlink Distribution DR')

/* --- Certificacion emitida --------------------------------------------- */
,( N'Certification.Issued', N'es-DO', 1
, N'Certificacion emitida: {{CompetencyName}}'
, N'Felicidades {{EmployeeName}},

Quedaste certificado en {{CompetencyName}} - nivel {{LevelName}}.

Numero de certificado: {{CertificateNumber}}
Vigente hasta: {{ExpiresAt}}

Descargar certificado: {{CertificateUrl}}

Te avisaremos con tiempo antes del vencimiento para que coordines la recertificacion.

Classroom - Airlink Distribution DR')

,( N'Certification.Issued', N'en-US', 1
, N'Certification issued: {{CompetencyName}}'
, N'Congratulations {{EmployeeName}},

You are now certified in {{CompetencyName}} - level {{LevelName}}.

Certificate number: {{CertificateNumber}}
Valid until: {{ExpiresAt}}

Download certificate: {{CertificateUrl}}

We will notify you well in advance of expiry so you can schedule recertification.

Classroom - Airlink Distribution DR')

/* --- Certificacion por vencer ------------------------------------------- */
,( N'Certification.ExpiringSoon', N'es-DO', 1
, N'Tu certificacion vence en {{DaysRemaining}} dias: {{CompetencyName}}'
, N'Hola {{EmployeeName}},

Tu certificacion {{CertificateNumber}} en {{CompetencyName}} vence el {{ExpiresAtUtc}} ({{DaysRemaining}} dias).

Al vencer, dejas de estar autorizado para las estaciones que requieren esta competencia. Coordina la recertificacion con tu supervisor antes de esa fecha.

Recertificar: {{RenewUrl}}

Classroom - Airlink Distribution DR')

,( N'Certification.ExpiringSoon', N'en-US', 1
, N'Your certification expires in {{DaysRemaining}} days: {{CompetencyName}}'
, N'Hello {{EmployeeName}},

Your certification {{CertificateNumber}} in {{CompetencyName}} expires on {{ExpiresAtUtc}} ({{DaysRemaining}} days).

Once expired, you will no longer be authorized for stations requiring this competency. Please arrange recertification with your supervisor before that date.

Recertify: {{RenewUrl}}

Classroom - Airlink Distribution DR')

/* --- Re-entrenamiento por revision de documento (GAP-02) ---------------- */
,( N'Document.RetrainingRequired', N'es-DO', 1
, N'Re-entrenamiento requerido: {{DocumentCode}} {{RevisionLabel}}'
, N'Hola {{EmployeeName}},

Se activo una nueva revision del documento {{DocumentCode}} - {{DocumentTitle}} ({{RevisionLabel}}).

Tu certificacion en {{CompetencyName}} se apoyaba en la revision anterior, asi que quedo marcada para re-entrenamiento.

Que cambio: {{ChangeSummary}}
Fecha limite: {{DueDate}}

Completar: {{TrainingUrl}}

Esto no es un tramite. La instruccion de trabajo cambio y necesitamos constancia de que la conoces antes de que sigas ejecutando ese proceso.

Classroom - Airlink Distribution DR')

,( N'Document.RetrainingRequired', N'en-US', 1
, N'Retraining required: {{DocumentCode}} {{RevisionLabel}}'
, N'Hello {{EmployeeName}},

A new revision of document {{DocumentCode}} - {{DocumentTitle}} ({{RevisionLabel}}) has been activated.

Your certification in {{CompetencyName}} was based on the previous revision, so it has been flagged for retraining.

What changed: {{ChangeSummary}}
Due date: {{DueDate}}

Complete: {{TrainingUrl}}

This is not paperwork. The work instruction changed, and we need a record that you know it before you continue running that process.

Classroom - Airlink Distribution DR');

MERGE ops.NotificationTemplate AS tgt
USING @Templates AS src
ON tgt.TemplateKey = src.TemplateKey AND tgt.LocaleCode = src.LocaleCode AND tgt.Channel = src.Channel
WHEN MATCHED THEN UPDATE SET
      [Subject] = src.[Subject], BodyTemplate = src.BodyTemplate
    , IsActive = 1, ModifiedAtUtc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN INSERT (TemplateKey, LocaleCode, Channel, [Subject], BodyTemplate, IsActive)
    VALUES (src.TemplateKey, src.LocaleCode, src.Channel, src.[Subject], src.BodyTemplate, 1);

DECLARE @Cnt_ops_NotificationTemplate INT = (SELECT COUNT(*) FROM ops.NotificationTemplate);
PRINT CONCAT('Plantillas de notificacion: ', @Cnt_ops_NotificationTemplate);
GO

/* =====================================================================
   8. WATERMARKS DE INTEGRACION
   ===================================================================== */
MERGE intg.SyncWatermark AS tgt
USING (VALUES
      (N'SPN',     N'Employee',   N'Empleados desde el sistema de nomina.')
    , (N'SPN',     N'Position',   N'Titulos de posicion desde nomina.')
    , (N'AIRLINK', N'Station',    N'Estaciones de produccion (solo lectura).')
) AS src (SourceSystem, SourceEntity, Notes)
ON tgt.SourceSystem = src.SourceSystem AND tgt.SourceEntity = src.SourceEntity
WHEN NOT MATCHED THEN INSERT (SourceSystem, SourceEntity, IsEnabled)
    VALUES (src.SourceSystem, src.SourceEntity, 1);
GO

/* =====================================================================
   9. VERIFICACION FINAL

   Si alguna de estas cuentas sale en cero, el deploy quedo incompleto y
   el sistema va a negar accesos en silencio.
   ===================================================================== */
SELECT  N'Permisos'            AS Objeto, COUNT(*) AS Filas FROM sec.Permission
UNION ALL SELECT N'Roles',              COUNT(*) FROM sec.Role
UNION ALL SELECT N'Rol-Permiso',        COUNT(*) FROM sec.RolePermission
UNION ALL SELECT N'Mapeo grupos Entra', COUNT(*) FROM sec.RoleGroupMapping
UNION ALL SELECT N'Configuraciones',    COUNT(*) FROM ops.Setting
UNION ALL SELECT N'Feature flags',      COUNT(*) FROM ops.FeatureFlag
UNION ALL SELECT N'Plantillas notif.',  COUNT(*) FROM ops.NotificationTemplate
UNION ALL SELECT N'Watermarks',         COUNT(*) FROM intg.SyncWatermark;

/* Roles de sistema que quedaron sin ningun permiso. LEARNER es el unico
   que legitimamente aparece aqui: sus accesos se resuelven por
   pertenencia, no por permisos explicitos. Cualquier otro es un error. */
SELECT r.RoleCode, N'Rol de sistema sin permisos asignados' AS Aviso
FROM sec.Role r
WHERE r.IsSystem = 1
  AND r.RoleCode <> N'LEARNER'
  AND NOT EXISTS (SELECT 1 FROM sec.RolePermission rp WHERE rp.RoleId = r.RoleId);

COMMIT TRANSACTION;

PRINT '=== 99_seed_reference_data.sql completado ===';
PRINT 'Pendiente manual: reemplazar los GUID placeholder de sec.RoleGroupMapping con los ObjectId reales de Entra ID.';
GO

/* ############################################################################
   ARCHIVO: database/19_jobs_agent.sql
   ############################################################################ */
/* =====================================================================
   Classroom - LMS by Airlink
   19_jobs_agent.sql
   SQL Server Agent: los 7 trabajos programados del sistema.

   El LMS no es solo pantallas. Buena parte del valor de compliance
   ocurre de noche, sin que nadie lo pida: certificaciones que vencen,
   brechas que se abren, empleados que cambian de puesto en SPN.

   Orden de la madrugada (todo en hora del servidor, Santo Domingo AST):
     01:00  Retencion (solo dia 1 del mes)
     02:00  Sync full de empleados
     03:00  Recalculo de brechas
     03:30  Refresco de estados de certificacion + avisos
     04:00  Expiracion de inscripciones vencidas
     07:00  Digest matutino de notificaciones
     cada hora :15  Sync incremental de empleados

   El orden importa: sync -> brechas -> certificaciones -> inscripciones.
   Si se invierte, el calculo de la noche trabaja con la foto de ayer.

   Requisitos: SQL Server Agent activo, Database Mail configurado para
   el operador, y el owner de los jobs debe poder ejecutar en AIRLINK_KMS.
   ===================================================================== */

USE msdb;
GO
SET NOCOUNT ON;
PRINT '=== 19_jobs_agent.sql iniciado ===';
GO

/* ---------------------------------------------------------------------
   Parametros de despliegue. Ajustar antes de correr en cada entorno.
   --------------------------------------------------------------------- */
DECLARE @DatabaseName SYSNAME       = N'AIRLINK_KMS';
DECLARE @JobOwner     SYSNAME       = N'sa';                    -- cambiar por cuenta de servicio
DECLARE @Category     SYSNAME       = N'Classroom LMS';
DECLARE @OperatorName SYSNAME       = N'Airlink IT';            -- debe existir en msdb
DECLARE @NotifyOnFail BIT           = 1;

/* Categoria de jobs, para que no se pierdan entre los demas del server. */
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = @Category AND category_class = 1)
    EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = @Category;
GO

/* =====================================================================
   Helper: cada job se borra y recrea. Idempotente por diseno, para que
   el deploy no dependa del estado previo del servidor.
   ===================================================================== */

/* ---------------------------------------------------------------------
   JOB 1 - LMS - Employee Sync (Incremental)
   Cada hora, al minuto 15.

   Solo trae cambios desde el watermark. Es lo que hace que un cambio de
   puesto a las 9am se refleje en los requisitos del empleado a las 9:15,
   no manana.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Employee Sync (Incremental)')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Employee Sync (Incremental)', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Employee Sync (Incremental)'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Sincroniza empleados desde SPN usando el watermark. No borra nunca: las bajas se marcan inactivas.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Employee Sync (Incremental)'
    , @step_name = N'Run incremental sync'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_KMS'
    , @retry_attempts = 2
    , @retry_interval = 5
    , @command = N'
DECLARE @JobRunId BIGINT, @SyncRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''EmployeeSync.Incremental'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    /* Sin payload: el agente de integracion externo carga el staging
       con este SyncRunId y luego llama al Merge. Si en tu despliegue
       usas linked server, sustituye por la carga directa. */
    EXEC intg.usp_EmployeeSync_Run
          @RunMode = 1, @TriggeredBy = N''SqlAgent.Incremental''
        , @SyncRunId = @SyncRunId OUTPUT;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Corrida incremental iniciada.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Employee Sync (Incremental)'
    , @name = N'Hourly at :15'
    , @freq_type = 4                 -- diario
    , @freq_interval = 1
    , @freq_subday_type = 8          -- horas
    , @freq_subday_interval = 1
    , @active_start_time = 001500;   -- 00:15
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Employee Sync (Incremental)';
GO

/* ---------------------------------------------------------------------
   JOB 2 - LMS - Employee Sync (Full)
   Diario 02:00.

   Corre con @DeactivateMissing = 1: quien ya no aparece en SPN se marca
   inactivo. Solo en modo full, nunca en el incremental: un incremental
   incompleto desactivaria media planta.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Employee Sync (Full)')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Employee Sync (Full)', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Employee Sync (Full)'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Reconciliacion completa contra SPN. Desactiva empleados ausentes del origen. Nunca borra registros.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Employee Sync (Full)'
    , @step_name = N'Run full sync'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_KMS'
    , @retry_attempts = 1
    , @retry_interval = 10
    , @command = N'
DECLARE @JobRunId BIGINT, @SyncRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''EmployeeSync.Full'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    EXEC intg.usp_EmployeeSync_Run
          @RunMode = 2, @TriggeredBy = N''SqlAgent.Full''
        , @SyncRunId = @SyncRunId OUTPUT;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Corrida full iniciada.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Employee Sync (Full)'
    , @name = N'Daily 02:00'
    , @freq_type = 4, @freq_interval = 1
    , @active_start_time = 020000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Employee Sync (Full)';
GO

/* ---------------------------------------------------------------------
   JOB 3 - LMS - Gap Recalculation
   Diario 03:00. Despues del sync full, a proposito.

   Recorre todos los empleados activos y recalcula su estado contra los
   requisitos vigentes. Con auto-inscripcion de remediacion encendida:
   una brecha detectada de madrugada ya tiene curso asignado cuando el
   supervisor abre el tablero a las 7.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Gap Recalculation')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Gap Recalculation', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Gap Recalculation'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Recalcula brechas de competencia de todos los empleados activos y auto-inscribe remediacion.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Gap Recalculation'
    , @step_name = N'Recalculate all gaps'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_KMS'
    , @command = N'
DECLARE @JobRunId BIGINT, @Processed INT = 0;
EXEC ops.usp_JobRun_Start @JobName = N''Gap.RecalculateAll'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    DECLARE @Result TABLE (EmployeesProcessed INT, Errors INT);
    INSERT INTO @Result
    EXEC comp.usp_Gap_RecalculateAll @AutoEnroll = 1;

    SELECT @Processed = EmployeesProcessed FROM @Result;

    DECLARE @GapJobStatus TINYINT;
    SELECT @GapJobStatus = CASE WHEN Errors > 0 THEN 3 ELSE 2 END FROM @Result;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId
        , @Status = @GapJobStatus
        , @RecordsProcessed = @Processed
        , @Message = N''Brechas recalculadas.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Gap Recalculation'
    , @name = N'Daily 03:00'
    , @freq_type = 4, @freq_interval = 1
    , @active_start_time = 030000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Gap Recalculation';
GO

/* ---------------------------------------------------------------------
   JOB 4 - LMS - Certification Status Refresh
   Diario 03:30.

   Mueve Valid -> ExpiringSoon -> Expired respetando el periodo de gracia
   de cada requisito, y encola los avisos de 60/30/14/7/1 dias.
   Este es el job que evita la conversacion "nadie me aviso".
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Certification Status Refresh')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Certification Status Refresh', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Certification Status Refresh'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Actualiza estados de certificacion por vencimiento y encola avisos escalonados.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Certification Status Refresh'
    , @step_name = N'Refresh certification statuses'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_KMS'
    , @command = N'
DECLARE @JobRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''Certification.RefreshStatuses'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    EXEC comp.usp_Certification_RefreshStatuses @BatchSize = 5000;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Estados de certificacion actualizados.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Certification Status Refresh'
    , @name = N'Daily 03:30'
    , @freq_type = 4, @freq_interval = 1
    , @active_start_time = 033000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Certification Status Refresh';
GO

/* ---------------------------------------------------------------------
   JOB 5 - LMS - Enrollment Expiration
   Diario 04:00.

   Cierra inscripciones vencidas y abandona intentos de quiz colgados
   (pestana cerrada, tablet que se durmio). Sin esto, un operador queda
   trabado porque "ya tiene un intento en progreso" de hace tres dias.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Enrollment Expiration')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Enrollment Expiration', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Enrollment Expiration'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Expira inscripciones vencidas y cierra intentos de evaluacion abandonados.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Enrollment Expiration'
    , @step_name = N'Expire overdue enrollments'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_KMS'
    , @on_success_action = 3          -- pasa al siguiente paso
    , @command = N'
DECLARE @JobRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''Enrollment.ExpireOverdue'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    EXEC dlv.usp_Enrollment_ExpireOverdue @BatchSize = 2000;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Inscripciones vencidas procesadas.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Enrollment Expiration'
    , @step_name = N'Abandon stale quiz attempts'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_KMS'
    , @command = N'
DECLARE @JobRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''Assessment.AbandonExpired'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    EXEC asmt.usp_Attempt_AbandonExpired @GraceMinutes = 15, @BatchSize = 500;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Intentos abandonados cerrados.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Enrollment Expiration'
    , @name = N'Daily 04:00'
    , @freq_type = 4, @freq_interval = 1
    , @active_start_time = 040000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Enrollment Expiration';
GO

/* ---------------------------------------------------------------------
   JOB 6 - LMS - Notification Digest
   Lunes a viernes 07:00, y reintentos cada 10 minutos en horario laboral.

   Este job NO envia: marca la cola como lista y deja el envio al worker
   de la API (que tiene las credenciales de Graph/Teams). SQL Server no
   debe estar hablando SMTP con el mundo.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Notification Digest')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Notification Digest', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Notification Digest'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Prepara el resumen matutino y reporta el estado de la cola de notificaciones.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Notification Digest'
    , @step_name = N'Queue health check'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_KMS'
    , @command = N'
DECLARE @JobRunId BIGINT, @Pending INT, @Dead INT;
EXEC ops.usp_JobRun_Start @JobName = N''Notification.Digest'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    SELECT @Pending = COUNT(*) FROM ops.NotificationQueue WHERE [Status] = 1;
    SELECT @Dead    = COUNT(*) FROM ops.NotificationQueue WHERE [Status] = 5;

    /* Cola creciendo o dead-letter con contenido = el worker esta caido
       o mal configurado. Se marca Warning para que se vea en el tablero. */
    DECLARE @JobStatus TINYINT = CASE WHEN @Dead > 0 OR @Pending > 500 THEN 3 ELSE 2 END
          , @JobMessage NVARCHAR(200) = N''Pendientes: '' + CAST(@Pending AS NVARCHAR(12))
                                      + N'' | Dead-letter: '' + CAST(@Dead AS NVARCHAR(12));
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId
        , @Status = @JobStatus
        , @RecordsProcessed = @Pending
        , @Message = @JobMessage;
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Notification Digest'
    , @name = N'Weekdays 07:00'
    , @freq_type = 8                 -- semanal
    , @freq_interval = 62            -- lunes(2)+martes(4)+mie(8)+jue(16)+vie(32)
    , @freq_recurrence_factor = 1
    , @active_start_time = 070000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Notification Digest';
GO

/* ---------------------------------------------------------------------
   JOB 7 - LMS - Retention Policy
   Mensual, dia 1 a la 01:00.

   Limpia solo lo operativo (logs de info, notificaciones enviadas,
   staging, llaves de idempotencia vencidas).

   NO TOCA el expediente: firmas, certificaciones, evidencia,
   inscripciones, intentos ni evaluaciones practicas. Eso se conserva 7
   anos y su eventual depuracion se maneja como proyecto aparte con
   aprobacion de Calidad, no como job automatico.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Retention Policy')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Retention Policy', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Retention Policy'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Aplica retencion a datos operativos. Nunca toca evidencia de compliance.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Retention Policy'
    , @step_name = N'Apply retention'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_KMS'
    , @command = N'
DECLARE @JobRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''Retention.Apply'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    /* Lotes de 5000 por pasada para no inflar el log de transacciones. */
    DECLARE @i INT = 0;
    WHILE @i < 10
    BEGIN
        EXEC ops.usp_Retention_Apply @DryRun = 0, @BatchSize = 5000;
        SET @i = @i + 1;
    END;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Retencion aplicada.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Retention Policy'
    , @name = N'Monthly day 1 01:00'
    , @freq_type = 16                -- mensual
    , @freq_interval = 1             -- dia 1
    , @freq_recurrence_factor = 1
    , @active_start_time = 010000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Retention Policy';
GO

/* =====================================================================
   Notificacion de fallos

   Descomentar y ajustar @OperatorName una vez creado el operador en
   msdb. Sin esto los jobs fallan en silencio, que es la peor forma de
   fallar.
   ===================================================================== */
/*
DECLARE @op SYSNAME = N'Airlink IT';
DECLARE @j SYSNAME;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM msdb.dbo.sysjobs WHERE name LIKE N'LMS - %';
OPEN c; FETCH NEXT FROM c INTO @j;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_update_job
          @job_name = @j
        , @notify_level_email = 2          -- solo en fallo
        , @notify_email_operator_name = @op;
    FETCH NEXT FROM c INTO @j;
END;
CLOSE c; DEALLOCATE c;
*/

PRINT '=== 19_jobs_agent.sql completado ===';
PRINT 'Recuerda: ajustar @owner_login_name a la cuenta de servicio y habilitar la notificacion al operador.';
GO
