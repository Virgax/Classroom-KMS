# 04 — Modelo de datos

Base de datos: **`AIRLINK_LMS`** (SQL Server 2019+).
DDL completo en `database/02_*.sql` a `database/08_*.sql`.

## 1. Esquemas

| Esquema | Contenido | Tablas |
|---|---|---|
| `sec` | Identidad, usuarios, roles, permisos, sesiones | 9 |
| `org` | Organización, sitios, departamentos, áreas, posiciones, empleados | 8 |
| `lms` | Cursos, versiones, módulos, items, contenido, programas | 14 |
| `asmt` | Bancos, preguntas, quizzes, intentos, rúbricas, evaluación práctica | 15 |
| `dlv` | Inscripciones, progreso, cohortes, sesiones ILT, asistencia | 10 |
| `comp` | Competencias, requisitos, certificaciones, documentos controlados, waivers | 14 |
| `aud` | Log de eventos, errores, firmas, idempotencia | 5 |
| `intg` | Staging de sync, watermarks, mapeos externos | 5 |
| `ops` | Settings, feature flags, notificaciones, jobs, archivos | 8 |
| `rpt` | Vistas de reportería (sin tablas propias) | 0 |

Total: ~88 tablas.

---

## 2. Diagrama lógico por dominio

### 2.1 Identidad y organización

```
org.Organization
    └── org.Site
            └── org.Department
                    └── org.Area                    (línea / celda de producción)
                            └── org.Station         (estación de trabajo)

org.Position ──┬── org.PositionCompetencyProfile
               │
org.Employee ──┼── org.EmployeePosition   (N posiciones: 1 primaria + N secundarias)
               └── org.EmployeeAssignment (sitio/depto/área/turno vigente, temporal)
                        │
                   sec.User  (1:0..1 — no todo empleado tiene cuenta; no todo
                              usuario es empleado: contratistas, auditores)

sec.User ── sec.UserRoleAssignment ── sec.Role ── sec.RolePermission ── sec.Permission
                    │
              (con ScopeType + ScopeId: Global | Site | Department | Area)

sec.UserCredential   (PIN hasheado para kiosko; NULL si solo usa Entra ID)
sec.UserSession      (sesiones activas, para revocación y auto-logout de kiosko)
sec.DeviceRegistration (terminales de kiosko autorizadas)
```

**Decisión clave:** `org.Employee` y `sec.User` son entidades **separadas**.
`Employee` es el hecho de RH (viene de SPN, read-only, nunca lo editamos).
`User` es la identidad de aplicación. Un operador de piso tiene `Employee` y
`User` (con PIN). Un auditor externo tiene `User` sin `Employee`. Mezclarlos es el
error clásico que después obliga a un refactor doloroso.

### 2.2 Catálogo y contenido

```
lms.Course  (código estable, dueño, tipo, categoría)
    └── lms.CourseVersion  (versionado, inmutable al publicar)  ← TEMPORAL
            ├── lms.CourseModule  (secuencia, prerequisitos, requisitos de completación)
            │       └── lms.ModuleItem  (polimórfico → ItemType + TargetId)
            │               ├── → lms.Page
            │               ├── → ops.FileAsset
            │               ├── → asmt.Quiz
            │               ├── → asmt.PracticalAssessmentTemplate
            │               ├── → comp.ControlledDocumentRevision
            │               └── → lms.ExternalResource
            ├── lms.CourseVersionLocale  (es-DO, en-US: estado de traducción)
            └── lms.CourseSetting  (intentos, score mínimo, anti-skip, ...)

lms.ContentTranslation  (PK compuesta: EntityType + EntityId + LocaleCode)
                        ← toda cadena visible al usuario pasa por aquí

lms.Program  (learning path)
    └── lms.ProgramCourse  (secuencia + obligatorio/electivo + prerequisitos)

lms.CourseCategory      (jerárquica)
lms.CourseBlueprintLink (curso maestro → derivados, con sync de contenido)
lms.CourseApproval      (workflow Draft → InReview → Published)
```

