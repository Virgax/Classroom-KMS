/* =============================================================================
   Classroom LMS by Airlink
   01_schemas.sql  -  Esquemas y permisos de esquema
   Idempotente.
   ============================================================================= */

USE AIRLINK_LMS;
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
