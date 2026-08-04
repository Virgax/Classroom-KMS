/* =====================================================================
   Classroom - LMS by Airlink
   18_procs_platform.sql
   Esquemas: aud (auditoria, firmas) + ops (notificaciones, settings,
             flags, archivos, jobs, retencion)

   Este archivo es dependencia de TODOS los demas: cada SP de negocio
   llama a aud.usp_Error_Log, aud.usp_Event_Log, aud.usp_Signature_Create
   u ops.usp_Notification_Enqueue. Por eso se despliega antes en el
   orden de ejecucion aunque lleve numero 18 (ver scripts/deploy-db.ps1,
   que reordena: 18 corre justo despues de las vistas).

   La pieza critica es la CADENA DE FIRMAS (GAP-06):

     firma[n].PreviousHash = firma[n-1].PayloadHash   (por empleado)

   Si alguien edita una fila del historial, el PayloadHash deja de
   cuadrar con el PreviousHash de la siguiente y la verificacion lo
   canta. Eso convierte "confien en nosotros" en "verifiquenlo ustedes".

   Codigos de error de este archivo: 50700-50799
   ===================================================================== */

USE AIRLINK_KMS;
GO
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
PRINT '=== 18_procs_platform.sql iniciado ===';
GO

/* =====================================================================
   aud.usp_Error_Log

   Se llama SIEMPRE desde el CATCH. Nunca lanza: si el logger falla, se
   traga el error. Un fallo del logger no puede convertirse en el error
   que ve el usuario en vez del error real.
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_Error_Log
      @ProcedureName  NVARCHAR(150) = NULL
    , @ActorUserId    INT           = NULL
    , @ParametersJson NVARCHAR(MAX) = NULL
    , @CorrelationId  UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        INSERT INTO aud.ErrorLog (ProcedureName, ErrorNumber, ErrorSeverity, ErrorState
                                , ErrorLine, ErrorMessage, ActorUserId, ParametersJson, CorrelationId)
        VALUES (ISNULL(@ProcedureName, ERROR_PROCEDURE())
              , ERROR_NUMBER(), ERROR_SEVERITY(), ERROR_STATE()
              , ERROR_LINE(), ERROR_MESSAGE(), @ActorUserId, @ParametersJson, @CorrelationId);
    END TRY
    BEGIN CATCH
        /* Silencio intencional. */
    END CATCH;
    RETURN 0;
END;
GO