**Patrón `ModuleItem` polimórfico:** `ItemType` (tinyint, enum) + `TargetId` (int).
Sin FK física — la integridad la garantizan los SPs. Alternativa considerada
(una FK nullable por tipo) se descartó: 8 columnas nullables y un check constraint
gigante que hay que modificar cada vez que se agrega un tipo. Trade-off aceptado
conscientemente: perdemos integridad declarativa, ganamos extensibilidad. El SP
`lms.usp_ModuleItem_Add` valida que el target exista según el tipo.

### 2.3 Evaluación

```
asmt.QuestionBank
    └── asmt.Question  (tipo, texto, puntos, feedback, dificultad, competencia)
            ├── asmt.QuestionOption   (opciones; para MC/MA/TF/Matching)
            └── asmt.QuestionMedia    (imagen para HotSpot, audio, video)

asmt.Quiz
    ├── asmt.QuizSection      (agrupa preguntas; permite "N del banco X")
    │       └── asmt.QuizSectionSource  (banco + cantidad + filtros)
    ├── asmt.QuizQuestion     (preguntas fijas, si no es aleatorio)
    └── asmt.QuizSetting

asmt.QuizAttempt  (por inscripción)
    ├── asmt.QuizAttemptQuestion   ← SNAPSHOT de la pregunta servida
    ├── asmt.QuizAttemptOption     ← SNAPSHOT de las opciones y su orden
    └── asmt.QuizAttemptAnswer     (respuesta + correcto + puntos + calificador)

asmt.Rubric
    ├── asmt.RubricCriterion
    └── asmt.RubricLevel
asmt.RubricAssessment → asmt.RubricAssessmentRating

asmt.PracticalAssessmentTemplate
    └── asmt.PracticalCriterion   (observable, IsCritical, orden)
asmt.PracticalAssessment          (instancia ejecutada)
    ├── asmt.PracticalCriterionResult
    └── asmt.PracticalAssessmentAttachment
```

**El snapshot del intento es no negociable.** Si el banco de preguntas cambia en
2027, el intento de 2026 tiene que seguir siendo reproducible tal como se
presentó, con las opciones en el orden en que se mostraron. Sin esto, un auditor
puede impugnar toda la evidencia de evaluación. Es la razón de existir de
`QuizAttemptQuestion` / `QuizAttemptOption`.

### 2.4 Delivery

```
dlv.Cohort  (curso + turno + instructor + periodo)  ← equivalente a section
dlv.Enrollment   ← TEMPORAL
    │  (EmployeeId, CourseVersionId, CohortId?, Source, Status, Due, Attempt#)
    ├── dlv.ItemProgress   (por ModuleItem: status, tiempo, vistas)
    ├── dlv.ModuleProgress (derivado, materializado para performance)
    └── dlv.EnrollmentEvidence  (une el enrollment con lo que lo satisface:
                                 QuizAttempt, PracticalAssessment,
                                 SessionAttendance, Acknowledgment)

dlv.TrainingSession  (ILT: curso + instructor + fecha + ubicación + capacidad)
    ├── dlv.SessionRegistration  (inscrito / lista de espera / confirmado)
    ├── dlv.SessionAttendance    (check-in, estado, minutos, firma)
    └── dlv.SessionMaterial

dlv.EnrollmentExtension  (prórroga con justificación y aprobador)
dlv.LearningActivity     (heartbeat de actividad, 30s; alimenta TimeSpent)
```

`dlv.Enrollment` es la entidad más consultada del sistema. Índices críticos:
`(EmployeeId, Status)`, `(CourseVersionId, Status)`, `(DueAtUtc)` filtrado por
`Status IN (Assigned, InProgress)`.

### 2.5 Compliance — el núcleo del valor

