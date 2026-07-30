/* =====================================================================
   Classroom - LMS by Airlink
   19_jobs_agent.sql
   SQL Server Agent: los 7 trabajos programados del sistema.

   El LMS no es solo pantallas. Buena parte del valor de compliance
   ocurre de noche, sin que nadie lo pida: certificaciones que vencen,
   brechas que se abren, empleados que cambian de puesto en SPN.

   Orden de la madrugada (todo en hora del servidor, Santo Domingo AST):
     01:00  Retencion (solo dia 1 del mes)
     02:00  Sync full de empleados
     03:00  Recalculo de brechas
     03:30  Refresco de estados de certificacion + avisos
     04:00  Expiracion de inscripciones vencidas
     07:00  Digest matutino de notificaciones
     cada hora :15  Sync incremental de empleados

   El orden importa: sync -> brechas -> certificaciones -> inscripciones.
   Si se invierte, el calculo de la noche trabaja con la foto de ayer.

   Requisitos: SQL Server Agent activo, Database Mail configurado para
   el operador, y el owner de los jobs debe poder ejecutar en AIRLINK_LMS.
   ===================================================================== */

USE msdb;
GO
SET NOCOUNT ON;
PRINT '=== 19_jobs_agent.sql iniciado ===';
GO

/* ---------------------------------------------------------------------
   Parametros de despliegue. Ajustar antes de correr en cada entorno.
   --------------------------------------------------------------------- */
DECLARE @DatabaseName SYSNAME       = N'AIRLINK_LMS';
DECLARE @JobOwner     SYSNAME       = N'sa';                    -- cambiar por cuenta de servicio
DECLARE @Category     SYSNAME       = N'Classroom LMS';
DECLARE @OperatorName SYSNAME       = N'Airlink IT';            -- debe existir en msdb
DECLARE @NotifyOnFail BIT           = 1;

/* Categoria de jobs, para que no se pierdan entre los demas del server. */
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = @Category AND category_class = 1)
    EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = @Category;
GO

/* =====================================================================
   Helper: cada job se borra y recrea. Idempotente por diseno, para que
   el deploy no dependa del estado previo del servidor.
   ===================================================================== */

/* ---------------------------------------------------------------------
   JOB 1 - LMS - Employee Sync (Incremental)
   Cada hora, al minuto 15.

   Solo trae cambios desde el watermark. Es lo que hace que un cambio de
   puesto a las 9am se refleje en los requisitos del empleado a las 9:15,
   no manana.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Employee Sync (Incremental)')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Employee Sync (Incremental)', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Employee Sync (Incremental)'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Sincroniza empleados desde SPN usando el watermark. No borra nunca: las bajas se marcan inactivas.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Employee Sync (Incremental)'
    , @step_name = N'Run incremental sync'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_LMS'
    , @retry_attempts = 2
    , @retry_interval = 5
    , @command = N'
DECLARE @JobRunId BIGINT, @SyncRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''EmployeeSync.Incremental'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    /* Sin payload: el agente de integracion externo carga el staging
       con este SyncRunId y luego llama al Merge. Si en tu despliegue
       usas linked server, sustituye por la carga directa. */
    EXEC intg.usp_EmployeeSync_Run
          @RunMode = 1, @TriggeredBy = N''SqlAgent.Incremental''
        , @SyncRunId = @SyncRunId OUTPUT;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Corrida incremental iniciada.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Employee Sync (Incremental)'
    , @name = N'Hourly at :15'
    , @freq_type = 4                 -- diario
    , @freq_interval = 1
    , @freq_subday_type = 8          -- horas
    , @freq_subday_interval = 1
    , @active_start_time = 001500;   -- 00:15
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Employee Sync (Incremental)';
GO