/* =====================================================================
   aud.usp_Event_Log

   Bitacora de negocio. La firma de parametros usa @EventType con formato
   'Entidad.Accion' porque asi lo llaman los SPs de negocio; aqui se
   parte y se guarda en las columnas reales EntityType / [Action].
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_Event_Log
      @EventType     NVARCHAR(120)
    , @EntityType    NVARCHAR(60)  = NULL
    , @EntityId      INT           = NULL
    , @EntityPublicId UNIQUEIDENTIFIER = NULL
    , @EmployeeId    INT           = NULL
    , @ActorUserId   INT           = NULL
    , @Severity      TINYINT       = 1
    , @Summary       NVARCHAR(1000) = NULL
    , @OldValuesJson NVARCHAR(MAX) = NULL
    , @NewValuesJson NVARCHAR(MAX) = NULL
    , @SessionId     UNIQUEIDENTIFIER = NULL
    , @DeviceId      INT           = NULL
    , @IpAddress     NVARCHAR(45)  = NULL
    , @CorrelationId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @Dot INT = CHARINDEX(N'.', @EventType);

        INSERT INTO aud.EventLog (ActorUserId, ActorEmployeeId, EntityType, EntityId, EntityPublicId
                                , [Action], Severity, [Description]
                                , OldValuesJson, NewValuesJson, ProcedureName
                                , SessionId, DeviceId, IpAddress, CorrelationId)
        VALUES ( @ActorUserId
               , COALESCE(@EmployeeId, (SELECT EmployeeId FROM sec.[User] WHERE UserId = @ActorUserId))
               , COALESCE(@EntityType, CASE WHEN @Dot > 1 THEN LEFT(@EventType, @Dot - 1) ELSE @EventType END)
               , @EntityId
               , @EntityPublicId
               , CASE WHEN @Dot > 0 THEN SUBSTRING(@EventType, @Dot + 1, 60) ELSE @EventType END
               , ISNULL(@Severity, 1)
               , @Summary
               , @OldValuesJson, @NewValuesJson, ERROR_PROCEDURE()
               , @SessionId, @DeviceId, @IpAddress, @CorrelationId);
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'aud.usp_Event_Log', @ActorUserId = @ActorUserId;
    END CATCH;
    RETURN 0;
END;
GO

/* =====================================================================
   aud.usp_Signature_Create        -- GAP-06, el corazon de la evidencia

   Una firma es: el payload canonico de lo que se firmo, su hash, y el
   hash de la firma anterior de ESE MISMO empleado. Con eso queda una
   cadena por persona que no se puede reordenar ni editar en silencio.

   El UPDLOCK/HOLDLOCK sobre la ultima firma del empleado es lo que
   evita que dos firmas concurrentes tomen el mismo SequenceNumber. La
   restriccion UQ_SignatureRecord_Sequence es la red de seguridad si
   aun asi se cuela una carrera.

   @SignatureMeaning llega como texto desde los SPs de negocio
   ('Acknowledged','Evaluated','Certified','Approved','Reviewed') y se
   traduce al TINYINT SignatureType que guarda la tabla.
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_Signature_Create
      @ActorUserId       INT
    , @SignatureMeaning  NVARCHAR(40)
    , @EntityType        NVARCHAR(60)
    , @EntityId          INT
    , @PayloadCanonical  NVARCHAR(MAX)
    , @AuthMethod        TINYINT       = 1
    , @EmployeeId        INT           = NULL
    , @DeviceId          INT           = NULL
    , @IpAddress         NVARCHAR(45)  = NULL
    , @SignatureRecordId BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* Errores: 50701 el usuario no tiene empleado asociado
                50702 payload vacio
                50703 payload demasiado largo                            */
    BEGIN TRY
        IF @PayloadCanonical IS NULL OR LEN(@PayloadCanonical) = 0
            THROW 50702, 'No se puede firmar un payload vacio.', 1;

        /* La columna guarda 2000 chars: es una huella, no el documento.
           Si el payload viene mas largo, el llamador esta metiendo datos
           que no pertenecen a la firma. */
        IF LEN(@PayloadCanonical) > 2000
            THROW 50703, 'El payload canonico de la firma excede 2000 caracteres.', 1;

        SELECT @EmployeeId = COALESCE(@EmployeeId, EmployeeId)
        FROM sec.[User] WHERE UserId = @ActorUserId;

        IF @EmployeeId IS NULL
            THROW 50701, 'El usuario que firma no tiene empleado asociado.', 1;

        DECLARE @SignatureType TINYINT = CASE @SignatureMeaning
                    WHEN N'Acknowledged' THEN 1
                    WHEN N'Attended'     THEN 2
                    WHEN N'Roster'       THEN 3
                    WHEN N'Evaluated'    THEN 4
                    WHEN N'Evaluatee'    THEN 5
                    WHEN N'Certified'    THEN 6
                    WHEN N'Waiver'       THEN 7
                    WHEN N'Approved'     THEN 8
                    WHEN N'Reviewed'     THEN 8
                    WHEN N'Submitted'    THEN 9
                    ELSE 1 END;

        DECLARE @PayloadHash  VARBINARY(32) = HASHBYTES('SHA2_256', @PayloadCanonical)
              , @PreviousHash VARBINARY(32)
              , @Sequence     INT;

        DECLARE @OwnsTran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;
        IF @OwnsTran = 1 BEGIN TRANSACTION;

        /* Ultimo eslabon de la cadena de ESTE empleado. El lock se
           sostiene hasta el commit: es lo que serializa las firmas
           concurrentes de la misma persona. */
        SELECT TOP (1) @PreviousHash = s.PayloadHash, @Sequence = s.SequenceNumber
        FROM aud.SignatureRecord s WITH (UPDLOCK, HOLDLOCK)
        WHERE s.EmployeeId = @EmployeeId
        ORDER BY s.SequenceNumber DESC;

        SET @Sequence = ISNULL(@Sequence, 0) + 1;   -- 1 = genesis, PreviousHash NULL

        INSERT INTO aud.SignatureRecord (EmployeeId, UserId, SignatureType, EntityType, EntityId
                                       , PayloadCanonical, PayloadHash, PreviousHash, SequenceNumber
                                       , AuthMethod, DeviceId, IpAddress)
        VALUES (@EmployeeId, @ActorUserId, @SignatureType, @EntityType, @EntityId
              , @PayloadCanonical, @PayloadHash, @PreviousHash, @Sequence
              , @AuthMethod, @DeviceId, @IpAddress);

        SET @SignatureRecordId = SCOPE_IDENTITY();

        IF @OwnsTran = 1 COMMIT TRANSACTION;

        SELECT @SignatureRecordId AS SignatureId, @Sequence AS SequenceNumber
             , CONVERT(NVARCHAR(64), @PayloadHash, 2) AS PayloadHashHex;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF @OwnsTran = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'aud.usp_Signature_Create', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   aud.usp_Signature_Verify

   Recorre las cadenas y reporta el primer eslabon roto de cada empleado.
   Dos comprobaciones independientes por fila:
     1. Recalcular SHA-256 del payload y compararlo con PayloadHash
        -> detecta edicion del contenido firmado.
     2. Comparar PreviousHash con el PayloadHash de la firma anterior
        -> detecta insercion, borrado o reordenamiento de filas.

   Este resultset va dentro del paquete de auditoria (rpt.usp_AuditEvidence_
   GeneratePackage). Es la diferencia entre un reporte y una prueba.
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_Signature_Verify
      @ActorUserId INT          = NULL
    , @EmployeeId  INT          = NULL
    , @FromUtc     DATETIME2(3) = NULL
    , @ToUtc       DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        SET @FromUtc = ISNULL(@FromUtc, '1900-01-01');
        SET @ToUtc   = ISNULL(@ToUtc, SYSUTCDATETIME());

        ;WITH Chain AS (
            SELECT  s.SignatureId
                  , s.EmployeeId
                  , s.SequenceNumber
                  , s.EntityType
                  , s.EntityId
                  , s.SignedAtUtc
                  , s.PayloadHash
                  , s.PreviousHash
                  , RecomputedHash = HASHBYTES('SHA2_256', s.PayloadCanonical)
                  , ExpectedPrevious = LAG(s.PayloadHash) OVER (PARTITION BY s.EmployeeId
                                                                ORDER BY s.SequenceNumber)
                  , ExpectedSequence = ROW_NUMBER() OVER (PARTITION BY s.EmployeeId
                                                          ORDER BY s.SequenceNumber)
            FROM aud.SignatureRecord s
            WHERE (@EmployeeId IS NULL OR s.EmployeeId = @EmployeeId)
        )
        , Checked AS (
            SELECT  c.*
                  , IsPayloadIntact = CASE WHEN c.RecomputedHash = c.PayloadHash THEN 1 ELSE 0 END
                  , IsLinkIntact = CASE
                        WHEN c.SequenceNumber = 1 AND c.PreviousHash IS NULL THEN 1
                        WHEN c.PreviousHash = c.ExpectedPrevious THEN 1
                        ELSE 0 END
                  , IsSequenceIntact = CASE WHEN c.SequenceNumber = c.ExpectedSequence THEN 1 ELSE 0 END
            FROM Chain c
        )
        /* Resultset 1: resumen por empleado */
        SELECT  ch.EmployeeId
              , e.EmployeeCode
              , e.FullName
              , COUNT(*)                                                  AS SignatureCount
              , MIN(ch.SignedAtUtc)                                       AS FirstSignedAtUtc
              , MAX(ch.SignedAtUtc)                                       AS LastSignedAtUtc
              , SUM(CASE WHEN ch.IsPayloadIntact = 0 THEN 1 ELSE 0 END)   AS TamperedPayloads
              , SUM(CASE WHEN ch.IsLinkIntact = 0 THEN 1 ELSE 0 END)      AS BrokenLinks
              , SUM(CASE WHEN ch.IsSequenceIntact = 0 THEN 1 ELSE 0 END)  AS SequenceAnomalies
              , MIN(CASE WHEN ch.IsPayloadIntact = 0 OR ch.IsLinkIntact = 0
                         THEN ch.SequenceNumber END)                      AS FirstBrokenSequence
              , CASE WHEN SUM(CASE WHEN ch.IsPayloadIntact = 0 OR ch.IsLinkIntact = 0
                                        OR ch.IsSequenceIntact = 0 THEN 1 ELSE 0 END) = 0
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END          AS IsChainValid
        INTO #ChainSummary
        FROM Checked ch
        JOIN org.Employee e ON e.EmployeeId = ch.EmployeeId
        GROUP BY ch.EmployeeId, e.EmployeeCode, e.FullName;

        SELECT * FROM #ChainSummary ORDER BY IsChainValid, EmployeeCode;

        /* Resultset 2: veredicto global del periodo */
        SELECT  COUNT(*)                                              AS ChainsVerified
              , SUM(CASE WHEN IsChainValid = 1 THEN 1 ELSE 0 END)     AS ValidChains
              , SUM(CASE WHEN IsChainValid = 0 THEN 1 ELSE 0 END)     AS CompromisedChains
              , SUM(SignatureCount)                                   AS TotalSignatures
              , CASE WHEN SUM(CASE WHEN IsChainValid = 0 THEN 1 ELSE 0 END) = 0
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END      AS AllChainsValid
              , SYSUTCDATETIME()                                      AS VerifiedAtUtc
              , @FromUtc AS PeriodFromUtc, @ToUtc AS PeriodToUtc
        FROM #ChainSummary;

        /* Resultset 3: detalle de las firmas rotas, si las hay.
           Si esto trae filas, alguien toco la base por fuera de la
           aplicacion y hay que investigarlo, no explicarlo. */
        SELECT TOP (500)
                s.SignatureId, s.EmployeeId, e.EmployeeCode, e.FullName
              , s.SequenceNumber, s.EntityType, s.EntityId, s.SignedAtUtc
              , CASE WHEN HASHBYTES('SHA2_256', s.PayloadCanonical) = s.PayloadHash
                     THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsPayloadIntact
              , CONVERT(NVARCHAR(64), s.PayloadHash, 2)  AS StoredHashHex
              , CONVERT(NVARCHAR(64), s.PreviousHash, 2) AS PreviousHashHex
        FROM aud.SignatureRecord s
        JOIN org.Employee e ON e.EmployeeId = s.EmployeeId
        JOIN #ChainSummary cs ON cs.EmployeeId = s.EmployeeId AND cs.IsChainValid = 0
        WHERE HASHBYTES('SHA2_256', s.PayloadCanonical) <> s.PayloadHash
           OR s.SequenceNumber >= ISNULL(cs.FirstBrokenSequence, 2147483647)
        ORDER BY s.EmployeeId, s.SequenceNumber;

        DROP TABLE #ChainSummary;
        RETURN 0;
    END TRY
    BEGIN CATCH
        IF OBJECT_ID('tempdb..#ChainSummary') IS NOT NULL DROP TABLE #ChainSummary;
        EXEC aud.usp_Error_Log @ProcedureName = N'aud.usp_Signature_Verify', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE aud.usp_Signature_Get
      @ActorUserId INT, @SignatureId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT  s.SignatureId, s.PublicId, s.EmployeeId, e.EmployeeCode, e.FullName
          , u.DisplayName AS SignedByName
          , s.SignatureType, s.EntityType, s.EntityId
          , s.PayloadCanonical
          , CONVERT(NVARCHAR(64), s.PayloadHash, 2)  AS PayloadHashHex
          , CONVERT(NVARCHAR(64), s.PreviousHash, 2) AS PreviousHashHex
          , s.SequenceNumber, s.AuthMethod, s.SignedAtUtc, s.DeviceId, s.IpAddress
          , CASE WHEN HASHBYTES('SHA2_256', s.PayloadCanonical) = s.PayloadHash
                 THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS IsPayloadIntact
    FROM aud.SignatureRecord s
    JOIN org.Employee e ON e.EmployeeId = s.EmployeeId
    LEFT JOIN sec.[User] u ON u.UserId = s.UserId
    WHERE s.SignatureId = @SignatureId;
    RETURN 0;
