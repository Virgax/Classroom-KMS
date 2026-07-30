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
           Mapeo REAL de SPN (confirmado):
             - dbo.Empleados     : Numero, Nombre, Apellido1, Apellido2,
                                   Cedula, Estatus ('A' = activo),
                                   Departamento, Posicion, Supervisor,
                                   Fecha_Nombramiento
             - dbo.Departamento  : Codigo -> Descripcion
             - dbo.Posiciones    : Codigo -> Descripcion
           Los alias (lado derecho) NO se tocan: son el contrato con el KMS.
           ==================================================================== */
              CAST(e.Numero AS NVARCHAR(30)) AS employeeCode   -- clave natural; sera el usuario de login
            , e.Nombre                       AS firstName
            , LTRIM(RTRIM(CONCAT(e.Apellido1, N' ', ISNULL(e.Apellido2, N'')))) AS lastName
            , e.Cedula                       AS nationalId     -- se enmascara en el KMS; ultimos 4 = PIN inicial
            , e.Correo                       AS email           -- quitar esta linea si Empleados no tiene correo
            , p.Descripcion                  AS positionTitle
            , d.Descripcion                  AS department
            /* SPN no tiene columna de sede y la operacion es planta unica:
               se fija la sede del KMS. Debe coincidir con org.Site.[Name]
               o SiteCode. Ajustar si algun dia hay mas de una planta. */
            , N'Santo Domingo'               AS site
            , sup.NumeroTexto                AS supervisorCode
            , e.Fecha_Nombramiento           AS hireDate
            /* Estatus: 'A' = activo. CUALQUIER otro valor entra como
               INACTIVO: el KMS lo desactiva y no puede iniciar sesion.
               Se incluyen los no-activos a proposito: asi la baja es
               explicita en cada corrida, no por ausencia. */
            , CASE WHEN e.Estatus = N'A' THEN N'ACTIVO' ELSE N'INACTIVO' END AS employmentStatus
        FROM dbo.Empleados e
        LEFT JOIN dbo.Departamento d ON d.Codigo = e.Departamento
        LEFT JOIN dbo.Posiciones   p ON p.Codigo = e.Posicion
        OUTER APPLY (SELECT CAST(s.Numero AS NVARCHAR(30)) AS NumeroTexto
                     FROM dbo.Empleados s WHERE s.Numero = e.Supervisor) sup
        /* SPN no expone fecha de modificacion: el sync corre siempre en
           modo FULL (RunMode = 2). El hash por fila del KMS hace que el
           costo del full diario sea bajo. @ModifiedSince queda ignorado. */
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