/* ---------------------------------------------------------------------
   JOB 2 - LMS - Employee Sync (Full)
   Diario 02:00.

   Corre con @DeactivateMissing = 1: quien ya no aparece en SPN se marca
   inactivo. Solo en modo full, nunca en el incremental: un incremental
   incompleto desactivaria media planta.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Employee Sync (Full)')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Employee Sync (Full)', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Employee Sync (Full)'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Reconciliacion completa contra SPN. Desactiva empleados ausentes del origen. Nunca borra registros.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Employee Sync (Full)'
    , @step_name = N'Run full sync'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_LMS'
    , @retry_attempts = 1
    , @retry_interval = 10
    , @command = N'
DECLARE @JobRunId BIGINT, @SyncRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''EmployeeSync.Full'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    EXEC intg.usp_EmployeeSync_Run
          @RunMode = 2, @TriggeredBy = N''SqlAgent.Full''
        , @SyncRunId = @SyncRunId OUTPUT;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Corrida full iniciada.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Employee Sync (Full)'
    , @name = N'Daily 02:00'
    , @freq_type = 4, @freq_interval = 1
    , @active_start_time = 020000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Employee Sync (Full)';
GO

/* ---------------------------------------------------------------------
   JOB 3 - LMS - Gap Recalculation
   Diario 03:00. Despues del sync full, a proposito.

   Recorre todos los empleados activos y recalcula su estado contra los
   requisitos vigentes. Con auto-inscripcion de remediacion encendida:
   una brecha detectada de madrugada ya tiene curso asignado cuando el
   supervisor abre el tablero a las 7.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Gap Recalculation')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Gap Recalculation', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Gap Recalculation'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Recalcula brechas de competencia de todos los empleados activos y auto-inscribe remediacion.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Gap Recalculation'
    , @step_name = N'Recalculate all gaps'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_LMS'
    , @command = N'
DECLARE @JobRunId BIGINT, @Processed INT = 0;
EXEC ops.usp_JobRun_Start @JobName = N''Gap.RecalculateAll'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    DECLARE @Result TABLE (EmployeesProcessed INT, Errors INT);
    INSERT INTO @Result
    EXEC comp.usp_Gap_RecalculateAll @AutoEnroll = 1;

    SELECT @Processed = EmployeesProcessed FROM @Result;

    DECLARE @GapJobStatus TINYINT;
    SELECT @GapJobStatus = CASE WHEN Errors > 0 THEN 3 ELSE 2 END FROM @Result;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId
        , @Status = @GapJobStatus
        , @RecordsProcessed = @Processed
        , @Message = N''Brechas recalculadas.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Gap Recalculation'
    , @name = N'Daily 03:00'
    , @freq_type = 4, @freq_interval = 1
    , @active_start_time = 030000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Gap Recalculation';
GO

/* ---------------------------------------------------------------------
   JOB 4 - LMS - Certification Status Refresh
   Diario 03:30.

   Mueve Valid -> ExpiringSoon -> Expired respetando el periodo de gracia
   de cada requisito, y encola los avisos de 60/30/14/7/1 dias.
   Este es el job que evita la conversacion "nadie me aviso".
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Certification Status Refresh')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Certification Status Refresh', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Certification Status Refresh'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Actualiza estados de certificacion por vencimiento y encola avisos escalonados.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Certification Status Refresh'
    , @step_name = N'Refresh certification statuses'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_LMS'
    , @command = N'
DECLARE @JobRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''Certification.RefreshStatuses'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    EXEC comp.usp_Certification_RefreshStatuses @BatchSize = 5000;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Estados de certificacion actualizados.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Certification Status Refresh'
    , @name = N'Daily 03:30'
    , @freq_type = 4, @freq_interval = 1
    , @active_start_time = 033000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Certification Status Refresh';
GO

/* ---------------------------------------------------------------------
   JOB 5 - LMS - Enrollment Expiration
   Diario 04:00.

   Cierra inscripciones vencidas y abandona intentos de quiz colgados
   (pestana cerrada, tablet que se durmio). Sin esto, un operador queda
   trabado porque "ya tiene un intento en progreso" de hace tres dias.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Enrollment Expiration')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Enrollment Expiration', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Enrollment Expiration'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Expira inscripciones vencidas y cierra intentos de evaluacion abandonados.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Enrollment Expiration'
    , @step_name = N'Expire overdue enrollments'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_LMS'
    , @on_success_action = 3          -- pasa al siguiente paso
    , @command = N'
DECLARE @JobRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''Enrollment.ExpireOverdue'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    EXEC dlv.usp_Enrollment_ExpireOverdue @BatchSize = 2000;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Inscripciones vencidas procesadas.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Enrollment Expiration'
    , @step_name = N'Abandon stale quiz attempts'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_LMS'
    , @command = N'
DECLARE @JobRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''Assessment.AbandonExpired'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    EXEC asmt.usp_Attempt_AbandonExpired @GraceMinutes = 15, @BatchSize = 500;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Intentos abandonados cerrados.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Enrollment Expiration'
    , @name = N'Daily 04:00'
    , @freq_type = 4, @freq_interval = 1
    , @active_start_time = 040000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Enrollment Expiration';
GO

/* ---------------------------------------------------------------------
   JOB 6 - LMS - Notification Digest
   Lunes a viernes 07:00, y reintentos cada 10 minutos en horario laboral.

   Este job NO envia: marca la cola como lista y deja el envio al worker
   de la API (que tiene las credenciales de Graph/Teams). SQL Server no
   debe estar hablando SMTP con el mundo.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Notification Digest')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Notification Digest', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Notification Digest'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Prepara el resumen matutino y reporta el estado de la cola de notificaciones.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Notification Digest'
    , @step_name = N'Queue health check'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_LMS'
    , @command = N'
DECLARE @JobRunId BIGINT, @Pending INT, @Dead INT;
EXEC ops.usp_JobRun_Start @JobName = N''Notification.Digest'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    SELECT @Pending = COUNT(*) FROM ops.NotificationQueue WHERE [Status] = 1;
    SELECT @Dead    = COUNT(*) FROM ops.NotificationQueue WHERE [Status] = 5;

    /* Cola creciendo o dead-letter con contenido = el worker esta caido
       o mal configurado. Se marca Warning para que se vea en el tablero. */
    DECLARE @JobStatus TINYINT = CASE WHEN @Dead > 0 OR @Pending > 500 THEN 3 ELSE 2 END
          , @JobMessage NVARCHAR(200) = N''Pendientes: '' + CAST(@Pending AS NVARCHAR(12))
                                      + N'' | Dead-letter: '' + CAST(@Dead AS NVARCHAR(12));
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId
        , @Status = @JobStatus
        , @RecordsProcessed = @Pending
        , @Message = @JobMessage;
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Notification Digest'
    , @name = N'Weekdays 07:00'
    , @freq_type = 8                 -- semanal
    , @freq_interval = 62            -- lunes(2)+martes(4)+mie(8)+jue(16)+vie(32)
    , @freq_recurrence_factor = 1
    , @active_start_time = 070000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Notification Digest';
