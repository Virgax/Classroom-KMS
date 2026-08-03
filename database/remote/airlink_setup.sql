/* =============================================================================
   Classroom KMS - Setup de lectura en AIRLINK (produccion: THOR/IQC/BoxShipping)
   -----------------------------------------------------------------------------
   Correr EN la base AIRLINK del servidor 192.168.181.248,13999 como sysadmin
   (o un usuario con permiso de CREATE PROCEDURE en AIRLINK).

   T-SQL puro: corre en cualquier cliente (SSMS, DataGrip, sqlcmd).
   El principal de lectura es AlAppUser (el usuario read-only existente).
   Para usar otro, buscar/reemplazar AlAppUser en este archivo.

   Que hace:
     1. Verifica que el principal exista (no crea logins).
     2. Crea 3 procedures de LECTURA (los unicos puntos de acceso del KMS):
        - dbo.usp_KMS_Station_GetForSync                catalogo de estaciones
        - dbo.usp_KMS_ProductionHistory_GetForEmployee  contexto operacional
        - dbo.usp_KMS_OperatorQuality_GetSummary        correlacion de
          efectividad (ISO 9001 cl.7.2(c))
     3. Otorga EXECUTE sobre esos procedures.

   El KMS NUNCA escribe en AIRLINK. Si AIRLINK esta caido, el KMS sigue
   operando completo (solo se degrada el dashboard de correlacion).

   AJUSTE REQUERIDO: las secciones >>> AJUSTAR <<< mapean las tablas y
   columnas reales de THOR/Nexus. Nada mas se toca.

   Idempotente. Re-ejecutable.
   ============================================================================= */
USE AIRLINK;
GO
SET NOCOUNT ON;
GO

/* -----------------------------------------------------------------------------
   1. Verificar el principal
   -------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'AlAppUser')
    THROW 50000, 'El login AlAppUser no existe en la instancia.', 1;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'AlAppUser')
    CREATE USER [AlAppUser] FOR LOGIN [AlAppUser];
GO

/* -----------------------------------------------------------------------------
   2.1 Catalogo de estaciones -> alimenta org.Station en el KMS
   Contrato de salida (resultset):
     stationCode, stationName, processCode, equipmentName, lineCode, isActive
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_KMS_Station_GetForSync
AS
BEGIN
    SET NOCOUNT ON;

    /* ========================= >>> AJUSTAR <<< ===============================
       Mapear a la tabla real de estaciones de THOR/Nexus. Los alias NO se
       tocan. lineCode debe corresponder al codigo de area/linea que se
       registrara en org.Area del KMS (TESTING, CALIDAD, REFURB, EMPAQUE...).
       ======================================================================== */
    SELECT  s.Codigo    AS stationCode      -- 'RXR-01','IQC-03'
          , s.Nombre    AS stationName
          , s.Proceso   AS processCode      -- 'IP68-TEST','IQC','FLASH','BOXSHIP'
          , s.Equipo    AS equipmentName    -- 'Roxer SmartRox PATRICK'
          , s.Linea     AS lineCode
          , s.Activa    AS isActive
    FROM dbo.Estacion s;
    /* ========================= fin AJUSTAR ================================== */
END;
GO