END;
GO

/* =====================================================================
   aud.usp_DataAccess_Log

   Quien miro el expediente de quien. Si no hay sujeto identificable
   (consultas agregadas como la matriz completa), se registra como
   evento en vez de forzar una fila sin sujeto.
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_DataAccess_Log
      @ActorUserId       INT
    , @AccessType        TINYINT       = 1
    , @EntityType        NVARCHAR(60)  = NULL
    , @SubjectEmployeeId INT           = NULL
    , @RecordCount       INT           = NULL
    , @Purpose           NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @SubjectEmployeeId IS NOT NULL
            INSERT INTO aud.DataAccessLog (ActorUserId, SubjectEmployeeId, AccessType, [Context])
            VALUES (@ActorUserId, @SubjectEmployeeId, @AccessType
                  , LEFT(CONCAT(ISNULL(@EntityType, N''), N' | ', ISNULL(@Purpose, N'')
                              , CASE WHEN @RecordCount IS NULL THEN N''
                                     ELSE N' | registros: ' + CAST(@RecordCount AS NVARCHAR(12)) END), 200));
        ELSE
            EXEC aud.usp_Event_Log
                  @EventType = N'DataAccess.Query'
                , @EntityType = @EntityType
                , @ActorUserId = @ActorUserId
                , @Severity = 3
                , @Summary = @Purpose;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'aud.usp_DataAccess_Log', @ActorUserId = @ActorUserId;
    END CATCH;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE aud.usp_Event_List
      @ActorUserId INT
    , @EntityType  NVARCHAR(60)  = NULL
    , @EntityId    INT           = NULL
    , @EmployeeId  INT           = NULL
    , @Severity    TINYINT       = NULL
    , @FromUtc     DATETIME2(3)  = NULL
    , @ToUtc       DATETIME2(3)  = NULL
    , @PageNumber  INT = 1
    , @PageSize    INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageSize > 200 SET @PageSize = 200;
    SET @FromUtc = ISNULL(@FromUtc, DATEADD(DAY, -30, SYSUTCDATETIME()));
    SET @ToUtc   = ISNULL(@ToUtc, SYSUTCDATETIME());

    SELECT  el.EventLogId, el.OccurredAtUtc, el.EntityType, el.EntityId, el.[Action]
          , el.Severity, el.[Description]
          , el.ActorUserId, u.DisplayName AS ActorName
          , el.ActorEmployeeId, e.EmployeeCode
          , el.IpAddress, el.CorrelationId
    FROM aud.EventLog el
    LEFT JOIN sec.[User] u ON u.UserId = el.ActorUserId
    LEFT JOIN org.Employee e ON e.EmployeeId = el.ActorEmployeeId
    WHERE el.OccurredAtUtc BETWEEN @FromUtc AND @ToUtc
      AND (@EntityType IS NULL OR el.EntityType      = @EntityType)
      AND (@EntityId   IS NULL OR el.EntityId        = @EntityId)
      AND (@EmployeeId IS NULL OR el.ActorEmployeeId = @EmployeeId)
      AND (@Severity   IS NULL OR el.Severity       >= @Severity)
    ORDER BY el.OccurredAtUtc DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
    RETURN 0;
END;
GO

/* =====================================================================
   aud.usp_Idempotency_Register

   Reintentos de red no deben crear dos inscripciones ni dos intentos.
   El cliente manda un GUID; si ya se vio, se devuelve el resultado
   anterior en vez de repetir la operacion.
   ===================================================================== */
