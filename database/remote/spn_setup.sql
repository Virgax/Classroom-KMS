/* =============================================================================
   Classroom KMS - Setup de lectura en SPN (nomina)
   -----------------------------------------------------------------------------
   Correr EN la base SPN del servidor 192.168.181.248,13999 como sysadmin
   (o un usuario con permiso de CREATE PROCEDURE en SPN).

   Requiere sqlcmd (CLI o SSMS en modo SQLCMD). El principal que ejecutara
   la lectura es parametrizable; default: AlAppUser (el usuario read-only
   existente). Para cambiarlo sin editar el script:
       sqlcmd ... -v SyncPrincipal=AlLmsSyncUser -i spn_setup.sql

   NOTA sobre AlAppUser: antes de darle este acceso, rotar su contrasena
   (00_setup_database_roles.sql recuerda que fue expuesta en texto claro).
   AlAppUser SOLO lee SPN/AIRLINK; el usuario de aplicacion del KMS sobre
   AIRLINK_KMS sigue siendo el dedicado (AlLmsAppUser). No mezclarlos.

   Que hace:
     1. Verifica que el principal exista en SPN (no crea logins).
     2. Crea dbo.usp_KMS_Employee_GetForSync: el UNICO punto de lectura
        de empleados para el KMS. Contrato de salida fijo (JSON).
     3. Otorga EXECUTE sobre ese procedure.

   El KMS NUNCA escribe en SPN. Este script no toca datos ni tablas.

   AJUSTE REQUERIDO: la seccion marcada >>> AJUSTAR <<< mapea las
   columnas reales de SPN al contrato. Es el unico lugar que se toca si
   SPN cambia de esquema.

   Idempotente. Re-ejecutable.
   ============================================================================= */
:setvar SyncPrincipal AlAppUser

USE SPN;
GO
SET NOCOUNT ON;
GO

/* -----------------------------------------------------------------------------
   1. Verificar el principal (login de instancia + usuario en SPN)
   -------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$(SyncPrincipal)')
    THROW 50000, 'El login $(SyncPrincipal) no existe en la instancia.', 1;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$(SyncPrincipal)')
    CREATE USER [$(SyncPrincipal)] FOR LOGIN [$(SyncPrincipal)];
GO

/* -----------------------------------------------------------------------------
   2. Procedure de lectura para el KMS
   Contrato de salida (1 fila, 1 columna EmployeesJson):
     [{ "employeeCode", "firstName", "lastName", "fullName", "nationalId",
        "email", "positionTitle", "department", "site", "supervisorCode",
        "hireDate", "terminationDate", "employmentStatus" }]
   Este JSON es exactamente lo que consume intg.usp_EmployeeSync_LoadStaging
   en AIRLINK_KMS. NO cambiar los nombres de las propiedades.
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_KMS_Employee_GetForSync
    @ModifiedSince DATETIME2(3) = NULL   -- NULL = full sync; valor = incremental
AS
BEGIN
    SET NOCOUNT ON;

    SELECT (
        SELECT
        /* ======================= >>> AJUSTAR <<< =============================
           Mapear aqui las columnas REALES de SPN. Los alias (lado derecho)
           NO se tocan: son el contrato con el KMS.
           Tabla(s) origen: reemplazar dbo.Empleado por la tabla/vista real.
           ==================================================================== */
              e.Codigo            AS employeeCode      -- codigo de empleado (clave natural)
            , e.Nombre            AS firstName
            , e.Apellidos         AS lastName
            , CAST(NULL AS NVARCHAR(200)) AS fullName  -- solo si SPN no separa nombre/apellido
            , e.Cedula            AS nationalId        -- se enmascara en el KMS (****1234)
            , e.Correo            AS email
            , e.Puesto            AS positionTitle
            , e.Departamento      AS department
            , e.Sede              AS site
            , e.CodigoSupervisor  AS supervisorCode
            , e.FechaIngreso      AS hireDate
            , e.FechaSalida       AS terminationDate
            , e.Estatus           AS employmentStatus  -- 'ACTIVO','INACTIVO','TERMINADO','BAJA'...
        FROM dbo.Empleado e
        WHERE (@ModifiedSince IS NULL OR e.FechaModificacion >= @ModifiedSince)
        /* Si SPN no tiene columna de fecha de modificacion, dejar solo
           full sync: quitar el filtro y correr el job siempre en modo full
           (RunMode = 2). El hash por fila del KMS hace que el costo de un
           full diario sea bajo. */
        /* ======================= fin AJUSTAR ================================ */
        FOR JSON PATH
    ) AS EmployeesJson;
END;
GO

/* -----------------------------------------------------------------------------
   3. Permiso: EXECUTE sobre el procedure
   (Si el principal es AlAppUser, ya trae SELECT read-only preexistente
   sobre SPN; este script no lo amplia ni lo reduce. El contrato oficial
   del KMS es el procedure, no las tablas.)
   -------------------------------------------------------------------------- */
GRANT EXECUTE ON dbo.usp_KMS_Employee_GetForSync TO [$(SyncPrincipal)];
GO

/* -----------------------------------------------------------------------------
   4. Verificacion: probar con la identidad real
   -------------------------------------------------------------------------- */
PRINT 'Verificando como $(SyncPrincipal)...';
EXECUTE AS USER = N'$(SyncPrincipal)';
BEGIN TRY
    EXEC dbo.usp_KMS_Employee_GetForSync;   -- debe devolver el JSON
    PRINT 'OK: el procedure ejecuta con $(SyncPrincipal).';
END TRY
BEGIN CATCH
    PRINT 'FALLO: ' + ERROR_MESSAGE();
END CATCH;
REVERT;
GO

PRINT '';
PRINT '=== SPN listo para el KMS (principal: $(SyncPrincipal)) ===';
GO
