# 02 — Módulos funcionales y requerimientos

## 1. Mapa de módulos

14 módulos. Los marcados **[CORE]** son fase 1–2; **[COMP]** son el diferenciador
de compliance (fase 3–4); **[EXT]** son extensiones posteriores.

```
┌─────────────────────────────────────────────────────────────────────┐
│ M01 Identidad y Organización            [CORE]                      │
│ M02 Catálogo de Cursos                  [CORE]                      │
│ M03 Autoría de Contenido                [CORE]                      │
│ M04 Inscripción y Asignación            [CORE]                      │
│ M05 Delivery y Progreso                 [CORE]                      │
│ M06 Evaluación (quizzes + bancos)       [CORE]                      │
│ M07 Evaluación Práctica y OJT           [COMP]                      │
│ M08 Sesiones Presenciales (ILT)         [COMP]                      │
│ M09 Documentos Controlados (WI/SOP)     [COMP]                      │
│ M10 Competencias y Certificación        [COMP]                      │
│ M11 Reportería y Evidencia de Auditoría [COMP]                      │
│ M12 Notificaciones y Recordatorios      [CORE]                      │
│ M13 Administración y Configuración      [CORE]                      │
│ M14 Integraciones                       [EXT]                       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## M01 — Identidad y Organización [CORE]

**Propósito:** saber quién es cada persona, dónde trabaja y qué puede hacer.

### Funcionalidad
- Sincronización de empleados desde `SPN` (código, nombre, cédula, posición,
  departamento, supervisor, fecha de ingreso, estado). Read-only, sync
  incremental cada hora + full nocturno.
- Jerarquía organizacional: **Organización → Sitio → Departamento → Área/Línea**.
  Fija, 4 niveles. No anidamiento arbitrario.
- Catálogo de **Posiciones** (job titles) independiente de SPN pero mapeado a él.
- Autenticación dual:
  - **Entra ID (OIDC)** para staff con cuenta M365.
  - **Código de empleado + PIN** para operadores de piso, en kiosko.
- RBAC: 7 roles base (ver `docs/06-seguridad-y-rbac.md`), permisos granulares,
  y **scope** del rol (global / sitio / departamento). Un supervisor de SMT no ve
  data de Data Sanitization.

### Reglas de negocio
- Un empleado inactivo en SPN se marca inactivo en Classroom pero **no se borra**:
  sus registros de entrenamiento son evidencia con retención de 3+ años.
- Un empleado puede tener múltiples posiciones (primaria + secundarias). Los
  requisitos de competencia son la **unión** de todas sus posiciones.
- Cambio de posición dispara recálculo de brechas de competencia.

### Casos de uso
| ID | Actor | Caso |
|---|---|---|
| UC-01.1 | Sistema | Sincronizar empleados nuevos y cambios desde SPN |
| UC-01.2 | Operador | Login en kiosko con código + PIN |
| UC-01.3 | Staff | Login SSO con Entra ID |
| UC-01.4 | Admin | Asignar rol con scope departamental |
| UC-01.5 | Sistema | Detectar cambio de posición y recalcular requisitos |

---

## M02 — Catálogo de Cursos [CORE]

**Propósito:** el inventario de todo lo que se puede aprender.

### Funcionalidad
- **Course**: entidad estable con código único (`CRS-IQC-001`), nombre, tipo,
  categoría, duración estimada, propietario.
- **CourseVersion**: el contenido versionado. Un curso vive; sus versiones se
  publican y se archivan. Estados: `Draft → InReview → Published → Retired`.
- Tipos de curso: `ELearning`, `InstructorLed`, `Blended`, `DocumentAcknowledgment`,
  `OnTheJob`, `External`.
- **Blueprint** (curso maestro) → cursos derivados por departamento, con push de
  actualizaciones.
- **Learning Path / Programa**: secuencia de cursos con prerequisitos
  (ej. "Certificación Operador IQC Nivel 1" = 4 cursos + 1 evaluación práctica).
- Catálogo público navegable con búsqueda, filtros por departamento, categoría,
  idioma disponible y modalidad.

### Reglas de negocio
- Un `CourseVersion` publicado es **inmutable**. Cambio = versión nueva.
- Publicar una versión nueva no invalida las certificaciones existentes por
  defecto: eso lo decide un flag `RequiresRetraining` en la versión.
- No se puede retirar un curso con inscripciones activas o que sea referenciado
  por un `CompetencyRequirement` vigente.
- Todo curso publicado debe tener contenido en `es-DO` como mínimo.

---

## M03 — Autoría de Contenido [CORE]

**Propósito:** que Calidad y los supervisores creen contenido sin depender de IT.

### Funcionalidad
- Editor de **Pages** (rich text, imágenes, tablas, embeds) con sanitización HTML.
- Estructura **Module → ModuleItem** (patrón de Canvas):
  - `Page`, `File`, `Video`, `Quiz`, `PracticalAssessment`,
    `DocumentAcknowledgment`, `ExternalLink`, `SubHeader`
- **Requisitos de completación** por módulo: ver / marcar como hecho / puntaje
  mínimo / entregar.
- **Prerequisitos**: módulo N requiere módulo N-1 completado.
- Biblioteca de archivos con versionado, tipos permitidos y límite de tamaño.
- Video: hosting en Azure Blob / share interno con streaming progresivo; tracking
  de % visto (anti-skip para contenido de seguridad).
- **Traducciones**: cada `Page`/`Quiz` tiene N traducciones por locale, con estado
  de traducción independiente.
- Import de PDF/DOCX de WIs existentes convertidos a item de tipo
  `DocumentAcknowledgment`.

### Reglas de negocio
- El contenido de una versión publicada no se edita. Se clona a Draft.
- Anti-skip: si `EnforceMinimumTime = 1`, el item no se marca completo antes del
  tiempo mínimo configurado. Necesario para contenido de EHS.

---

## M04 — Inscripción y Asignación [CORE]

**Propósito:** conectar personas con cursos, por 4 vías distintas.

### Funcionalidad
Cuatro mecanismos de inscripción, con precedencia:

1. **Requerida por competencia** (automática, no removible por el empleado).
   Generada por el motor de M10. Es la vía principal.
2. **Asignada por supervisor/admin** (manual, con fecha límite y justificación).
3. **Auto-inscripción** (el empleado elige del catálogo, si está habilitado).
4. **Inscripción masiva** (por departamento, posición, sitio o lista de códigos;
   CSV upload o filtro dinámico).

- **Cohortes** (equivalente a `sections` de Canvas): mismo curso, distinto turno
  e instructor. Un empleado pertenece a una cohorte.
- Estados de inscripción: `Assigned → InProgress → Completed | Failed |
  Withdrawn | Expired`.
- Fechas: `AssignedAtUtc`, `DueAtUtc`, `StartedAtUtc`, `CompletedAtUtc`.
- Lista de espera para ILT con capacidad limitada, con promoción automática.
- Extensión de fecha límite con justificación y aprobación (queda en audit log).

### Reglas de negocio
- Una inscripción de origen `CompetencyRequired` no puede ser cancelada por el
  empleado ni por el supervisor directo — solo por el dueño del requisito.
- Re-inscripción al mismo curso crea un registro **nuevo**; nunca se sobreescribe
  el anterior (historia de auditoría).
- Máximo de intentos configurable por curso; agotarlos escala al supervisor.

---

## M05 — Delivery y Progreso [CORE]

**Propósito:** la experiencia del learner y el rastro de qué hizo.

### Funcionalidad
- **Dashboard del empleado**: mis pendientes, por vencer, vencidos, completados,
  certificados vigentes.
- Player de curso con navegación por módulos, indicador de progreso, y
  continuación desde donde se quedó (`LastAccessedItemId`).
- Tracking granular: `ItemProgress` por item con `Status`, `TimeSpentSeconds`,
  `ViewCount`, `FirstAccessedAtUtc`, `CompletedAtUtc`.
- Progreso de curso calculado: `% items completados` ponderado por requisito.
- **Modo kiosko de piso**: pantalla táctil grande, sesión corta, auto-logout a los
  90 segundos de inactividad, sin acceso a data de otros empleados.
- Modo baja conectividad: cachear el contenido del curso actual en el cliente y
  encolar eventos de progreso para sync (Service Worker / IndexedDB).

### Reglas de negocio
- El progreso se registra server-side. El cliente propone, el SP valida.
- Un item no se puede marcar completo si sus prerequisitos no están completos —
  validado en el SP, no en el front.
- El tiempo se acumula por heartbeat cada 30s, no por diferencia de timestamps
  (evita inflar tiempo dejando la pestaña abierta).

---

## M06 — Evaluación: quizzes y bancos de preguntas [CORE]

**Propósito:** medir conocimiento con integridad razonable.

### Funcionalidad
- **QuestionBank** por categoría/competencia, reutilizable entre cursos.
- Tipos de pregunta: `MultipleChoice`, `MultipleAnswer`, `TrueFalse`,
  `Matching`, `Ordering`, `ShortAnswer`, `Numeric`, `Essay`, `HotSpot`
  (marcar zona en una imagen — útilísimo para identificar componentes/defectos),
  `FileUpload`.
- Auto-calificación de todos los tipos objetivos. `Essay` y `FileUpload` van a
  cola de calificación manual.
- **Selección aleatoria**: "toma 20 preguntas del banco X, 5 del banco Y",
  con randomización de orden de preguntas y de opciones.
- Configuración por quiz: intentos permitidos, política de nota
  (`Highest | Latest | Average`), score mínimo para aprobar, límite de tiempo,
  mostrar respuestas correctas (nunca / después de aprobar / siempre),
  bloqueo de retroceso.
- **QuizAttempt** con snapshot de las preguntas servidas: si el banco cambia
  después, el intento histórico sigue siendo reproducible. Crítico para auditoría.
- Rúbricas con criterios y niveles de desempeño para lo subjetivo.
- Feedback por pregunta y por respuesta incorrecta (con referencia a la sección de
  la WI donde está la respuesta).

### Reglas de negocio
- El score mínimo para contenido de compliance es 80% por defecto, configurable
  por requisito, no por quiz.
- Los intentos se guardan **todos**. Nunca se borra un intento fallido.
- Un intento abandonado (sin submit) se auto-cierra al expirar el límite de tiempo
  con el estado `Abandoned` y se califica con lo respondido.

---

## M07 — Evaluación práctica y OJT [COMP]

**Propósito:** certificar habilidad observada, no conocimiento declarado.

### Funcionalidad
- **PracticalAssessment**: checklist de criterios observables, cada uno con
  resultado `Pass | Fail | NotApplicable` y comentario del evaluador.
- Criterios críticos (`IsCritical = 1`): fallar uno reprueba la evaluación
  completa independientemente del score total.
- Requiere **evaluador calificado**: el sistema valida que el evaluador tenga a su
  vez la certificación de nivel superior en esa competencia. Sin esto, la
  evidencia no vale nada ante un auditor.
- Registro de **repeticiones observadas** (ej. "ejecutó el proceso correctamente 3
  de 3 veces").
- Firma dual: evaluador + evaluado, ambas con `SignatureRecord` hasheado.
- Adjuntos: foto del setup, del resultado, del defecto identificado.
- Reevaluación programada según el ciclo del requisito.

### Reglas de negocio
- Un empleado no puede evaluarse a sí mismo. Validado en SP.
- Un supervisor no puede evaluar sin estar certificado como evaluador en esa
  competencia (`comp.EvaluatorQualification`).
- Una evaluación práctica firmada es inmutable. Corrección = nueva evaluación con
  referencia a la anterior + justificación.

---

## M08 — Sesiones presenciales (ILT) [COMP]

**Propósito:** el 70% del entrenamiento real de Airlink.

### Funcionalidad
- **TrainingSession**: curso + instructor + fecha/hora + ubicación (sala, línea,
  estación) + capacidad + idioma.
- Sesiones recurrentes (ej. inducción cada lunes 8am).
- Roster: inscritos, lista de espera, confirmados, asistentes, ausentes.
- **Check-in**: por escaneo de badge, código de empleado en tablet, o marcado
  manual del instructor. Con timestamp.
- Asistencia parcial: `Present | Late | LeftEarly | Absent | Excused`, con
  minutos asistidos vs. requeridos.
- Firma del roster: instructor firma la lista completa; cada participante firma su
  asistencia. Genera el "sign-in sheet" digital que el auditor pide.
- Cierre de sesión: el instructor marca resultados (aprobado/no aprobado por
  participante), sube materiales usados y notas.
- Conflictos: no permitir doble booking de instructor ni de sala.
- Impacto en producción: alerta si >X% de una línea está en entrenamiento a la
  misma hora.

### Reglas de negocio
- Una sesión no se cierra sin roster firmado por el instructor.
- La asistencia por sí sola no otorga certificación si el curso también requiere
  quiz o evaluación práctica.
- Cancelar una sesión con inscritos requiere motivo y notifica a todos.

---

## M09 — Documentos controlados (WI / SOP) [COMP]

**Propósito:** el puente entre el sistema documental de Calidad y el LMS.
Este módulo es lo que hace que Classroom valga más que Canvas.

### Funcionalidad
- **ControlledDocument**: código (`WI-IP68-RXR-001`), título, tipo
  (`WorkInstruction | SOP | Policy | Form | Spec | SafetyDataSheet`),
  proceso dueño, departamento, clasificación.
- **ControlledDocumentRevision**: `Rev.0`, `Rev.1`, ... con `EffectiveAtUtc`,
  archivo (PDF), resumen de cambios, aprobadores.
- **Acknowledgment**: el empleado lee la revisión y firma. Registro con hash,
  timestamp, IP/terminal, y tiempo de lectura.
- **Retraining trigger**: al activar una revisión con
  `RequiresReacknowledgment = 1`:
  1. Se identifican todos los empleados con acknowledgment de la revisión anterior
     y todos los que tienen un requisito ligado al documento.
  2. Sus certificaciones asociadas pasan a `RetrainingRequired`.
  3. Se generan inscripciones con fecha límite = `EffectiveAtUtc + N días`.
  4. Se notifica al empleado y a su supervisor.
- Matriz **Documento × Posición**: qué posiciones deben conocer qué documentos.
- Dashboard de Calidad: % de acknowledgment por revisión, por departamento,
  pendientes por vencer.

### Reglas de negocio
- Una revisión activa reemplaza a la anterior; la anterior queda `Superseded` pero
  consultable (evidencia histórica).
- No se puede activar una revisión sin aprobadores registrados.
- El acknowledgment de una revisión superseded no cuenta como vigente.

---

## M10 — Competencias y certificación [COMP]

**Propósito:** el motor de compliance. El módulo más importante del sistema.

### Funcionalidad
- **Competency**: habilidad certificable (ej. "Data Sanitization NIST 800-88",
  "IQC Cosmetic Grading", "Operación Roxer SmartRox"), con niveles
  (`Awareness | Basic | Competent | Advanced | Trainer`).
- **CompetencyRequirement**: Posición (o Departamento, o Empleado específico) →
  Competencia → Nivel mínimo → Vigencia en meses → Ventanas de alerta → Cursos y
  evaluaciones que la satisfacen → Documento controlado ligado → Criticidad.
- **Certification**: el registro emitido. Empleado + Competencia + Nivel +
  Emitida + Vence + Evidencia (qué inscripciones/evaluaciones la sustentan) +
  Firma + Estado.
- **Motor de brechas** (`comp.usp_Gap_Recalculate`): para cada empleado, unión de
  requisitos de todas sus posiciones vs. certificaciones vigentes → lista de
  brechas con severidad. Corre nocturno + on-demand + al cambiar posición.
- **Waiver / excepción**: un requisito puede ser waived temporalmente con
  justificación, aprobador y fecha de expiración del waiver. Todo waiver es
  visible en el reporte de auditoría (esconderlos es peor que tenerlos).
- **Trainer qualification**: quién puede entrenar/evaluar qué.
- Cálculo de estado de certificación:
  - `Valid` — vigente
  - `ExpiringSoon` — dentro de la ventana de alerta
  - `Expired` — pasó `ExpiresAtUtc`
  - `RetrainingRequired` — revisión de documento cambió
  - `Revoked` — retirada por incidente de calidad, con motivo
  - `Provisional` — en entrenamiento, puede operar bajo supervisión directa
- Certificado en PDF con código verificable, QR y firma.

### Reglas de negocio
- Una certificación se emite **solo** cuando toda la evidencia requerida está
  completa (todos los cursos + quizzes + evaluación práctica del requisito).
- La emisión es automática vía SP, no un click de un admin. El admin puede
  revocar, no fabricar.
- Vigencia se cuenta desde la fecha de la **última** pieza de evidencia
  completada, no desde la inscripción.
- Revocar una certificación notifica inmediatamente a Producción (gating).

---

## M11 — Reportería y evidencia de auditoría [COMP]

**Propósito:** que la próxima auditoría R2/ISO se prepare en 20 minutos, no en 3
días.

### Reportes core
| Reporte | Audiencia | Contenido |
|---|---|---|
| **Matriz de competencias** | Calidad, gerencia | Empleados × Competencias, semáforo por estado. Filtrable por depto/posición/línea. Exportable a Excel. |
| **Registro individual de entrenamiento** | Auditor, RH | Todo lo que un empleado ha tomado: curso, fecha, score, instructor, firma, certificado. El "training record" clásico. |
| **Cumplimiento por departamento** | Supervisores | % de requisitos cumplidos, brechas abiertas, vencimientos próximos. |
| **Vencimientos** | Calidad | Qué vence en 30/60/90 días y quién. |
| **Acknowledgment de documentos** | Calidad | % de firma por revisión de WI. |
| **Efectividad del entrenamiento** | Calidad (ISO 7.2c) | Tasa de aprobación, intentos promedio, correlación con defectos/scrap. Evidencia de "evaluar la efectividad de las acciones". |
| **Actividad de instructores** | Gerencia | Sesiones dictadas, participantes, horas. |
| **Waivers y excepciones** | Auditor | Todas las excepciones vigentes e históricas con justificación. |

### Paquete de evidencia de auditoría
`rpt.usp_AuditEvidence_GeneratePackage` con parámetros de alcance
(fechas, sitio, departamento, competencias, lista de empleados) produce un ZIP:

```
AuditEvidence_R2v3_2026-08-15/
├── 00_Resumen_Ejecutivo.pdf
├── 01_Matriz_Competencias.xlsx
├── 02_Registros_Individuales/  (1 PDF por empleado, firmado)
├── 03_Certificados/            (1 PDF por certificación vigente)
├── 04_Rosters_Firmados/        (sign-in sheets de sesiones ILT)
├── 05_Acknowledgments_WI.xlsx
├── 06_Historial_Revisiones_WI.xlsx
├── 07_Waivers_y_Excepciones.pdf
├── 08_Efectividad_Entrenamiento.pdf
└── MANIFEST.json   (hashes SHA-256 de cada archivo + cadena de firmas)
```

### Reglas
- Todo reporte de compliance sale de vistas en el esquema `rpt`, nunca de queries
  contra tablas OLTP.
- Los reportes históricos usan las **temporal tables**: "el estado al 12 de marzo"
  es una query `FOR SYSTEM_TIME AS OF`.

---

## M12 — Notificaciones y recordatorios [CORE]

- Canales: correo (Graph API), **Teams** (Power Automate / webhook — ya tienes el
  patrón montado), y notificación in-app.
- Eventos: inscripción nueva, fecha límite en 7/3/1 días, vencido, certificación
  emitida, certificación por vencer (60/30/7 días), sesión ILT en 24h, sesión
  cancelada, revisión de WI nueva, brecha crítica abierta.
- Digest para supervisores: resumen semanal del estado de su equipo.
- Escalamiento: brecha crítica sin cerrar en N días escala al supervisor del
  supervisor.
- Preferencias por usuario y **plantillas bilingües** por evento.
- Cola de notificaciones (`ops.NotificationQueue`) con retry y dead-letter. Nunca
  enviar sincrónicamente desde el SP.

---

## M13 — Administración y configuración [CORE]

- Gestión de usuarios, roles, permisos y scopes.
- Configuración global y por sitio (`ops.Setting`) con tipado y versionado.
- Feature flags por rol/departamento.
- Plantillas de notificación y de certificado (branding Airlink).
- Catálogos maestros: competencias, posiciones, ubicaciones, categorías, locales.
- Audit log navegable y buscable, exportable.
- Health dashboard: estado de sync con SPN, cola de notificaciones, jobs, errores.
- Import/export masivo con validación previa y dry-run.

---

## M14 — Integraciones [EXT]

| Integración | Dirección | Propósito |
|---|---|---|
| **SPN** | ← lectura | Master de empleados |
| **AIRLINK** | ← lectura | Datos de producción para gating y correlación con calidad |
| **Nexus / Movement** | → API | Gating: consultar elegibilidad antes de asignar estación |
| **Entra ID** | ↔ | SSO, grupos, aprovisionamiento |
| **Microsoft Graph** | → | Correo, calendario (invitaciones a sesiones ILT) |
| **Teams / Power Automate** | → | Notificaciones, aprobaciones |
| **Power BI** | ← | Dashboards ejecutivos sobre el esquema `rpt` |
| **cmi5 / xAPI** | ← | Import de contenido externo (fase 5, opcional) |
| **Zebra ZPL** | → | Impresión de credenciales de certificación con QR |

---

## 2. Roles del sistema

| Rol | Alcance | Puede |
|---|---|---|
| **Learner** | Sí mismo | Ver y tomar sus cursos, firmar documentos, ver sus certificados |
| **Instructor** | Sus sesiones | Dictar ILT, tomar asistencia, calificar, cerrar sesiones |
| **Evaluator** | Su competencia | Ejecutar evaluaciones prácticas donde está calificado |
| **Supervisor** | Su departamento | Ver equipo, asignar cursos, aprobar extensiones, ver brechas |
| **ContentAuthor** | Cursos propios | Crear/editar contenido, enviar a revisión |
| **QualityManager** | Global | Definir competencias y requisitos, documentos controlados, waivers, reportes de auditoría |
| **Administrator** | Global | Todo lo anterior + usuarios, roles, configuración, integraciones |

Los permisos son granulares (`course.create`, `certification.revoke`,
`waiver.approve`, ...) y los roles son colecciones de permisos, editables. Ver
`docs/06-seguridad-y-rbac.md`.

---

## 3. Requerimientos no funcionales

| # | Requerimiento | Objetivo |
|---|---|---|
| NFR-01 | Latencia de lectura (P95) | < 400 ms |
| NFR-02 | Usuarios concurrentes | 150 (pico de cambio de turno) |
| NFR-03 | Disponibilidad en horario productivo | 99.5% |
| NFR-04 | Bilingüe ES-DO / EN-US completo | 100% de UI y contenido de compliance |
| NFR-05 | Retención de registros de entrenamiento | ≥ 3 años activos, 7 años en archivo |
| NFR-06 | Inmutabilidad de evidencia firmada | Hash chain verificable |
| NFR-07 | Accesibilidad | WCAG 2.1 AA en el player y el kiosko |
| NFR-08 | Kiosko táctil | Targets ≥ 48px, legible a 60cm, sin teclado físico |
| NFR-09 | RPO / RTO | RPO 1h (log backup), RTO 4h |
| NFR-10 | Acceso a datos | 100% vía stored procedure, 0 SQL ad-hoc |
| NFR-11 | Auditoría | Toda escritura registrada con actor, timestamp UTC y valores anteriores |
| NFR-12 | Baja conectividad | Curso en progreso operable offline, sync al reconectar |
