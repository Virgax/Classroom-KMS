/* =============================================================================
   Classroom LMS by Airlink
   05_tables_assessment.sql  -  asmt: bancos, preguntas, quizzes, intentos,
                                rubricas, evaluacion practica (OJT)
   ============================================================================= */
USE AIRLINK_KMS;
GO
SET NOCOUNT ON;
GO

/* --- asmt.QuestionBank -------------------------------------------------- */
IF OBJECT_ID(N'asmt.QuestionBank', N'U') IS NULL
CREATE TABLE asmt.QuestionBank (
      QuestionBankId    INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_QuestionBank_PublicId DEFAULT NEWID()
    , BankCode          NVARCHAR(40)     NOT NULL
    , NameEs            NVARCHAR(250)    NOT NULL
    , NameEn            NVARCHAR(250)    NULL
    , CompetencyId      INT              NULL       -- banco alineado a una competencia
    , OwnerDepartmentId INT              NULL
    , IsShared          BIT              NOT NULL CONSTRAINT DF_QuestionBank_IsShared DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_QuestionBank_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_QuestionBank_IsDeleted DEFAULT 0
    , CONSTRAINT PK_QuestionBank PRIMARY KEY CLUSTERED (QuestionBankId)
    , CONSTRAINT UQ_QuestionBank_Code UNIQUE (BankCode)
);
GO

