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
   Cambiar el nombre por AIRLINK_LMS_DEV / _QA segun el entorno.
   -------------------------------------------------------------------------- */
DECLARE @DbName SYSNAME = N'AIRLINK_LMS';

IF DB_ID(@DbName) IS NULL
BEGIN
    DECLARE @sql NVARCHAR(MAX) = N'CREATE DATABASE ' + QUOTENAME(@DbName) + N';';
    EXEC sys.sp_executesql @sql;
    PRINT 'Base de datos creada: ' + @DbName;
END
ELSE
    PRINT 'Base de datos ya existe: ' + @DbName;
GO

USE AIRLINK_LMS;
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
           , DEFAULT_DATABASE = [AIRLINK_LMS];
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
           , DEFAULT_DATABASE = [AIRLINK_LMS];
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
           , DEFAULT_DATABASE = [AIRLINK_LMS];
    PRINT 'Login creado: AlLmsReportUser';
END
GO

/* -----------------------------------------------------------------------------
   3. Usuarios y roles en AIRLINK_LMS
   -------------------------------------------------------------------------- */
USE AIRLINK_LMS;
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
DENY SELECT, INSERT, UPDATE, DELETE ON DATABASE::[AIRLINK_LMS] TO [db_lms_app];
GO

-- Nadie de la aplicacion altera esquema
DENY ALTER, CONTROL, CREATE TABLE, CREATE PROCEDURE, CREATE VIEW
    ON DATABASE::[AIRLINK_LMS] TO [db_lms_app], [db_lms_sync], [db_lms_report];
GO

-- El rol de reporteria no ve nada fuera de rpt
DENY SELECT ON DATABASE::[AIRLINK_LMS] TO [db_lms_report];
GO

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
