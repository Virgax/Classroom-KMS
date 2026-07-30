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

USE AIRLINK_LMS;
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