/* --- asmt.Question ----------------------------------------------------- */
IF OBJECT_ID(N'asmt.Question', N'U') IS NULL
CREATE TABLE asmt.Question (
      QuestionId        INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Question_PublicId DEFAULT NEWID()
    , QuestionBankId    INT              NOT NULL
    , QuestionType      TINYINT          NOT NULL
        /* 1=MultipleChoice 2=MultipleAnswer 3=TrueFalse 4=Matching 5=Ordering
           6=ShortAnswer 7=Numeric 8=Essay 9=HotSpot 10=FileUpload */
    , TextEs            NVARCHAR(MAX)    NOT NULL
    , TextEn            NVARCHAR(MAX)    NULL
    , Points            DECIMAL(9,2)     NOT NULL CONSTRAINT DF_Question_Points DEFAULT 1
    , Difficulty        TINYINT          NOT NULL CONSTRAINT DF_Question_Difficulty DEFAULT 2
                                         -- 1=Easy 2=Medium 3=Hard
    , CorrectFeedbackEs NVARCHAR(1000)   NULL
    , CorrectFeedbackEn NVARCHAR(1000)   NULL
    , IncorrectFeedbackEs NVARCHAR(1000) NULL       -- referencia a la seccion de la WI
    , IncorrectFeedbackEn NVARCHAR(1000) NULL
    , ReferenceDocumentCode NVARCHAR(60) NULL       -- 'WI-IP68-RXR-001 Rev.1 sec.4.2'
    , MediaFileAssetId  INT              NULL       -- imagen para HotSpot
    , NumericAnswer     DECIMAL(18,4)    NULL
    , NumericTolerance  DECIMAL(18,4)    NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Question_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Question_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Question_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Question PRIMARY KEY CLUSTERED (QuestionId)
    , CONSTRAINT FK_Question_Bank FOREIGN KEY (QuestionBankId) REFERENCES asmt.QuestionBank (QuestionBankId)
    , CONSTRAINT CK_Question_Type CHECK (QuestionType BETWEEN 1 AND 10)
    , CONSTRAINT CK_Question_Points CHECK (Points > 0)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Question_Bank_Active' AND object_id = OBJECT_ID(N'asmt.Question'))
    CREATE NONCLUSTERED INDEX IX_Question_Bank_Active ON asmt.Question (QuestionBankId, IsActive, Difficulty)
        WHERE IsDeleted = 0;
GO

/* --- asmt.QuestionOption ----------------------------------------------- */
IF OBJECT_ID(N'asmt.QuestionOption', N'U') IS NULL
CREATE TABLE asmt.QuestionOption (
      QuestionOptionId  INT              NOT NULL IDENTITY(1,1)
    , QuestionId        INT              NOT NULL
    , TextEs            NVARCHAR(1000)   NOT NULL
    , TextEn            NVARCHAR(1000)   NULL
    , IsCorrect         BIT              NOT NULL CONSTRAINT DF_QuestionOption_IsCorrect DEFAULT 0
    , SortOrder         INT              NOT NULL
    , MatchGroupKey     NVARCHAR(40)     NULL       -- para Matching
    , HotSpotX          INT              NULL       -- para HotSpot (px)
    , HotSpotY          INT              NULL
    , HotSpotRadius     INT              NULL
    , PartialCredit     DECIMAL(5,2)     NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_QuestionOption_IsDeleted DEFAULT 0
    , CONSTRAINT PK_QuestionOption PRIMARY KEY CLUSTERED (QuestionOptionId)
    , CONSTRAINT FK_QuestionOption_Question FOREIGN KEY (QuestionId) REFERENCES asmt.Question (QuestionId)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_QuestionOption_Question' AND object_id = OBJECT_ID(N'asmt.QuestionOption'))
    CREATE NONCLUSTERED INDEX IX_QuestionOption_Question ON asmt.QuestionOption (QuestionId, SortOrder)
        WHERE IsDeleted = 0;
GO

/* --- asmt.Quiz --------------------------------------------------------- */
IF OBJECT_ID(N'asmt.Quiz', N'U') IS NULL
CREATE TABLE asmt.Quiz (
      QuizId            INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Quiz_PublicId DEFAULT NEWID()
    , CourseVersionId   INT              NULL       -- NULL = quiz reutilizable
    , TitleEs           NVARCHAR(250)    NOT NULL
    , TitleEn           NVARCHAR(250)    NULL
    , InstructionsEs    NVARCHAR(MAX)    NULL
    , InstructionsEn    NVARCHAR(MAX)    NULL
    , QuizType          TINYINT          NOT NULL CONSTRAINT DF_Quiz_QuizType DEFAULT 1
                                         -- 1=Graded 2=Practice 3=Survey 4=PreTest
    , PassingScore      DECIMAL(5,2)     NOT NULL CONSTRAINT DF_Quiz_PassingScore DEFAULT 80.00
    , MaxAttempts       TINYINT          NOT NULL CONSTRAINT DF_Quiz_MaxAttempts DEFAULT 3
    , ScorePolicy       TINYINT          NOT NULL CONSTRAINT DF_Quiz_ScorePolicy DEFAULT 1
                                         -- 1=Highest 2=Latest 3=Average 4=First
    , TimeLimitMinutes  INT              NULL
    , ShuffleQuestions  BIT              NOT NULL CONSTRAINT DF_Quiz_ShuffleQuestions DEFAULT 1
    , ShuffleOptions    BIT              NOT NULL CONSTRAINT DF_Quiz_ShuffleOptions DEFAULT 1
    , OneQuestionAtATime BIT             NOT NULL CONSTRAINT DF_Quiz_OneAtATime DEFAULT 0
    , AllowBacktrack    BIT              NOT NULL CONSTRAINT DF_Quiz_AllowBacktrack DEFAULT 1
    , ShowCorrectAnswers TINYINT         NOT NULL CONSTRAINT DF_Quiz_ShowCorrect DEFAULT 2
                                         -- 1=Never 2=AfterPassing 3=Always 4=AfterLastAttempt
    , ShowScoreImmediately BIT           NOT NULL CONSTRAINT DF_Quiz_ShowScore DEFAULT 1
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Quiz_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Quiz_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , ModifiedAtUtc     DATETIME2(3)     NULL
    , ModifiedByUserId  INT              NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Quiz_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Quiz PRIMARY KEY CLUSTERED (QuizId)
    , CONSTRAINT FK_Quiz_CourseVersion FOREIGN KEY (CourseVersionId) REFERENCES lms.CourseVersion (CourseVersionId)
    , CONSTRAINT CK_Quiz_ScorePolicy CHECK (ScorePolicy BETWEEN 1 AND 4)
);
GO

/* --- asmt.QuizSection + fuentes (seleccion aleatoria de banco) ---------- */
IF OBJECT_ID(N'asmt.QuizSection', N'U') IS NULL
CREATE TABLE asmt.QuizSection (
      QuizSectionId     INT              NOT NULL IDENTITY(1,1)
    , QuizId            INT              NOT NULL
    , TitleEs           NVARCHAR(250)    NULL
    , TitleEn           NVARCHAR(250)    NULL
    , SortOrder         INT              NOT NULL
    , SelectionMode     TINYINT          NOT NULL CONSTRAINT DF_QuizSection_SelectionMode DEFAULT 1
                                         -- 1=FixedQuestions 2=RandomFromBank
    , CONSTRAINT PK_QuizSection PRIMARY KEY CLUSTERED (QuizSectionId)
    , CONSTRAINT FK_QuizSection_Quiz FOREIGN KEY (QuizId) REFERENCES asmt.Quiz (QuizId)
);
GO

IF OBJECT_ID(N'asmt.QuizSectionSource', N'U') IS NULL
CREATE TABLE asmt.QuizSectionSource (
      QuizSectionSourceId INT            NOT NULL IDENTITY(1,1)
    , QuizSectionId     INT              NOT NULL
    , QuestionBankId    INT              NOT NULL
    , QuestionCount     INT              NOT NULL   -- "toma N del banco"
    , DifficultyFilter  TINYINT          NULL
    , PointsPerQuestion DECIMAL(9,2)     NULL       -- override
    , CONSTRAINT PK_QuizSectionSource PRIMARY KEY CLUSTERED (QuizSectionSourceId)
    , CONSTRAINT FK_QuizSectionSource_Section FOREIGN KEY (QuizSectionId)  REFERENCES asmt.QuizSection (QuizSectionId)
    , CONSTRAINT FK_QuizSectionSource_Bank    FOREIGN KEY (QuestionBankId) REFERENCES asmt.QuestionBank (QuestionBankId)
    , CONSTRAINT CK_QuizSectionSource_Count CHECK (QuestionCount > 0)
);
GO

IF OBJECT_ID(N'asmt.QuizQuestion', N'U') IS NULL
CREATE TABLE asmt.QuizQuestion (
      QuizQuestionId    INT              NOT NULL IDENTITY(1,1)
    , QuizSectionId     INT              NOT NULL
    , QuestionId        INT              NOT NULL
    , SortOrder         INT              NOT NULL
    , PointsOverride    DECIMAL(9,2)     NULL
    , CONSTRAINT PK_QuizQuestion PRIMARY KEY CLUSTERED (QuizQuestionId)
    , CONSTRAINT UQ_QuizQuestion UNIQUE (QuizSectionId, QuestionId)
    , CONSTRAINT FK_QuizQuestion_Section  FOREIGN KEY (QuizSectionId) REFERENCES asmt.QuizSection (QuizSectionId)
    , CONSTRAINT FK_QuizQuestion_Question FOREIGN KEY (QuestionId)    REFERENCES asmt.Question (QuestionId)
);
GO

/* --- asmt.QuizAttempt -------------------------------------------------- */
IF OBJECT_ID(N'asmt.QuizAttempt', N'U') IS NULL
CREATE TABLE asmt.QuizAttempt (
      QuizAttemptId     INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_QuizAttempt_PublicId DEFAULT NEWID()
    , QuizId            INT              NOT NULL
    , EnrollmentId      INT              NULL       -- NULL si es practica libre
    , EmployeeId        INT              NOT NULL
    , ModuleItemId      INT              NULL
    , AttemptNumber     TINYINT          NOT NULL
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_QuizAttempt_Status DEFAULT 1
        /* 1=InProgress 2=Submitted 3=Graded 4=Abandoned 5=PendingManualGrading */
    , StartedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_QuizAttempt_StartedAtUtc DEFAULT SYSUTCDATETIME()
    , ExpiresAtUtc      DATETIME2(3)     NULL       -- StartedAt + TimeLimit
    , SubmittedAtUtc    DATETIME2(3)     NULL
    , GradedAtUtc       DATETIME2(3)     NULL
    , GradedByUserId    INT              NULL
    , PointsEarned      DECIMAL(9,2)     NULL
    , PointsPossible    DECIMAL(9,2)     NULL
    , ScorePercent      DECIMAL(5,2)     NULL
    , IsPassed          BIT              NULL
    , TimeSpentSeconds  INT              NOT NULL CONSTRAINT DF_QuizAttempt_TimeSpent DEFAULT 0
    , SessionId         UNIQUEIDENTIFIER NULL
    , DeviceId          INT              NULL
    , IpAddress         NVARCHAR(45)     NULL
    , CONSTRAINT PK_QuizAttempt PRIMARY KEY CLUSTERED (QuizAttemptId)
    , CONSTRAINT UQ_QuizAttempt_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT FK_QuizAttempt_Quiz     FOREIGN KEY (QuizId)     REFERENCES asmt.Quiz (QuizId)
    , CONSTRAINT FK_QuizAttempt_Employee FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT CK_QuizAttempt_Status CHECK ([Status] BETWEEN 1 AND 5)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_QuizAttempt_Enrollment' AND object_id = OBJECT_ID(N'asmt.QuizAttempt'))
    CREATE NONCLUSTERED INDEX IX_QuizAttempt_Enrollment ON asmt.QuizAttempt (EnrollmentId, AttemptNumber)
        INCLUDE ([Status], ScorePercent, IsPassed);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_QuizAttempt_Expiring' AND object_id = OBJECT_ID(N'asmt.QuizAttempt'))
    CREATE NONCLUSTERED INDEX IX_QuizAttempt_Expiring ON asmt.QuizAttempt (ExpiresAtUtc)
        WHERE [Status] = 1;
GO

/* --- SNAPSHOT DEL INTENTO --------------------------------------------------
   asmt.QuizAttemptQuestion / QuizAttemptOption congelan la pregunta y las
   opciones EXACTAMENTE como se le presentaron al empleado, en el orden en que
   se mostraron. Si el banco cambia despues, el intento historico sigue siendo
   reproducible. Sin esto, un auditor puede impugnar toda la evidencia de
   evaluacion. NO ELIMINAR NI "OPTIMIZAR" ESTAS TABLAS.
   ---------------------------------------------------------------------- */
IF OBJECT_ID(N'asmt.QuizAttemptQuestion', N'U') IS NULL
CREATE TABLE asmt.QuizAttemptQuestion (
      AttemptQuestionId INT              NOT NULL IDENTITY(1,1)
    , QuizAttemptId     INT              NOT NULL
    , QuestionId        INT              NOT NULL   -- referencia, no fuente de verdad
    , QuestionType      TINYINT          NOT NULL
    , QuestionTextSnapshot NVARCHAR(MAX) NOT NULL   -- texto tal como se mostro
    , LocaleCode        NVARCHAR(10)     NOT NULL
    , PointsPossible    DECIMAL(9,2)     NOT NULL
    , PresentedOrder    INT              NOT NULL
    , NumericAnswerSnapshot DECIMAL(18,4) NULL
    , NumericToleranceSnapshot DECIMAL(18,4) NULL
    , ReferenceDocumentCode NVARCHAR(60) NULL
    , CONSTRAINT PK_QuizAttemptQuestion PRIMARY KEY CLUSTERED (AttemptQuestionId)
    , CONSTRAINT UQ_QuizAttemptQuestion UNIQUE (QuizAttemptId, PresentedOrder)
    , CONSTRAINT FK_AttemptQuestion_Attempt FOREIGN KEY (QuizAttemptId) REFERENCES asmt.QuizAttempt (QuizAttemptId)
);
GO

IF OBJECT_ID(N'asmt.QuizAttemptOption', N'U') IS NULL
CREATE TABLE asmt.QuizAttemptOption (
      AttemptOptionId   INT              NOT NULL IDENTITY(1,1)
    , AttemptQuestionId INT              NOT NULL
    , QuestionOptionId  INT              NULL
    , OptionTextSnapshot NVARCHAR(1000)  NOT NULL
    , IsCorrectSnapshot BIT              NOT NULL
    , PresentedOrder    INT              NOT NULL
    , MatchGroupKey     NVARCHAR(40)     NULL
    , HotSpotX          INT              NULL
    , HotSpotY          INT              NULL
    , HotSpotRadius     INT              NULL
    , PartialCredit     DECIMAL(5,2)     NULL
    , CONSTRAINT PK_QuizAttemptOption PRIMARY KEY CLUSTERED (AttemptOptionId)
    , CONSTRAINT UQ_QuizAttemptOption UNIQUE (AttemptQuestionId, PresentedOrder)
    , CONSTRAINT FK_AttemptOption_AttemptQuestion FOREIGN KEY (AttemptQuestionId) REFERENCES asmt.QuizAttemptQuestion (AttemptQuestionId)
);
GO

IF OBJECT_ID(N'asmt.QuizAttemptAnswer', N'U') IS NULL
CREATE TABLE asmt.QuizAttemptAnswer (
      AttemptAnswerId   INT              NOT NULL IDENTITY(1,1)
    , AttemptQuestionId INT              NOT NULL
    , SelectedOptionIds NVARCHAR(200)    NULL       -- CSV de AttemptOptionId
    , TextAnswer        NVARCHAR(MAX)    NULL
    , NumericAnswer     DECIMAL(18,4)    NULL
    , FileAssetId       INT              NULL
    , IsCorrect         BIT              NULL       -- NULL = pendiente de calificar
    , PointsEarned      DECIMAL(9,2)     NULL
    , GraderComments    NVARCHAR(1000)   NULL
    , GradedByUserId    INT              NULL
    , GradedAtUtc       DATETIME2(3)     NULL
    , AnsweredAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_AttemptAnswer_AnsweredAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_QuizAttemptAnswer PRIMARY KEY CLUSTERED (AttemptAnswerId)
    , CONSTRAINT UQ_QuizAttemptAnswer UNIQUE (AttemptQuestionId)
    , CONSTRAINT FK_AttemptAnswer_AttemptQuestion FOREIGN KEY (AttemptQuestionId) REFERENCES asmt.QuizAttemptQuestion (AttemptQuestionId)
);
GO

/* --- asmt.Rubric ------------------------------------------------------- */
IF OBJECT_ID(N'asmt.Rubric', N'U') IS NULL
CREATE TABLE asmt.Rubric (
      RubricId          INT              NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_Rubric_PublicId DEFAULT NEWID()
    , RubricCode        NVARCHAR(40)     NOT NULL
    , NameEs            NVARCHAR(250)    NOT NULL
    , NameEn            NVARCHAR(250)    NULL
    , TotalPoints       DECIMAL(9,2)     NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_Rubric_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Rubric_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_Rubric_IsDeleted DEFAULT 0
    , CONSTRAINT PK_Rubric PRIMARY KEY CLUSTERED (RubricId)
    , CONSTRAINT UQ_Rubric_Code UNIQUE (RubricCode)
);
GO

IF OBJECT_ID(N'asmt.RubricCriterion', N'U') IS NULL
CREATE TABLE asmt.RubricCriterion (
      RubricCriterionId INT              NOT NULL IDENTITY(1,1)
    , RubricId          INT              NOT NULL
    , DescriptionEs     NVARCHAR(1000)   NOT NULL
    , DescriptionEn     NVARCHAR(1000)   NULL
    , CompetencyId      INT              NULL       -- alineacion a competencia (outcome)
    , MaxPoints         DECIMAL(9,2)     NOT NULL
    , SortOrder         INT              NOT NULL
    , IsCritical        BIT              NOT NULL CONSTRAINT DF_RubricCriterion_IsCritical DEFAULT 0
    , CONSTRAINT PK_RubricCriterion PRIMARY KEY CLUSTERED (RubricCriterionId)
    , CONSTRAINT FK_RubricCriterion_Rubric FOREIGN KEY (RubricId) REFERENCES asmt.Rubric (RubricId)
);
GO

IF OBJECT_ID(N'asmt.RubricLevel', N'U') IS NULL
CREATE TABLE asmt.RubricLevel (
      RubricLevelId     INT              NOT NULL IDENTITY(1,1)
    , RubricCriterionId INT              NOT NULL
    , LabelEs           NVARCHAR(100)    NOT NULL
    , LabelEn           NVARCHAR(100)    NULL
    , DescriptionEs     NVARCHAR(1000)   NULL
    , DescriptionEn     NVARCHAR(1000)   NULL
    , Points            DECIMAL(9,2)     NOT NULL
    , SortOrder         INT              NOT NULL
    , CONSTRAINT PK_RubricLevel PRIMARY KEY CLUSTERED (RubricLevelId)
    , CONSTRAINT FK_RubricLevel_Criterion FOREIGN KEY (RubricCriterionId) REFERENCES asmt.RubricCriterion (RubricCriterionId)
);
GO

IF OBJECT_ID(N'asmt.RubricAssessment', N'U') IS NULL
CREATE TABLE asmt.RubricAssessment (
      RubricAssessmentId INT             NOT NULL IDENTITY(1,1)
    , RubricId          INT              NOT NULL
    , EnrollmentId      INT              NULL
    , QuizAttemptId     INT              NULL
    , EmployeeId        INT              NOT NULL
    , AssessorUserId    INT              NOT NULL
    , TotalPoints       DECIMAL(9,2)     NULL
    , ScorePercent      DECIMAL(5,2)     NULL
    , Comments          NVARCHAR(MAX)    NULL
    , AssessedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_RubricAssessment_AssessedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_RubricAssessment PRIMARY KEY CLUSTERED (RubricAssessmentId)
    , CONSTRAINT FK_RubricAssessment_Rubric   FOREIGN KEY (RubricId)   REFERENCES asmt.Rubric (RubricId)
    , CONSTRAINT FK_RubricAssessment_Employee FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId)
);
GO

IF OBJECT_ID(N'asmt.RubricAssessmentRating', N'U') IS NULL
CREATE TABLE asmt.RubricAssessmentRating (
      RubricAssessmentRatingId INT       NOT NULL IDENTITY(1,1)
    , RubricAssessmentId INT             NOT NULL
    , RubricCriterionId INT              NOT NULL
    , RubricLevelId     INT              NULL
    , PointsAwarded     DECIMAL(9,2)     NOT NULL
    , Comments          NVARCHAR(1000)   NULL
    , CONSTRAINT PK_RubricAssessmentRating PRIMARY KEY CLUSTERED (RubricAssessmentRatingId)
    , CONSTRAINT UQ_RubricAssessmentRating UNIQUE (RubricAssessmentId, RubricCriterionId)
    , CONSTRAINT FK_RAR_Assessment FOREIGN KEY (RubricAssessmentId) REFERENCES asmt.RubricAssessment (RubricAssessmentId)
    , CONSTRAINT FK_RAR_Criterion  FOREIGN KEY (RubricCriterionId)  REFERENCES asmt.RubricCriterion (RubricCriterionId)
);
GO

/* =============================================================================
   EVALUACION PRACTICA / OJT
   Esta es la evidencia que ISO 9001 cl.7.2 llama "registros de entrenamiento en
   el puesto" y que R2v3 exige como competencia tecnica del trabajador.
   ============================================================================= */

IF OBJECT_ID(N'asmt.PracticalAssessmentTemplate', N'U') IS NULL
CREATE TABLE asmt.PracticalAssessmentTemplate (
      PracticalTemplateId INT            NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_PracticalTemplate_PublicId DEFAULT NEWID()
    , TemplateCode      NVARCHAR(40)     NOT NULL
    , NameEs            NVARCHAR(250)    NOT NULL
    , NameEn            NVARCHAR(250)    NULL
    , CompetencyId      INT              NULL
    , StationId         INT              NULL
    , RequiredRepetitions TINYINT        NOT NULL CONSTRAINT DF_PracticalTemplate_Reps DEFAULT 1
        /* "ejecuto el proceso correctamente N de N veces" */
    , PassingScore      DECIMAL(5,2)     NOT NULL CONSTRAINT DF_PracticalTemplate_PassingScore DEFAULT 100.00
    , MinimumEvaluatorLevelId INT        NULL       -- el evaluador debe tener >= este nivel
    , RequiresDualSignature BIT          NOT NULL CONSTRAINT DF_PracticalTemplate_DualSig DEFAULT 1
    , InstructionsEs    NVARCHAR(MAX)    NULL
    , InstructionsEn    NVARCHAR(MAX)    NULL
    , IsActive          BIT              NOT NULL CONSTRAINT DF_PracticalTemplate_IsActive DEFAULT 1
    , CreatedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_PracticalTemplate_CreatedAtUtc DEFAULT SYSUTCDATETIME()
    , CreatedByUserId   INT              NOT NULL
    , RowVersion        ROWVERSION       NOT NULL
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_PracticalTemplate_IsDeleted DEFAULT 0
    , CONSTRAINT PK_PracticalAssessmentTemplate PRIMARY KEY CLUSTERED (PracticalTemplateId)
    , CONSTRAINT UQ_PracticalTemplate_Code UNIQUE (TemplateCode)
);
GO

IF OBJECT_ID(N'asmt.PracticalCriterion', N'U') IS NULL
CREATE TABLE asmt.PracticalCriterion (
      PracticalCriterionId INT           NOT NULL IDENTITY(1,1)
    , PracticalTemplateId INT            NOT NULL
    , DescriptionEs     NVARCHAR(1000)   NOT NULL   -- observable, verificable
    , DescriptionEn     NVARCHAR(1000)   NULL
    , SortOrder         INT              NOT NULL
    , IsCritical        BIT              NOT NULL CONSTRAINT DF_PracticalCriterion_IsCritical DEFAULT 0
        /* Fallar un criterio critico reprueba toda la evaluacion */
    , Weight            DECIMAL(5,2)     NOT NULL CONSTRAINT DF_PracticalCriterion_Weight DEFAULT 1
    , ReferenceDocumentCode NVARCHAR(60) NULL
    , RequiresPhoto     BIT              NOT NULL CONSTRAINT DF_PracticalCriterion_RequiresPhoto DEFAULT 0
    , IsDeleted         BIT              NOT NULL CONSTRAINT DF_PracticalCriterion_IsDeleted DEFAULT 0
    , CONSTRAINT PK_PracticalCriterion PRIMARY KEY CLUSTERED (PracticalCriterionId)
    , CONSTRAINT FK_PracticalCriterion_Template FOREIGN KEY (PracticalTemplateId) REFERENCES asmt.PracticalAssessmentTemplate (PracticalTemplateId)
);
GO

IF OBJECT_ID(N'asmt.PracticalAssessment', N'U') IS NULL
CREATE TABLE asmt.PracticalAssessment (
      PracticalAssessmentId INT          NOT NULL IDENTITY(1,1)
    , PublicId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_PracticalAssessment_PublicId DEFAULT NEWID()
    , PracticalTemplateId INT            NOT NULL
    , EnrollmentId      INT              NULL
    , EmployeeId        INT              NOT NULL   -- el evaluado
    , EvaluatorUserId   INT              NOT NULL   -- el evaluador
    , StationId         INT              NULL
    , AttemptNumber     TINYINT          NOT NULL CONSTRAINT DF_PracticalAssessment_Attempt DEFAULT 1
    , RepetitionsObserved TINYINT        NOT NULL CONSTRAINT DF_PracticalAssessment_Reps DEFAULT 0
    , RepetitionsPassed TINYINT          NOT NULL CONSTRAINT DF_PracticalAssessment_RepsPassed DEFAULT 0
    , [Status]          TINYINT          NOT NULL CONSTRAINT DF_PracticalAssessment_Status DEFAULT 1
        /* 1=InProgress 2=Submitted 3=Passed 4=Failed 5=Voided */
    , ScorePercent      DECIMAL(5,2)     NULL
    , IsPassed          BIT              NULL
    , CriticalFailureCount TINYINT       NOT NULL CONSTRAINT DF_PracticalAssessment_CritFail DEFAULT 0
    , EvaluatorComments NVARCHAR(MAX)    NULL
    , EmployeeComments  NVARCHAR(MAX)    NULL
    , StartedAtUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_PracticalAssessment_StartedAtUtc DEFAULT SYSUTCDATETIME()
    , SubmittedAtUtc    DATETIME2(3)     NULL
    , EvaluatorSignatureId BIGINT        NULL       -- aud.SignatureRecord
    , EmployeeSignatureId BIGINT         NULL
    , SupersededByAssessmentId INT       NULL       -- correccion = nueva evaluacion
    , VoidReason        NVARCHAR(1000)   NULL
    , RowVersion        ROWVERSION       NOT NULL
    , CONSTRAINT PK_PracticalAssessment PRIMARY KEY CLUSTERED (PracticalAssessmentId)
    , CONSTRAINT UQ_PracticalAssessment_PublicId UNIQUE NONCLUSTERED (PublicId)
    , CONSTRAINT FK_PracticalAssessment_Template FOREIGN KEY (PracticalTemplateId) REFERENCES asmt.PracticalAssessmentTemplate (PracticalTemplateId)
    , CONSTRAINT FK_PracticalAssessment_Employee FOREIGN KEY (EmployeeId) REFERENCES org.Employee (EmployeeId)
    , CONSTRAINT FK_PracticalAssessment_Superseded FOREIGN KEY (SupersededByAssessmentId) REFERENCES asmt.PracticalAssessment (PracticalAssessmentId)
    , CONSTRAINT CK_PracticalAssessment_Status CHECK ([Status] BETWEEN 1 AND 5)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PracticalAssessment_Employee' AND object_id = OBJECT_ID(N'asmt.PracticalAssessment'))
    CREATE NONCLUSTERED INDEX IX_PracticalAssessment_Employee ON asmt.PracticalAssessment (EmployeeId, [Status])
        INCLUDE (PracticalTemplateId, SubmittedAtUtc, IsPassed);
GO

IF OBJECT_ID(N'asmt.PracticalCriterionResult', N'U') IS NULL
CREATE TABLE asmt.PracticalCriterionResult (
      PracticalCriterionResultId INT     NOT NULL IDENTITY(1,1)
    , PracticalAssessmentId INT          NOT NULL
    , PracticalCriterionId INT           NOT NULL
    , CriterionTextSnapshot NVARCHAR(1000) NOT NULL  -- snapshot para auditoria
    , IsCriticalSnapshot BIT             NOT NULL
    , ResultCode        TINYINT          NOT NULL   -- 1=Pass 2=Fail 3=NotApplicable
    , Comments          NVARCHAR(1000)   NULL
    , RecordedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_PCR_RecordedAtUtc DEFAULT SYSUTCDATETIME()
    , CONSTRAINT PK_PracticalCriterionResult PRIMARY KEY CLUSTERED (PracticalCriterionResultId)
    , CONSTRAINT UQ_PracticalCriterionResult UNIQUE (PracticalAssessmentId, PracticalCriterionId)
    , CONSTRAINT FK_PCR_Assessment FOREIGN KEY (PracticalAssessmentId) REFERENCES asmt.PracticalAssessment (PracticalAssessmentId)
    , CONSTRAINT FK_PCR_Criterion  FOREIGN KEY (PracticalCriterionId)  REFERENCES asmt.PracticalCriterion (PracticalCriterionId)
    , CONSTRAINT CK_PCR_ResultCode CHECK (ResultCode IN (1,2,3))
);
GO

IF OBJECT_ID(N'asmt.PracticalAssessmentAttachment', N'U') IS NULL
CREATE TABLE asmt.PracticalAssessmentAttachment (
      AttachmentId      INT              NOT NULL IDENTITY(1,1)
    , PracticalAssessmentId INT          NOT NULL
    , PracticalCriterionId INT           NULL
    , FileAssetId       INT              NOT NULL
    , [Description]     NVARCHAR(400)    NULL
    , UploadedAtUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_PAA_UploadedAtUtc DEFAULT SYSUTCDATETIME()
    , UploadedByUserId  INT              NOT NULL
    , CONSTRAINT PK_PracticalAssessmentAttachment PRIMARY KEY CLUSTERED (AttachmentId)
    , CONSTRAINT FK_PAA_Assessment FOREIGN KEY (PracticalAssessmentId) REFERENCES asmt.PracticalAssessment (PracticalAssessmentId)
);
GO

PRINT '=== 05_tables_assessment.sql completado ===';
GO