```
comp.Competency  (habilidad certificable)
    └── comp.CompetencyLevel  (Awareness/Basic/Competent/Advanced/Trainer)

comp.CompetencyRequirement   ← TEMPORAL   ★ tabla más importante del sistema
    │  Scope: Position | Department | Area | Station | Employee
    │  + CompetencyId + MinimumLevelId
    │  + ValidityMonths (NULL = no vence)
    │  + AlertWindowDays (60/30/7)
    │  + Criticality (Critical | Major | Minor)
    │  + RegulatoryBasis ('ISO 9001:2015 cl.7.2', 'R2v3 Core 4', 'FA4', 'OSHA')
    ├── comp.RequirementSatisfier  (qué lo satisface: curso, programa,
    │                               evaluación práctica, documento, credencial externa)
    └── comp.RequirementDocument   (documentos controlados ligados)

comp.Certification   ← TEMPORAL
    │  (EmployeeId, CompetencyId, LevelId, IssuedAtUtc, ExpiresAtUtc,
    │   Status, IssuedBy, CertificateNumber, SignatureRecordId)
    └── comp.CertificationEvidence  (qué inscripciones/evaluaciones la sustentan)

comp.CompetencyGap   (materializada por el motor; refrescada nocturna + on-demand)
    (EmployeeId, RequirementId, GapType, Severity, DetectedAtUtc, ResolvedAtUtc)

comp.Waiver  (excepción: requisito + empleado + justificación + aprobador + vence)

comp.ControlledDocument
    └── comp.ControlledDocumentRevision  (Rev.N, EffectiveAtUtc, PDF, cambios,
                                          RequiresReacknowledgment)
            ├── comp.DocumentApproval    (aprobadores: autor, revisor, aprobador)
            └── comp.DocumentAcknowledgment (empleado firmó revisión N)

comp.EvaluatorQualification  (quién puede evaluar qué competencia y hasta qué nivel)
comp.CertificationTemplate   (plantilla del PDF del certificado, bilingüe)
```

**Separación crítica Course vs Requirement.** En Canvas, si quieres obligar a
alguien lo inscribes en un curso. Aquí no: el **requisito** obliga, y el curso es
solo uno de los medios de satisfacerlo (`RequirementSatisfier`). Eso permite:

- Un requisito satisfecho por *cualquiera* de 3 cursos equivalentes.
- Un requisito satisfecho por una credencial externa (ej. certificado de OSHA
  traído de otro empleo) sin inventar un curso falso.
- Reemplazar el curso que satisface un requisito sin invalidar las
  certificaciones ya emitidas.
- Reportar cumplimiento por competencia, que es como pregunta el auditor, no por
  curso, que es como lo modelan los LMS.

### 2.6 Plataforma

```
aud.EventLog        (toda escritura: actor, entidad, acción, valores antes/después JSON)
aud.ErrorLog        (excepciones de SP con contexto)
aud.SignatureRecord (hash SHA-256 + PreviousHash → cadena por empleado)
aud.IdempotencyKey  (clave → resultado, TTL 24h)
aud.DataAccessLog   (lecturas de PII: quién vio el expediente de quién)

intg.SyncWatermark      (última marca por fuente: SPN.Employee, AIRLINK.x)
intg.EmployeeStaging    (landing del sync de SPN antes del merge)
intg.SyncRun            (ejecución: inicio, fin, filas, errores)
intg.ExternalIdMap      (sistema externo + id externo → entidad interna)
intg.IntegrationError   (fila rechazada + motivo, para reproceso)

ops.Setting            (clave/valor tipado, por scope, versionado)
ops.FeatureFlag        (flag + regla de audiencia)
ops.NotificationTemplate (bilingüe, por evento)
ops.NotificationQueue  (cola + retry + dead-letter)
ops.NotificationLog
ops.FileAsset          (metadata; el binario va a blob/share)
ops.JobRun             (jobs de SQL Agent y del worker)
ops.AppLog             (log de aplicación relevante para negocio)
```

