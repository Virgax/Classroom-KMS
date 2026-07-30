/* =====================================================================
   Mock local de SPN (nomina) para probar la integracion.
   Espeja la ESTRUCTURA REAL de SPN:
     - dbo.Empleados : Numero, Nombre, Apellido1, Apellido2, Cedula,
                       Estatus ('A' = activo), Departamento (codigo),
                       Posicion (codigo), Supervisor (Numero del jefe),
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
      Numero             NVARCHAR(30)  NOT NULL PRIMARY KEY  -- INT en SPN real; aqui texto para continuidad de las pruebas
    , Nombre             NVARCHAR(80)  NOT NULL
    , Apellido1          NVARCHAR(80)  NOT NULL
    , Apellido2          NVARCHAR(80)  NULL
    , Cedula             NVARCHAR(30)  NULL
    , Correo             NVARCHAR(200) NULL
    , Estatus            NCHAR(1)      NOT NULL DEFAULT N'A'   -- 'A' = activo
    , Departamento       INT           NULL
    , Posicion           INT           NULL
    , Supervisor         NVARCHAR(30)  NULL                    -- Numero del supervisor
    , Fecha_Nombramiento DATE          NULL
    , CONSTRAINT FK_Empleados_Departamento FOREIGN KEY (Departamento) REFERENCES dbo.Departamento (Codigo)
    , CONSTRAINT FK_Empleados_Posicion     FOREIGN KEY (Posicion)     REFERENCES dbo.Posiciones (Codigo)
);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.Empleados)
INSERT INTO dbo.Empleados (Numero, Nombre, Apellido1, Apellido2, Cedula, Correo, Estatus, Departamento, Posicion, Supervisor, Fecha_Nombramiento) VALUES
  (N'AL-0001', N'Ramona',     N'Peralta',   N'Gomez',      N'00112345671', N'rperalta@airlink.com.do',  N'A', 10, 100, NULL,      '2019-03-11')
, (N'AL-0002', N'Jose Luis',  N'Perez',     N'Ramirez',    N'00223456782', N'jperez@airlink.com.do',    N'A', 20, 200, N'AL-0001','2020-06-01')
, (N'AL-0003', N'Yokasta',    N'Minaya',    N'de la Cruz', N'00334567893', N'yminaya@airlink.com.do',   N'A', 30, 201, N'AL-0001','2020-09-15')
, (N'AL-0104', N'Francisco',  N'Tejada',    N'Nunez',      N'00445678904', N'ftejada@airlink.com.do',   N'A', 20, 300, N'AL-0002','2022-01-10')
, (N'AL-0105', N'Carolina',   N'Baez',      N'Santana',    N'00556789015', N'cbaez@airlink.com.do',     N'A', 20, 300, N'AL-0002','2022-02-21')
, (N'AL-0106', N'Miguel',     N'Castillo',  N'Reyes',      N'00667890126', N'mcastillo@airlink.com.do', N'A', 20, 301, N'AL-0002','2022-05-02')
, (N'AL-0107', N'Altagracia', N'Rosario',   N'Frias',      N'00778901237', N'arosario@airlink.com.do',  N'A', 20, 301, N'AL-0002','2023-04-17')
, (N'AL-0108', N'Wilkin',     N'Fernandez', N'Marte',      N'00889012348', N'wfernandez@airlink.com.do',N'A', 30, 302, N'AL-0003','2023-08-07')
, (N'AL-0109', N'Esperanza',  N'Duarte',    N'Polanco',    N'00990123459', N'eduarte@airlink.com.do',   N'A', 30, 302, N'AL-0003','2024-02-19')
, (N'AL-0110', N'Randy',      N'Mejia',     N'Suriel',     N'01001234560', N'rmejia@airlink.com.do',    N'A', 20, 303, N'AL-0002','2024-06-03')
, (N'AL-0111', N'Katherine',  N'Almonte',   N'Vargas',     N'01112345671', N'kalmonte@airlink.com.do',  N'A', 40, 400, N'AL-0001','2021-11-08')
, (N'AL-0112', N'Domingo',    N'Santos',    N'Beltre',     N'01223456782', N'dsantos@airlink.com.do',   N'T', 20, 300, N'AL-0002','2021-07-26');
  /* AL-0112 con Estatus 'T' (terminado): NO debe poder entrar al KMS */
GO
PRINT 'Mock SPN (estructura real) listo.';
GO