CREATE OR ALTER PROCEDURE aud.usp_Idempotency_Register
      @IdempotencyKey  UNIQUEIDENTIFIER
    , @OperationName   NVARCHAR(150)
    , @ActorUserId     INT = NULL
    , @ResultEntityId  INT = NULL
    , @ResultJson      NVARCHAR(MAX) = NULL
    , @TtlHours        INT = 24
    , @WasAlreadySeen  BIT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SET @WasAlreadySeen = 0;

        SELECT @WasAlreadySeen = 1, @ResultEntityId = ResultEntityId, @ResultJson = ResultJson
        FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey;

        IF @WasAlreadySeen = 0
            INSERT INTO aud.IdempotencyKey (IdempotencyKey, OperationName, ActorUserId
                                          , ResultEntityId, ResultJson, ExpiresAtUtc)
            VALUES (@IdempotencyKey, @OperationName, @ActorUserId
                  , @ResultEntityId, @ResultJson, DATEADD(HOUR, @TtlHours, SYSUTCDATETIME()));

        SELECT @WasAlreadySeen AS WasAlreadySeen, @ResultEntityId AS ResultEntityId, @ResultJson AS ResultJson;
        RETURN 0;
    END TRY
    BEGIN CATCH
        /* Violacion de PK = otra sesion gano la carrera. Eso ES el
           comportamiento idempotente correcto, no un error. */
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            SET @WasAlreadySeen = 1;
            SELECT 1 AS WasAlreadySeen, ResultEntityId, ResultJson
            FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey;
            RETURN 0;
        END;
        EXEC aud.usp_Error_Log @ProcedureName = N'aud.usp_Idempotency_Register', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

/* =====================================================================
   ops.usp_Notification_Enqueue

   Encola, no envia. El worker externo hace el envio real.

   @DedupeKey se guarda dentro del PayloadJson y se consulta con
   JSON_VALUE: asi el job de vencimientos puede correr todas las noches
   durante 60 dias sin mandar 60 correos iguales.
   ===================================================================== */