---

## 3. Convenciones (resumen ejecutable)

Ver `CLAUDE.md` §3 para el detalle completo. Lo esencial:

- PK: `<Tabla>Id INT IDENTITY(1,1)`, clustered.
- ID público: `PublicId UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID()`, único
  non-clustered. **Es el único ID que sale por la API.**
- Fechas: `DATETIME2(3)`, siempre UTC, sufijo `Utc` en el nombre.
- Texto: `NVARCHAR` siempre.
- Enums: `TINYINT` + tabla de referencia en `ops.Lookup*` o CHECK constraint
  documentado. Nunca strings mágicos.
- Auditoría: `CreatedAtUtc`, `CreatedByUserId`, `ModifiedAtUtc`,
  `ModifiedByUserId`, `RowVersion`, `IsDeleted` en toda tabla transaccional.
- Soft delete siempre; filtro en el SP, más un índice filtrado
  `WHERE IsDeleted = 0` en las tablas grandes.
- Temporal tables en: `lms.CourseVersion`, `dlv.Enrollment`,
  `comp.CompetencyRequirement`, `comp.Certification`, `sec.UserRoleAssignment`.

---

## 4. Estrategia de índices

| Tabla | Índice | Justificación |
|---|---|---|
| `dlv.Enrollment` | `IX_Enrollment_Employee_Status (EmployeeId, Status) INCLUDE (CourseVersionId, DueAtUtc)` | Dashboard del learner |
| `dlv.Enrollment` | `IX_Enrollment_Due (DueAtUtc) WHERE Status IN (1,2)` filtrado | Job de vencimientos |
| `dlv.ItemProgress` | `IX_ItemProgress_Enrollment (EnrollmentId, ModuleItemId)` único | Upsert de progreso |
| `comp.Certification` | `IX_Certification_Employee_Comp (EmployeeId, CompetencyId, Status)` | Chequeo de elegibilidad |
| `comp.Certification` | `IX_Certification_Expiry (ExpiresAtUtc) WHERE Status = 1` filtrado | Job de vencimientos |
| `comp.CompetencyGap` | `IX_Gap_Employee_Severity (EmployeeId, Severity) WHERE ResolvedAtUtc IS NULL` | Dashboards de brechas |
| `asmt.QuizAttempt` | `IX_QuizAttempt_Enrollment (EnrollmentId, AttemptNumber)` | Historia de intentos |
| `comp.DocumentAcknowledgment` | `IX_DocAck_Revision_Employee (RevisionId, EmployeeId)` único | % de firma por revisión |
| `aud.EventLog` | `IX_EventLog_Entity (EntityType, EntityId, OccurredAtUtc DESC)` | Trazabilidad por entidad |
| `org.Employee` | `UQ_Employee_Code (EmployeeCode)` único | Login de kiosko, sync SPN |

`aud.EventLog` y `dlv.LearningActivity` van **particionadas por mes** con
compresión de página. Son las que crecen sin control.

---

## 5. Retención y archivado

| Datos | Retención activa | Archivo | Base |
|---|---|---|---|
| Certificaciones y evidencia | Permanente | — | ISO 9001 7.5, R2v3 |
| Registros de entrenamiento | 7 años | Permanente en archivo | Compliance |
| Intentos de quiz | 3 años | 7 años | Evidencia de evaluación |
| Acknowledgments de WI | Permanente | — | Trazabilidad de revisión |
| `aud.EventLog` | 2 años | 7 años | Auditoría |
| `dlv.LearningActivity` | 90 días | — | Solo operativo |
| `intg.*Staging` | 30 días | — | Solo operativo |
| Sesiones y tokens | 30 días | — | Seguridad |

Job mensual `ops.usp_Retention_Apply` mueve a `AIRLINK_LMS_ARCHIVE` y purga.
Nunca borra nada con estado de compliance vigente.