/* -----------------------------------------------------------------------------
   2.2 Contexto operacional de un empleado: donde ha estado trabajando
   segun produccion (la fuente de verdad del piso, no la asignacion teorica).
   Contrato de salida (resultset agregado por estacion+proceso):
     stationCode, processCode, unitsProcessed, unitsFailed, firstSeenUtc, lastSeenUtc
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_KMS_ProductionHistory_GetForEmployee
      @EmployeeCode NVARCHAR(30)
    , @SinceUtc     DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @SinceUtc = ISNULL(@SinceUtc, DATEADD(DAY, -30, SYSUTCDATETIME()));

    /* ========================= >>> AJUSTAR <<< ===============================
       Fuente esperada: VW_HistoryUnitProcess (o la tabla de historia de
       proceso por unidad de THOR). Columnas minimas: codigo de empleado,
       codigo de estacion, proceso, resultado y fecha de proceso.
       ======================================================================== */
    SELECT  h.EstacionCodigo  AS stationCode
          , h.Proceso         AS processCode
          , COUNT(*)          AS unitsProcessed
          , SUM(CASE WHEN h.Resultado = N'FAIL' THEN 1 ELSE 0 END) AS unitsFailed
          , MIN(h.ProcesadoEn) AS firstSeenUtc
          , MAX(h.ProcesadoEn) AS lastSeenUtc
    FROM dbo.VW_HistoryUnitProcess h
    WHERE h.CodigoEmpleado = @EmployeeCode
      AND h.ProcesadoEn >= @SinceUtc
    GROUP BY h.EstacionCodigo, h.Proceso;
    /* ========================= fin AJUSTAR ================================== */
END;
GO

/* -----------------------------------------------------------------------------
   2.3 Correlacion de efectividad: tasa de fallas por operador
   Es la evidencia de "evaluar la efectividad de las acciones" (ISO 9001
   cl.7.2(c)). Un job nocturno del KMS trae este agregado a rpt.
   Contrato de salida (resultset por operador+proceso):
     employeeCode, processCode, unitsProcessed, unitsFailed, failRatePercent
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_KMS_OperatorQuality_GetSummary
      @FromUtc DATETIME2(3)
    , @ToUtc   DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @ToUtc = ISNULL(@ToUtc, SYSUTCDATETIME());

    /* ========================= >>> AJUSTAR <<< ===============================
       Misma fuente que 2.2. Si THOR distingue defecto atribuible al operador
       vs. defecto del equipo, filtrarlo aqui: la correlacion solo es justa
       con defectos atribuibles.
       ======================================================================== */
    SELECT  h.CodigoEmpleado AS employeeCode
          , h.Proceso        AS processCode
          , COUNT(*)         AS unitsProcessed
          , SUM(CASE WHEN h.Resultado = N'FAIL' THEN 1 ELSE 0 END) AS unitsFailed
          , CAST(100.0 * SUM(CASE WHEN h.Resultado = N'FAIL' THEN 1 ELSE 0 END)
                 / NULLIF(COUNT(*), 0) AS DECIMAL(5,2)) AS failRatePercent
    FROM dbo.VW_HistoryUnitProcess h
    WHERE h.ProcesadoEn >= @FromUtc AND h.ProcesadoEn < @ToUtc
    GROUP BY h.CodigoEmpleado, h.Proceso;
    /* ========================= fin AJUSTAR ================================== */
END;
GO

/* -----------------------------------------------------------------------------
   3. Permiso: EXECUTE sobre los 3 procedures
   (Si el principal es AlAppUser, ya trae SELECT read-only preexistente
   sobre AIRLINK; este script no lo amplia ni lo reduce. El contrato
   oficial del KMS son los procedures, no las tablas.)
   -------------------------------------------------------------------------- */
GRANT EXECUTE ON dbo.usp_KMS_Station_GetForSync               TO [AlAppUser];
GRANT EXECUTE ON dbo.usp_KMS_ProductionHistory_GetForEmployee TO [AlAppUser];
GRANT EXECUTE ON dbo.usp_KMS_OperatorQuality_GetSummary       TO [AlAppUser];
GO

/* -----------------------------------------------------------------------------
   4. Verificacion con la identidad real
   -------------------------------------------------------------------------- */
PRINT 'Verificando como AlAppUser...';
EXECUTE AS USER = N'AlAppUser';
BEGIN TRY
    EXEC dbo.usp_KMS_Station_GetForSync;
    PRINT 'OK: catalogo de estaciones legible via procedure.';
END TRY
BEGIN CATCH
    PRINT 'FALLO: ' + ERROR_MESSAGE();
END CATCH;
REVERT;
GO

PRINT '';
PRINT '=== AIRLINK listo para el KMS (principal: AlAppUser) ===';
GO