CREATE OR ALTER PROCEDURE ops.usp_Notification_Enqueue
      @TemplateCode        NVARCHAR(80)
    , @RecipientUserId     INT           = NULL
    , @RecipientEmployeeId INT           = NULL
    , @Channel             TINYINT       = NULL
    , @LocaleCode          NVARCHAR(10)  = NULL
    , @ModelJson           NVARCHAR(MAX) = NULL
    , @Priority            TINYINT       = 3
    , @DedupeKey           NVARCHAR(120) = NULL
    , @NotifySupervisor    BIT           = 0
    , @CorrelationId       UNIQUEIDENTIFIER = NULL
    , @NotificationId      BIGINT        = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    /* Errores: 50710 sin destinatario */
    BEGIN TRY
        IF @RecipientUserId IS NULL AND @RecipientEmployeeId IS NULL
            THROW 50710, 'La notificacion necesita un destinatario.', 1;

        /* Completar el par usuario/empleado y el idioma preferido. */
        SELECT TOP (1)
               @RecipientUserId     = COALESCE(@RecipientUserId, u.UserId)
             , @RecipientEmployeeId = COALESCE(@RecipientEmployeeId, u.EmployeeId)
             , @LocaleCode          = COALESCE(@LocaleCode, u.PreferredLocale)
        FROM sec.[User] u
        WHERE (@RecipientUserId IS NOT NULL AND u.UserId = @RecipientUserId)
           OR (@RecipientUserId IS NULL AND u.EmployeeId = @RecipientEmployeeId AND u.IsActive = 1);

        SET @LocaleCode = ISNULL(@LocaleCode, N'es-DO');

        /* Dedupe: si ya hay una notificacion con la misma llave que no
           haya fallado, no se encola otra. */
        IF @DedupeKey IS NOT NULL
           AND EXISTS (SELECT 1 FROM ops.NotificationQueue q
                       WHERE q.TemplateKey = @TemplateCode
                         AND q.[Status] IN (1, 2, 3)
                         AND JSON_VALUE(q.PayloadJson, N'$.dedupeKey') = @DedupeKey)
        BEGIN
            SELECT NULL AS NotificationId, 1 AS WasDeduped;
            RETURN 0;
        END;

        /* Canal por defecto segun el template disponible en ese idioma. */
        IF @Channel IS NULL
            SELECT TOP (1) @Channel = t.Channel
            FROM ops.NotificationTemplate t
            WHERE t.TemplateKey = @TemplateCode AND t.IsActive = 1
              AND t.LocaleCode IN (@LocaleCode, N'es-DO')
            ORDER BY CASE WHEN t.LocaleCode = @LocaleCode THEN 0 ELSE 1 END;

        SET @Channel = ISNULL(@Channel, 1);

        DECLARE @Payload NVARCHAR(MAX) = JSON_MODIFY(
              JSON_MODIFY(ISNULL(NULLIF(@ModelJson, N''), N'{}')
                        , N'$.dedupeKey', @DedupeKey)
            , N'$.recipientEmployeeId', @RecipientEmployeeId);

        INSERT INTO ops.NotificationQueue (TemplateKey, Channel, LocaleCode, RecipientUserId
                                         , RecipientEmployeeId, RecipientAddress, PayloadJson
                                         , Priority, CorrelationId)
        SELECT @TemplateCode, @Channel, @LocaleCode, @RecipientUserId
             , @RecipientEmployeeId
             , (SELECT TOP (1) u.Email FROM sec.[User] u WHERE u.UserId = @RecipientUserId)
             , @Payload, ISNULL(@Priority, 3), @CorrelationId;

        SET @NotificationId = SCOPE_IDENTITY();

        /* Escalamiento al supervisor: se usa para vencimientos criticos y
           re-entrenamiento obligatorio. El supervisor es quien realmente
           puede liberar tiempo del operador para que lo haga. */
        IF @NotifySupervisor = 1 AND @RecipientEmployeeId IS NOT NULL
        BEGIN
            DECLARE @SupervisorEmployeeId INT;
            SELECT @SupervisorEmployeeId = SupervisorEmployeeId
            FROM org.Employee WHERE EmployeeId = @RecipientEmployeeId;

            IF @SupervisorEmployeeId IS NOT NULL
                INSERT INTO ops.NotificationQueue (TemplateKey, Channel, LocaleCode
                                                 , RecipientEmployeeId, PayloadJson, Priority, CorrelationId)
                SELECT @TemplateCode, @Channel, @LocaleCode, @SupervisorEmployeeId
                     , JSON_MODIFY(JSON_MODIFY(@Payload, N'$.isSupervisorCopy', CAST(1 AS BIT))
                                 , N'$.dedupeKey'
                                 , CASE WHEN @DedupeKey IS NULL THEN NULL ELSE @DedupeKey + N'-SUP' END)
                     , ISNULL(@Priority, 3), @CorrelationId;
        END;

        SELECT @NotificationId AS NotificationId, 0 AS WasDeduped;
        RETURN 0;
    END TRY
    BEGIN CATCH
        /* Una notificacion que no sale no puede tumbar una certificacion
           que si se emitio. Se registra y se sigue. */
        EXEC aud.usp_Error_Log @ProcedureName = N'ops.usp_Notification_Enqueue';
        RETURN 0;
    END CATCH;
END;
GO

/* =====================================================================
   ops.usp_Notification_Dequeue

   READPAST + UPDLOCK: varios workers pueden tomar lotes a la vez sin
   pisarse ni bloquearse entre ellos.
   ===================================================================== */
CREATE OR ALTER PROCEDURE ops.usp_Notification_Dequeue
      @BatchSize INT = 50
    , @Channel   TINYINT = NULL
    , @WorkerId  NVARCHAR(100) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @Taken TABLE (NotificationId BIGINT);

        UPDATE TOP (@BatchSize) q
        SET q.[Status] = 2                       -- Processing
          , q.AttemptCount = q.AttemptCount + 1
        OUTPUT inserted.NotificationId INTO @Taken
        FROM ops.NotificationQueue q WITH (READPAST, UPDLOCK, ROWLOCK)
        WHERE q.[Status] = 1
          AND q.NextAttemptAtUtc <= SYSUTCDATETIME()
          AND (@Channel IS NULL OR q.Channel = @Channel);

        SELECT  q.NotificationId, q.TemplateKey, q.Channel, q.LocaleCode
              , q.RecipientUserId, q.RecipientEmployeeId
              , COALESCE(q.RecipientAddress, u.Email, e.Email) AS RecipientAddress
              , COALESCE(e.FullName, u.DisplayName) AS RecipientName
              , q.PayloadJson, q.Priority, q.AttemptCount, q.CorrelationId
              , t.[Subject], t.BodyTemplate
        FROM ops.NotificationQueue q
        JOIN @Taken tk ON tk.NotificationId = q.NotificationId
        LEFT JOIN sec.[User] u ON u.UserId = q.RecipientUserId
        LEFT JOIN org.Employee e ON e.EmployeeId = q.RecipientEmployeeId
        OUTER APPLY (SELECT TOP (1) t2.[Subject], t2.BodyTemplate
                     FROM ops.NotificationTemplate t2
                     WHERE t2.TemplateKey = q.TemplateKey AND t2.Channel = q.Channel
                       AND t2.IsActive = 1
                       AND t2.LocaleCode IN (q.LocaleCode, N'es-DO')
                     ORDER BY CASE WHEN t2.LocaleCode = q.LocaleCode THEN 0 ELSE 1 END) t
        ORDER BY q.Priority, q.EnqueuedAtUtc;

        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'ops.usp_Notification_Dequeue';
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_Notification_MarkSent
      @NotificationId BIGINT
    , @Success        BIT = 1
    , @ErrorMessage   NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* Backoff exponencial: 2, 4, 8, 16, 32 minutos. Agotados los
       intentos, pasa a DeadLetter para revision humana. */
    UPDATE ops.NotificationQueue
    SET [Status] = CASE WHEN @Success = 1 THEN 3
                        WHEN AttemptCount >= MaxAttempts THEN 5
                        ELSE 1 END
      , SentAtUtc = CASE WHEN @Success = 1 THEN SYSUTCDATETIME() ELSE NULL END
      , LastError = CASE WHEN @Success = 1 THEN NULL ELSE @ErrorMessage END
      , NextAttemptAtUtc = CASE WHEN @Success = 1 THEN NextAttemptAtUtc
                                ELSE DATEADD(MINUTE, POWER(2, AttemptCount), SYSUTCDATETIME()) END
    WHERE NotificationId = @NotificationId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_Notification_GetDeadLetter
      @ActorUserId INT = NULL, @Top INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Top)
           q.NotificationId, q.TemplateKey, q.Channel, q.RecipientEmployeeId
         , e.EmployeeCode, e.FullName
         , q.AttemptCount, q.LastError, q.EnqueuedAtUtc, q.PayloadJson
    FROM ops.NotificationQueue q
    LEFT JOIN org.Employee e ON e.EmployeeId = q.RecipientEmployeeId
    WHERE q.[Status] = 5
    ORDER BY q.EnqueuedAtUtc DESC;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_NotificationTemplate_Upsert
      @ActorUserId INT, @TemplateKey NVARCHAR(80), @LocaleCode NVARCHAR(10)
    , @Channel TINYINT, @Subject NVARCHAR(300) = NULL
    , @BodyTemplate NVARCHAR(MAX), @IsActive BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    MERGE ops.NotificationTemplate AS tgt
    USING (SELECT @TemplateKey AS K, @LocaleCode AS L, @Channel AS C) AS src
    ON tgt.TemplateKey = src.K AND tgt.LocaleCode = src.L AND tgt.Channel = src.C
    WHEN MATCHED THEN UPDATE SET
          [Subject] = @Subject, BodyTemplate = @BodyTemplate
        , IsActive = @IsActive, ModifiedAtUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (TemplateKey, LocaleCode, Channel, [Subject], BodyTemplate, IsActive)
        VALUES (@TemplateKey, @LocaleCode, @Channel, @Subject, @BodyTemplate, @IsActive);
    RETURN 0;
