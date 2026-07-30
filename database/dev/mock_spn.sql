/* =====================================================================
   Mock local de SPN (nomina) para probar la integracion.
   En el servidor real este procedure se crea en SPN con permisos de ese
   sistema; el contrato de salida es identico.
   ===================================================================== */
IF DB_ID(N'SPN') IS NULL CREATE DATABASE SPN;
GO
USE SPN;
GO
IF OBJECT_ID(N'dbo.Empleado', N'U') IS NULL
CREATE TABLE dbo.Empleado (
      EmpleadoId      INT           NOT NULL IDENTITY(1,1) PRIMARY KEY
    , Codigo          NVARCHAR(30)  NOT NULL UNIQUE
    , Nombre          NVARCHAR(80)  NOT NULL
    , Apellidos       NVARCHAR(80)  NOT NULL
    , Cedula          NVARCHAR(30)  NULL
    , Correo          NVARCHAR(200) NULL
    , Puesto          NVARCHAR(150) NULL
    , Departamento    NVARCHAR(150) NULL
    , Sede            NVARCHAR(100) NULL
    , CodigoSupervisor NVARCHAR(30) NULL
    , FechaIngreso    DATE          NULL
    , FechaSalida     DATE          NULL
    , Estatus         NVARCHAR(50)  NOT NULL DEFAULT N'ACTIVO'
    , FechaModificacion DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.Empleado)
INSERT INTO dbo.Empleado (Codigo, Nombre, Apellidos, Cedula, Correo, Puesto, Departamento, Sede, CodigoSupervisor, FechaIngreso, Estatus)
VALUES
  (N'AL-0001', N'Ramona',    N'Peralta Gomez',     N'00112345671', N'rperalta@airlink.com.do',  N'Gerente de Operaciones', N'Operaciones',   N'Santo Domingo', NULL,      '2019-03-11', N'ACTIVO')
, (N'AL-0002', N'Jose Luis', N'Perez Ramirez',     N'00223456782', N'jperez@airlink.com.do',    N'Supervisor de Piso',     N'Produccion',    N'Santo Domingo', N'AL-0001','2020-06-01', N'ACTIVO')
, (N'AL-0003', N'Yokasta',   N'Minaya de la Cruz', N'00334567893', N'yminaya@airlink.com.do',   N'Supervisor de Calidad',  N'Calidad',       N'Santo Domingo', N'AL-0001','2020-09-15', N'ACTIVO')
, (N'AL-0104', N'Francisco', N'Tejada Nunez',      N'00445678904', N'ftejada@airlink.com.do',   N'Operador de Testing',    N'Produccion',    N'Santo Domingo', N'AL-0002','2022-01-10', N'ACTIVO')
, (N'AL-0105', N'Carolina',  N'Baez Santana',      N'00556789015', N'cbaez@airlink.com.do',     N'Operador de Testing',    N'Produccion',    N'Santo Domingo', N'AL-0002','2022-02-21', N'ACTIVO')
, (N'AL-0106', N'Miguel',    N'Castillo Reyes',    N'00667890126', N'mcastillo@airlink.com.do', N'Operador de Refurbishment', N'Produccion', N'Santo Domingo', N'AL-0002','2022-05-02', N'ACTIVO')
, (N'AL-0107', N'Altagracia',N'Rosario Frias',     N'00778901237', N'arosario@airlink.com.do',  N'Operador de Refurbishment', N'Produccion', N'Santo Domingo', N'AL-0002','2023-04-17', N'ACTIVO')
, (N'AL-0108', N'Wilkin',    N'Fernandez Marte',   N'00889012348', N'wfernandez@airlink.com.do',N'Operador QC',            N'Calidad',       N'Santo Domingo', N'AL-0003','2023-08-07', N'ACTIVO')
, (N'AL-0109', N'Esperanza', N'Duarte Polanco',    N'00990123459', N'eduarte@airlink.com.do',   N'Operador QC',            N'Calidad',       N'Santo Domingo', N'AL-0003','2024-02-19', N'ACTIVO')
, (N'AL-0110', N'Randy',     N'Mejia Suriel',      N'01001234560', N'rmejia@airlink.com.do',    N'Tecnico de Reparacion',  N'Produccion',    N'Santo Domingo', N'AL-0002','2024-06-03', N'ACTIVO')
, (N'AL-0111', N'Katherine', N'Almonte Vargas',    N'01112345671', N'kalmonte@airlink.com.do',  N'Entrenadora',            N'Recursos Humanos', N'Santo Domingo', N'AL-0001','2021-11-08', N'ACTIVO')
, (N'AL-0112', N'Domingo',   N'Santos Beltre',     N'01223456782', N'dsantos@airlink.com.do',   N'Operador de Testing',    N'Produccion',    N'Santo Domingo', N'AL-0002','2021-07-26', N'ACTIVO');
GO

/* Procedure de LECTURA para el KMS. Contrato de salida: el JSON que
   consume intg.usp_EmployeeSync_LoadStaging. */
CREATE OR ALTER PROCEDURE dbo.usp_KMS_Employee_GetForSync
    @ModifiedSince DATETIME2(3) = NULL   -- NULL = full
AS
BEGIN
    SET NOCOUNT ON;
    SELECT (
        SELECT  e.Codigo          AS employeeCode
              , e.Nombre          AS firstName
              , e.Apellidos       AS lastName
              , e.Cedula          AS nationalId
              , e.Correo          AS email
              , e.Puesto          AS positionTitle
              , e.Departamento    AS department
              , e.Sede            AS site
              , e.CodigoSupervisor AS supervisorCode
              , e.FechaIngreso    AS hireDate
              , e.FechaSalida     AS terminationDate
              , e.Estatus         AS employmentStatus
        FROM dbo.Empleado e
        FOR JSON PATH
    ) AS EmployeesJson;
END;
GO
PRINT 'Mock SPN listo.';
GO
