/* =====================================================================
   Mock local de AIRLINK (produccion: THOR / IQC / BoxShipping).
   SOLO LECTURA desde el KMS. En el servidor real estos procedures de
   lectura se crean en AIRLINK con permisos de ese sistema; el contrato
   de salida es identico.
   ===================================================================== */
IF DB_ID(N'AIRLINK') IS NULL CREATE DATABASE AIRLINK;
GO
USE AIRLINK;
GO

/* Catalogo de estaciones reales de piso (THOR/Nexus) */
IF OBJECT_ID(N'dbo.Estacion', N'U') IS NULL
CREATE TABLE dbo.Estacion (
      EstacionId    INT           NOT NULL IDENTITY(1,1) PRIMARY KEY
    , Codigo        NVARCHAR(40)  NOT NULL UNIQUE      -- 'RXR-01'
    , Nombre        NVARCHAR(150) NOT NULL
    , Proceso       NVARCHAR(40)  NOT NULL             -- 'IP68-TEST','IQC','BOXSHIP'
    , Equipo        NVARCHAR(150) NULL
    , Linea         NVARCHAR(50)  NOT NULL             -- area/linea
    , Activa        BIT           NOT NULL DEFAULT 1
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.Estacion)
INSERT INTO dbo.Estacion (Codigo, Nombre, Proceso, Equipo, Linea) VALUES
  (N'RXR-01', N'Roxer IP68 Test 1',    N'IP68-TEST', N'Roxer SmartRox PATRICK', N'TESTING')
, (N'RXR-02', N'Roxer IP68 Test 2',    N'IP68-TEST', N'Roxer SmartRox SPONGEBOB', N'TESTING')
, (N'IQC-01', N'Incoming QC 1',        N'IQC',       NULL, N'CALIDAD')
, (N'IQC-02', N'Incoming QC 2',        N'IQC',       NULL, N'CALIDAD')
, (N'FLSH-01', N'Flasheo y Software 1',N'FLASH',     N'THOR Bench 1', N'REFURB')
, (N'BSH-01', N'Box Shipping 1',       N'BOXSHIP',   NULL, N'EMPAQUE');
GO

/* Historia de proceso por unidad: quien trabajo que unidad, donde, cuando */
IF OBJECT_ID(N'dbo.HistoryUnitProcess', N'U') IS NULL
CREATE TABLE dbo.HistoryUnitProcess (
      HistoryId     BIGINT        NOT NULL IDENTITY(1,1) PRIMARY KEY
    , IMEI          NVARCHAR(20)  NOT NULL
    , EstacionCodigo NVARCHAR(40) NOT NULL
    , Proceso       NVARCHAR(40)  NOT NULL
    , CodigoEmpleado NVARCHAR(30) NOT NULL
    , Resultado     NVARCHAR(10)  NOT NULL             -- 'PASS','FAIL'
    , ProcesadoEn   DATETIME2(3)  NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.HistoryUnitProcess)
INSERT INTO dbo.HistoryUnitProcess (IMEI, EstacionCodigo, Proceso, CodigoEmpleado, Resultado, ProcesadoEn) VALUES
  (N'350123450000001', N'RXR-01', N'IP68-TEST', N'AL-0104', N'PASS', DATEADD(DAY, -20, SYSUTCDATETIME()))
, (N'350123450000002', N'RXR-01', N'IP68-TEST', N'AL-0104', N'PASS', DATEADD(DAY, -18, SYSUTCDATETIME()))
, (N'350123450000003', N'RXR-01', N'IP68-TEST', N'AL-0104', N'FAIL', DATEADD(DAY, -12, SYSUTCDATETIME()))
, (N'350123450000004', N'RXR-01', N'IP68-TEST', N'AL-0104', N'PASS', DATEADD(DAY, -5,  SYSUTCDATETIME()))
, (N'350123450000005', N'RXR-02', N'IP68-TEST', N'AL-0105', N'PASS', DATEADD(DAY, -9,  SYSUTCDATETIME()))
, (N'350123450000006', N'IQC-01', N'IQC',       N'AL-0108', N'PASS', DATEADD(DAY, -3,  SYSUTCDATETIME()))
, (N'350123450000007', N'FLSH-01',N'FLASH',     N'AL-0106', N'PASS', DATEADD(DAY, -2,  SYSUTCDATETIME()));
GO

/* Vista de contrato para el KMS (doc 07 seccion 3.2) */
CREATE OR ALTER VIEW dbo.VW_HistoryUnitProcess
AS
SELECT IMEI, EstacionCodigo, Proceso, CodigoEmpleado, Resultado, ProcesadoEn
FROM dbo.HistoryUnitProcess;
GO

/* Procedure de LECTURA: catalogo de estaciones para sincronizar org.Station */
CREATE OR ALTER PROCEDURE dbo.usp_KMS_Station_GetForSync
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Codigo AS stationCode, Nombre AS stationName, Proceso AS processCode
         , Equipo AS equipmentName, Linea AS lineCode, Activa AS isActive
    FROM dbo.Estacion;
END;
GO

/* Procedure de LECTURA: donde ha trabajado un empleado (contexto operacional) */
CREATE OR ALTER PROCEDURE dbo.usp_KMS_ProductionHistory_GetForEmployee
      @CodigoEmpleado NVARCHAR(30)
    , @DesdeUtc       DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @DesdeUtc = ISNULL(@DesdeUtc, DATEADD(DAY, -30, SYSUTCDATETIME()));
    SELECT EstacionCodigo, Proceso, COUNT(*) AS Unidades
         , SUM(CASE WHEN Resultado = N'FAIL' THEN 1 ELSE 0 END) AS Fallas
         , MIN(ProcesadoEn) AS PrimeraVez, MAX(ProcesadoEn) AS UltimaVez
    FROM dbo.HistoryUnitProcess
    WHERE CodigoEmpleado = @CodigoEmpleado AND ProcesadoEn >= @DesdeUtc
    GROUP BY EstacionCodigo, Proceso;
END;
GO
PRINT 'Mock AIRLINK listo.';
GO