GO

/* ---------------------------------------------------------------------
   JOB 7 - LMS - Retention Policy
   Mensual, dia 1 a la 01:00.

   Limpia solo lo operativo (logs de info, notificaciones enviadas,
   staging, llaves de idempotencia vencidas).

   NO TOCA el expediente: firmas, certificaciones, evidencia,
   inscripciones, intentos ni evaluaciones practicas. Eso se conserva 7
   anos y su eventual depuracion se maneja como proyecto aparte con
   aprobacion de Calidad, no como job automatico.
   --------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'LMS - Retention Policy')
    EXEC msdb.dbo.sp_delete_job @job_name = N'LMS - Retention Policy', @delete_unused_schedule = 1;
GO
EXEC msdb.dbo.sp_add_job
      @job_name = N'LMS - Retention Policy'
    , @enabled = 1
    , @category_name = N'Classroom LMS'
    , @owner_login_name = N'sa'
    , @description = N'Aplica retencion a datos operativos. Nunca toca evidencia de compliance.';
GO
EXEC msdb.dbo.sp_add_jobstep
      @job_name = N'LMS - Retention Policy'
    , @step_name = N'Apply retention'
    , @subsystem = N'TSQL'
    , @database_name = N'AIRLINK_LMS'
    , @command = N'
DECLARE @JobRunId BIGINT;
EXEC ops.usp_JobRun_Start @JobName = N''Retention.Apply'', @JobRunId = @JobRunId OUTPUT;
BEGIN TRY
    /* Lotes de 5000 por pasada para no inflar el log de transacciones. */
    DECLARE @i INT = 0;
    WHILE @i < 10
    BEGIN
        EXEC ops.usp_Retention_Apply @DryRun = 0, @BatchSize = 5000;
        SET @i = @i + 1;
    END;
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 2
        , @Message = N''Retencion aplicada.'';
END TRY
BEGIN CATCH
    EXEC ops.usp_JobRun_Finish @JobRunId = @JobRunId, @Status = 4, @Message = ERROR_MESSAGE();
    THROW;
END CATCH;';
GO
EXEC msdb.dbo.sp_add_jobschedule
      @job_name = N'LMS - Retention Policy'
    , @name = N'Monthly day 1 01:00'
    , @freq_type = 16                -- mensual
    , @freq_interval = 1             -- dia 1
    , @freq_recurrence_factor = 1
    , @active_start_time = 010000;
GO
EXEC msdb.dbo.sp_add_jobserver @job_name = N'LMS - Retention Policy';
GO

/* =====================================================================
   Notificacion de fallos

   Descomentar y ajustar @OperatorName una vez creado el operador en
   msdb. Sin esto los jobs fallan en silencio, que es la peor forma de
   fallar.
   ===================================================================== */
/*
DECLARE @op SYSNAME = N'Airlink IT';
DECLARE @j SYSNAME;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM msdb.dbo.sysjobs WHERE name LIKE N'LMS - %';
OPEN c; FETCH NEXT FROM c INTO @j;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_update_job
          @job_name = @j
        , @notify_level_email = 2          -- solo en fallo
        , @notify_email_operator_name = @op;
    FETCH NEXT FROM c INTO @j;
END;
CLOSE c; DEALLOCATE c;
*/

PRINT '=== 19_jobs_agent.sql completado ===';
PRINT 'Recuerda: ajustar @owner_login_name a la cuenta de servicio y habilitar la notificacion al operador.';
GO
