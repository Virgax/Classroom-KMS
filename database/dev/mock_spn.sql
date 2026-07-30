/* =====================================================================
   Mock local de SPN (nomina) para probar la integracion.
   Espeja la ESTRUCTURA REAL de SPN:
     - dbo.Empleados : codigo ('DR0002' — lo que el empleado teclea),
                       numero (2 — el entero del codigo sin letras),
                       nombre, apellido1, apellido2, cedula, correo,
                       Estatus ('A' = activo), Departamento (codigo),
                       Posicion (codigo), supervisor (NUMERO del jefe),
                       Fecha_Nombramiento
     - dbo.Departamento : Codigo, Descripcion
     - dbo.Posiciones   : Codigo, Descripcion
   El procedure de lectura es el mismo de database/remote/spn_setup.sql.
   ===================================================================== */
IF DB_ID(N'SPN') IS NULL CREATE DATABASE SPN;
GO
USE SPN;
GO

IF OBJECT_ID(N'dbo.Departamento', N'U') IS NULL
CREATE TABLE dbo.Departamento (
      Codigo      INT           NOT NULL PRIMARY KEY
    , Descripcion NVARCHAR(150) NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.Departamento)
INSERT INTO dbo.Departamento (Codigo, Descripcion) VALUES
  (10, N'Operaciones')
, (20, N'Produccion')
, (30, N'Calidad')
, (40, N'Recursos Humanos');
GO

IF OBJECT_ID(N'dbo.Posiciones', N'U') IS NULL
CREATE TABLE dbo.Posiciones (
      Codigo      INT           NOT NULL PRIMARY KEY
    , Descripcion NVARCHAR(150) NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.Posiciones)
INSERT INTO dbo.Posiciones (Codigo, Descripcion) VALUES
  (100, N'Gerente de Operaciones')
, (200, N'Supervisor de Piso')
, (201, N'Supervisor de Calidad')
, (300, N'Operador de Testing')
, (301, N'Operador de Refurbishment')
, (302, N'Operador QC')
, (303, N'Tecnico de Reparacion')
, (400, N'Entrenadora');
GO

IF OBJECT_ID(N'dbo.Empleados', N'U') IS NULL
CREATE TABLE dbo.Empleados (
      codigo             NVARCHAR(30)  NOT NULL PRIMARY KEY   -- 'DR0002'
    , numero             INT           NOT NULL UNIQUE        -- 2 (sin letras)
    , nombre             NVARCHAR(80)  NOT NULL
    , apellido1          NVARCHAR(80)  NOT NULL
    , apellido2          NVARCHAR(80)  NULL
    , cedula             NVARCHAR(30)  NULL
    , correo             NVARCHAR(200) NULL
    , Estatus            NCHAR(1)      NOT NULL DEFAULT N'A'  -- 'A' = activo
    , Departamento       INT           NULL
    , Posicion           INT           NULL
    , supervisor         INT           NULL                   -- NUMERO del supervisor
    , Fecha_Nombramiento DATE          NULL
    , CONSTRAINT FK_Empleados_Departamento FOREIGN KEY (Departamento) REFERENCES dbo.Departamento (Codigo)
    , CONSTRAINT FK_Empleados_Posicion     FOREIGN KEY (Posicion)     REFERENCES dbo.Posiciones (Codigo)
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.Empleados)
INSERT INTO dbo.Empleados (codigo, numero, nombre, apellido1, apellido2, cedula, correo, Estatus, Departamento, Posicion, supervisor, Fecha_Nombramiento) VALUES
  (N'DR0001', 1,   N'Ramona',     N'Peralta',   N'Gomez',      N'00112345671', N'rperalta@airlink.com.do',  N'A', 10, 100, NULL, '2019-03-11')
, (N'DR0002', 2,   N'Jose Luis',  N'Perez',     N'Ramirez',    N'00223456782', N'jperez@airlink.com.do',    N'A', 20, 200, 1,    '2020-06-01')
, (N'DR0003', 3,   N'Yokasta',    N'Minaya',    N'de la Cruz', N'00334567893', N'yminaya@airlink.com.do',   N'A', 30, 201, 1,    '2020-09-15')
, (N'DR0104', 104, N'Francisco',  N'Tejada',    N'Nunez',      N'00445678904', N'ftejada@airlink.com.do',   N'A', 20, 300, 2,    '2022-01-10')
, (N'DR0105', 105, N'Carolina',   N'Baez',      N'Santana',    N'00556789015', N'cbaez@airlink.com.do',     N'A', 20, 300, 2,    '2022-02-21')
, (N'DR0106', 106, N'Miguel',     N'Castillo',  N'Reyes',      N'00667890126', N'mcastillo@airlink.com.do', N'A', 20, 301, 2,    '2022-05-02')
, (N'DR0107', 107, N'Altagracia', N'Rosario',   N'Frias',      N'00778901237', N'arosario@airlink.com.do',  N'A', 20, 301, 2,    '2023-04-17')
, (N'DR0108', 108, N'Wilkin',     N'Fernandez', N'Marte',      N'00889012348', N'wfernandez@airlink.com.do',N'A', 30, 302, 3,    '2023-08-07')
, (N'DR0109', 109, N'Esperanza',  N'Duarte',    N'Polanco',    N'00990123459', N'eduarte@airlink.com.do',   N'A', 30, 302, 3,    '2024-02-19')
, (N'DR0110', 110, N'Randy',      N'Mejia',     N'Suriel',     N'01001234560', N'rmejia@airlink.com.do',    N'A', 20, 303, 2,    '2024-06-03')
, (N'DR0111', 111, N'Katherine',  N'Almonte',   N'Vargas',     N'01112345671', N'kalmonte@airlink.com.do',  N'A', 40, 400, 1,    '2021-11-08')
, (N'DR0112', 112, N'Domingo',    N'Santos',    N'Beltre',     N'01223456782', N'dsantos@airlink.com.do',   N'T', 20, 300, 2,    '2021-07-26');
  /* DR0112 con Estatus 'T' (terminado): NO debe poder entrar al KMS */
GO
PRINT 'Mock SPN (estructura real: codigo/numero) listo.';
GO