END;
GO

/* =====================================================================
   Configuracion, flags, archivos, jobs
   ===================================================================== */
CREATE OR ALTER PROCEDURE ops.usp_Setting_Get
      @SettingKey NVARCHAR(100) = NULL, @ScopeType TINYINT = 1, @ScopeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    /* Resolucion por especificidad: departamento gana a sitio, sitio
       gana a global. Un solo query, sin logica en la aplicacion. */
    IF @SettingKey IS NOT NULL
        SELECT TOP (1) SettingKey, SettingValue, DataType, ScopeType, ScopeId
        FROM ops.Setting
        WHERE SettingKey = @SettingKey
          AND (ScopeType = 1 OR (ScopeType = @ScopeType AND ScopeId = @ScopeId))
        ORDER BY CASE WHEN ScopeType = @ScopeType AND ScopeId = @ScopeId THEN 0 ELSE 1 END;
    ELSE
        SELECT SettingKey, SettingValue, DataType, ScopeType, ScopeId, [Description]
        FROM ops.Setting WHERE IsEncrypted = 0 ORDER BY SettingKey;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_Setting_Set
      @ActorUserId INT, @SettingKey NVARCHAR(100), @SettingValue NVARCHAR(MAX)
    , @DataType NVARCHAR(20) = N'string', @ScopeType TINYINT = 1, @ScopeId INT = NULL
    , @Description NVARCHAR(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF sec.fn_UserHasPermission(@ActorUserId, N'settings.manage') = 0
        THROW 50002, 'El usuario no tiene permiso para modificar la configuracion.', 1;

    MERGE ops.Setting AS tgt
    USING (SELECT @SettingKey AS K, @ScopeType AS T, @ScopeId AS I) AS src
    ON tgt.SettingKey = src.K AND tgt.ScopeType = src.T
       AND ISNULL(tgt.ScopeId, -1) = ISNULL(src.I, -1)
    WHEN MATCHED THEN UPDATE SET
          SettingValue = @SettingValue, DataType = @DataType
        , [Description] = COALESCE(@Description, [Description])
        , ModifiedAtUtc = SYSUTCDATETIME(), ModifiedByUserId = @ActorUserId
    WHEN NOT MATCHED THEN INSERT (SettingKey, ScopeType, ScopeId, SettingValue, DataType
                                , [Description], ModifiedByUserId)
        VALUES (@SettingKey, @ScopeType, @ScopeId, @SettingValue, @DataType
              , @Description, @ActorUserId);

    EXEC aud.usp_Event_Log @EventType = N'Setting.Changed', @EntityType = N'Setting'
       , @ActorUserId = @ActorUserId, @Severity = 3, @Summary = @SettingKey;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_FeatureFlag_IsEnabled
      @FlagKey NVARCHAR(80), @UserId INT = NULL, @IsEnabled BIT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Flag BIT, @AudienceType TINYINT, @AudienceValue NVARCHAR(500);

    SELECT @Flag = IsEnabled, @AudienceType = AudienceType, @AudienceValue = AudienceValue
    FROM ops.FeatureFlag WHERE FlagKey = @FlagKey;

    SET @IsEnabled = CASE
        WHEN @Flag IS NULL OR @Flag = 0 THEN 0
        WHEN @AudienceType = 1 THEN 1                     -- All
        WHEN @UserId IS NULL THEN 0
        WHEN @AudienceType = 5 THEN                       -- lista de usuarios
             CASE WHEN EXISTS (SELECT 1 FROM STRING_SPLIT(@AudienceValue, N',')
                               WHERE TRY_CONVERT(INT, RTRIM(LTRIM([value]))) = @UserId)
                  THEN 1 ELSE 0 END
        WHEN @AudienceType = 2 THEN                       -- por rol
             CASE WHEN EXISTS (SELECT 1 FROM sec.UserRoleAssignment ura
                               JOIN sec.Role r ON r.RoleId = ura.RoleId
                               JOIN STRING_SPLIT(@AudienceValue, N',') s
                                 ON RTRIM(LTRIM(s.[value])) = r.RoleCode
                               WHERE ura.UserId = @UserId)
                  THEN 1 ELSE 0 END
        WHEN @AudienceType = 3 THEN                       -- por departamento
             CASE WHEN EXISTS (SELECT 1 FROM sec.[User] u
                               JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
                               JOIN STRING_SPLIT(@AudienceValue, N',') s
                                 ON TRY_CONVERT(INT, RTRIM(LTRIM(s.[value]))) = e.DepartmentId
                               WHERE u.UserId = @UserId)
                  THEN 1 ELSE 0 END
        WHEN @AudienceType = 4 THEN                       -- por sitio
             CASE WHEN EXISTS (SELECT 1 FROM sec.[User] u
                               JOIN org.Employee e ON e.EmployeeId = u.EmployeeId
                               JOIN STRING_SPLIT(@AudienceValue, N',') s
                                 ON TRY_CONVERT(INT, RTRIM(LTRIM(s.[value]))) = e.SiteId
                               WHERE u.UserId = @UserId)
                  THEN 1 ELSE 0 END
        ELSE 0 END;

    SELECT @IsEnabled AS IsEnabled;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_FileAsset_Register
      @ActorUserId INT, @FileName NVARCHAR(300), @ContentType NVARCHAR(150)
    , @SizeBytes BIGINT, @StorageProvider TINYINT, @StoragePath NVARCHAR(1000)
    , @ContentHash VARBINARY(32) = NULL
    , @OwnerEntityType NVARCHAR(60) = NULL, @OwnerEntityId INT = NULL
    , @IsPublic BIT = 0
    , @FileAssetId INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    /* Deduplicacion por hash: la misma WI subida por tres personas
       distintas guarda un solo archivo. */
    IF @ContentHash IS NOT NULL
        SELECT TOP (1) @FileAssetId = FileAssetId
        FROM ops.FileAsset
        WHERE ContentHash = @ContentHash AND IsDeleted = 0
        ORDER BY FileAssetId;

    IF @FileAssetId IS NULL
    BEGIN
        INSERT INTO ops.FileAsset (FileName, ContentType, SizeBytes, StorageProvider, StoragePath
                                 , ContentHash, OwnerEntityType, OwnerEntityId, IsPublic, UploadedByUserId)
        VALUES (@FileName, @ContentType, @SizeBytes, @StorageProvider, @StoragePath
              , @ContentHash, @OwnerEntityType, @OwnerEntityId, @IsPublic, @ActorUserId);
        SET @FileAssetId = SCOPE_IDENTITY();
    END;

    SELECT @FileAssetId AS FileAssetId;
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_JobRun_Start
      @JobName NVARCHAR(100), @JobRunId BIGINT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO ops.JobRun (JobName, [Status]) VALUES (@JobName, 1);
    SET @JobRunId = SCOPE_IDENTITY();
    RETURN 0;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_JobRun_Finish
      @JobRunId BIGINT, @Status TINYINT = 2
    , @RecordsProcessed INT = 0, @Message NVARCHAR(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE ops.JobRun
    SET FinishedAtUtc = SYSUTCDATETIME(), [Status] = @Status
      , RecordsProcessed = @RecordsProcessed
      , DurationMs = DATEDIFF(MILLISECOND, StartedAtUtc, SYSUTCDATETIME())
      , Message = @Message
    WHERE JobRunId = @JobRunId;
    RETURN 0;
END;
GO

/* =====================================================================
   ops.usp_Health_GetStatus

   Lo que se pone en el tablero de IT. Si el sync de empleados lleva mas
   de 3 horas sin correr, o la cola de notificaciones esta creciendo, el
   sistema esta mintiendo aunque la pantalla se vea bien.
   ===================================================================== */
CREATE OR ALTER PROCEDURE ops.usp_Health_GetStatus @ActorUserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();

    SELECT
          (SELECT COUNT(*) FROM ops.NotificationQueue WHERE [Status] = 1) AS NotificationsPending
        , (SELECT COUNT(*) FROM ops.NotificationQueue WHERE [Status] = 5) AS NotificationsDeadLetter
        , (SELECT COUNT(*) FROM intg.IntegrationError WHERE IsResolved = 0) AS OpenIntegrationErrors
        , (SELECT MAX(LastSuccessAtUtc) FROM intg.SyncWatermark
           WHERE SourceSystem = N'SPN' AND SourceEntity = N'Employee') AS LastEmployeeSyncUtc
        , (SELECT COUNT(*) FROM aud.ErrorLog WHERE OccurredAtUtc > DATEADD(HOUR, -24, @NowUtc)) AS ErrorsLast24h
        , (SELECT COUNT(*) FROM ops.JobRun
           WHERE [Status] = 4 AND StartedAtUtc > DATEADD(HOUR, -24, @NowUtc)) AS FailedJobsLast24h
        , (SELECT COUNT(*) FROM comp.CompetencyGap
           WHERE ResolvedAtUtc IS NULL AND Severity = 1 AND HasActiveWaiver = 0) AS OpenCriticalGaps
        , (SELECT COUNT(*) FROM asmt.QuizAttempt WHERE [Status] = 1) AS AttemptsInProgress;

    /* Ultimas corridas de cada job */
    SELECT j.JobName, j.[Status], j.StartedAtUtc, j.FinishedAtUtc
         , j.DurationMs, j.RecordsProcessed, j.Message
    FROM ops.JobRun j
    JOIN (SELECT JobName, MAX(JobRunId) AS LastId FROM ops.JobRun GROUP BY JobName) x
      ON x.LastId = j.JobRunId
    ORDER BY j.JobName;
    RETURN 0;
END;
GO

/* =====================================================================
   ops.usp_Retention_Apply

   Retencion diferenciada. Lo operativo se limpia; lo que sostiene una
   certificacion NO se toca nunca.

   Politicas por ops.Setting (dias):
     Retention.EventLog.Days      (default 1095 = 3 anos)
     Retention.AppLog.Days        (default 90)
     Retention.ErrorLog.Days      (default 365)
     Retention.Notification.Days  (default 180, solo enviadas)
     Retention.Staging.Days       (default 30)

   NUNCA se purga: aud.SignatureRecord, comp.Certification,
   comp.CertificationEvidence, comp.DocumentAcknowledgment,
   dlv.Enrollment, asmt.QuizAttempt*, asmt.PracticalAssessment*.
   Esos son el expediente. Se conservan 7 anos como minimo y su borrado
   se maneja como proyecto aparte, con aprobacion de Calidad.
   ===================================================================== */
CREATE OR ALTER PROCEDURE ops.usp_Retention_Apply
      @ActorUserId INT = NULL
    , @DryRun      BIT = 0
    , @BatchSize   INT = 5000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRY
        DECLARE @NowUtc DATETIME2(3) = SYSUTCDATETIME();

        DECLARE @EventDays INT   = TRY_CONVERT(INT, (SELECT TOP (1) SettingValue FROM ops.Setting
                                   WHERE SettingKey = N'Retention.EventLog.Days' AND ScopeType = 1))
              , @AppDays INT     = TRY_CONVERT(INT, (SELECT TOP (1) SettingValue FROM ops.Setting
                                   WHERE SettingKey = N'Retention.AppLog.Days' AND ScopeType = 1))
              , @ErrDays INT     = TRY_CONVERT(INT, (SELECT TOP (1) SettingValue FROM ops.Setting
                                   WHERE SettingKey = N'Retention.ErrorLog.Days' AND ScopeType = 1))
              , @NotifDays INT   = TRY_CONVERT(INT, (SELECT TOP (1) SettingValue FROM ops.Setting
                                   WHERE SettingKey = N'Retention.Notification.Days' AND ScopeType = 1))
              , @StagingDays INT = TRY_CONVERT(INT, (SELECT TOP (1) SettingValue FROM ops.Setting
                                   WHERE SettingKey = N'Retention.Staging.Days' AND ScopeType = 1));

        SET @EventDays   = ISNULL(@EventDays, 1095);
        SET @AppDays     = ISNULL(@AppDays, 90);
        SET @ErrDays     = ISNULL(@ErrDays, 365);
        SET @NotifDays   = ISNULL(@NotifDays, 180);
        SET @StagingDays = ISNULL(@StagingDays, 30);

        DECLARE @Plan TABLE ([Table] NVARCHAR(80), RowsAffected INT);

        IF @DryRun = 1
        BEGIN
            INSERT INTO @Plan
            SELECT N'aud.EventLog', COUNT(*) FROM aud.EventLog
            WHERE OccurredAtUtc < DATEADD(DAY, -@EventDays, @NowUtc) AND Severity = 1
            UNION ALL SELECT N'ops.AppLog', COUNT(*) FROM ops.AppLog
            WHERE LoggedAtUtc < DATEADD(DAY, -@AppDays, @NowUtc)
            UNION ALL SELECT N'aud.ErrorLog', COUNT(*) FROM aud.ErrorLog
            WHERE OccurredAtUtc < DATEADD(DAY, -@ErrDays, @NowUtc)
            UNION ALL SELECT N'ops.NotificationQueue', COUNT(*) FROM ops.NotificationQueue
            WHERE [Status] = 3 AND SentAtUtc < DATEADD(DAY, -@NotifDays, @NowUtc)
            UNION ALL SELECT N'intg.EmployeeStaging', COUNT(*) FROM intg.EmployeeStaging st
            JOIN intg.SyncRun r ON r.SyncRunId = st.SyncRunId
            WHERE r.StartedAtUtc < DATEADD(DAY, -@StagingDays, @NowUtc)
            UNION ALL SELECT N'aud.IdempotencyKey', COUNT(*) FROM aud.IdempotencyKey
            WHERE ExpiresAtUtc < @NowUtc;

            SELECT * FROM @Plan;
            RETURN 0;
        END;

        /* Solo eventos informativos. Severity >= 2 (Notable, Sensible,
           Critico) se conserva: ahi vive el rastro de quien hizo que. */
        DELETE TOP (@BatchSize) FROM aud.EventLog
        WHERE OccurredAtUtc < DATEADD(DAY, -@EventDays, @NowUtc) AND Severity = 1;
        INSERT INTO @Plan VALUES (N'aud.EventLog', @@ROWCOUNT);

        DELETE TOP (@BatchSize) FROM ops.AppLog
        WHERE LoggedAtUtc < DATEADD(DAY, -@AppDays, @NowUtc);
        INSERT INTO @Plan VALUES (N'ops.AppLog', @@ROWCOUNT);

        DELETE TOP (@BatchSize) FROM aud.ErrorLog
        WHERE OccurredAtUtc < DATEADD(DAY, -@ErrDays, @NowUtc);
        INSERT INTO @Plan VALUES (N'aud.ErrorLog', @@ROWCOUNT);

        DELETE TOP (@BatchSize) FROM ops.NotificationQueue
        WHERE [Status] = 3 AND SentAtUtc < DATEADD(DAY, -@NotifDays, @NowUtc);
        INSERT INTO @Plan VALUES (N'ops.NotificationQueue', @@ROWCOUNT);

        DELETE TOP (@BatchSize) st
        FROM intg.EmployeeStaging st
        JOIN intg.SyncRun r ON r.SyncRunId = st.SyncRunId
        WHERE r.StartedAtUtc < DATEADD(DAY, -@StagingDays, @NowUtc);
        INSERT INTO @Plan VALUES (N'intg.EmployeeStaging', @@ROWCOUNT);

        DELETE TOP (@BatchSize) FROM aud.IdempotencyKey WHERE ExpiresAtUtc < @NowUtc;
        INSERT INTO @Plan VALUES (N'aud.IdempotencyKey', @@ROWCOUNT);

        EXEC aud.usp_Event_Log @EventType = N'Retention.Applied', @EntityType = N'Retention'
           , @ActorUserId = @ActorUserId, @Severity = 2
           , @Summary = N'Politica de retencion aplicada.';

        SELECT * FROM @Plan;
        RETURN 0;
    END TRY
    BEGIN CATCH
        EXEC aud.usp_Error_Log @ProcedureName = N'ops.usp_Retention_Apply', @ActorUserId = @ActorUserId;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE ops.usp_AppLog_Write
      @Level NVARCHAR(20), @Source NVARCHAR(150) = NULL, @Message NVARCHAR(4000)
    , @ExceptionDetail NVARCHAR(MAX) = NULL, @ActorUserId INT = NULL
    , @CorrelationId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO ops.AppLog ([Level], [Source], Message, ExceptionDetail, ActorUserId, CorrelationId)
    VALUES (@Level, @Source, @Message, @ExceptionDetail, @ActorUserId, @CorrelationId);
    RETURN 0;
END;
GO

PRINT '=== 18_procs_platform.sql completado ===';
GO
