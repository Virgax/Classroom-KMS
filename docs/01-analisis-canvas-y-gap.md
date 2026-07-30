# 01 — Análisis de Canvas y Gap Analysis para Airlink

## 1. Qué es Canvas realmente

Canvas es el LMS de Instructure, licencia AGPLv3 en su versión open source. Es
el LMS #1 de Norteamérica: 30M+ de learners, 100+ países, 33 idiomas, con picos
soportados de 6 millones de usuarios concurrentes. Está construido en Ruby on
Rails + PostgreSQL, expone una REST API con 190+ grupos de recursos, una API
GraphQL en `/api/graphql`, LTI 1.3 / LTI Advantage, un Platform Notification
Service para webhooks server-to-server, y el Data Access Platform (Canvas Data 2)
para export a data warehouse.

**Contexto que importa para nuestra decisión:** en abril–mayo 2026 Canvas sufrió
una brecha de datos (grupo ShinyHunters) que expuso nombres, correos, IDs de
estudiante y mensajes entre usuarios. No es un argumento contra Canvas como
software, pero sí refuerza el caso de que data de empleados de Airlink viva
on-premise bajo nuestro control, no en un SaaS multi-tenant.

Canvas también está migrando a un modelo de tiers (anunciado abril 2026), donde
capacidades como AI assistance y analytics avanzado quedan detrás de niveles
superiores. Costo variable y creciente para features que nosotros necesitamos.

---

## 2. Teardown del modelo de dominio de Canvas

Canvas organiza todo en una jerarquía. Este es el mapa de sus entidades
principales (los nombres son los de su esquema real):

### Identidad y acceso
`accounts` → `roles` → `users` → `enrollments`
Cuenta raíz, sub-cuentas anidadas, roles con permisos granulares, y el
`enrollment` como la entidad que une un usuario a un curso **con un rol**
(student, teacher, TA, designer, observer). El enrollment es el corazón del
modelo: no existe "usuario del curso", existe "inscripción con rol".

### Estructura curricular
`terms` → `courses` → `sections`
Periodo académico, curso, y secciones (grupos de la misma materia con distinto
horario/instructor). Un curso puede tener varias secciones y un estudiante
pertenece a una sección.

### Entrega de contenido
`modules` → `module_items` → (`pages` | `files` | `assignments` | `quizzes` | `external_tools`)
El `module` es un contenedor secuencial con **requisitos de completación** y
**prerequisitos** (no puedes ver el módulo 3 sin completar el 2). Los
`module_items` son punteros polimórficos a cualquier tipo de contenido. Este
patrón es excelente y lo vamos a copiar tal cual.

### Evaluación
`assignment_groups` → `assignments` → `submissions` → `submission_attachments`
`quizzes` → `quiz_questions` → `quiz_submissions` → `quiz_submission_answers`
`rubrics` → `rubric_criteria` → `rubric_assessments`
`outcomes` → `outcome_results`

Los assignments soportan múltiples tipos de entrega: upload de archivo, texto
directo, URL, y grabación de audio/video. Los quizzes (New Quizzes) manejan
bancos de preguntas con randomización y auto-calificación de objetivas. Las
rúbricas se pueden atar a learning outcomes, lo que alimenta el "Learning
Mastery Gradebook".

### Calificación
`grades` + gradebook con ponderación por `assignment_group`, esquemas de
calificación configurables (puntos, porcentaje, letra), y SpeedGrader para
calificar con anotación sobre el documento entregado.

### Colaboración
`discussions` → `discussion_entries`, `announcements`, `groups` →
`group_memberships`, `calendar_events`, y mensajería con
`conversations` → `conversation_participants` → `conversation_messages`.

### Administración
`blueprint_courses` (curso maestro que empuja cambios a cursos derivados con un
click), feature flags a nivel de cuenta y curso, `sis_imports`,
`authentication_providers`, `audit_logs`.

---

## 3. Qué copiamos de Canvas

| Patrón de Canvas | Por qué lo adoptamos |
|---|---|
| **Enrollment como entidad de primera clase** (usuario + curso + rol + estado) | Modelo correcto. Permite historia: un empleado se inscribió, se retiró, se re-inscribió. |
| **Module → ModuleItem polimórfico** | Permite mezclar video, PDF, quiz y firma de WI en una secuencia sin explotar el esquema. |
| **Requisitos de completación y prerequisitos por módulo** | Crítico para nosotros: no puedes tomar el examen de IQC sin haber leído la WI. |
| **Bancos de preguntas + randomización** | Evita que los operadores se pasen las respuestas entre turnos. Fundamental. |
| **Rúbricas con criterios y niveles** | Es exactamente cómo se evalúa un skill práctico (OJT sign-off). |
| **Outcomes / mastery separados de la nota** | Un operador puede "pasar" un curso pero no dominar un outcome. La matriz de competencias vive aquí. |
| **Blueprint courses** | Un curso maestro de "Seguridad Industrial" desplegado a 6 departamentos, con updates centralizados. Nos ahorra muchísimo. |
| **Feature flags por cuenta/curso** | Rollout gradual sin ramas de código. |
| **Sección separada del curso** | Nosotros lo mapeamos a *cohorte/turno*: mismo curso, distinto turno e instructor. |
| **Data platform separado del OLTP** | Vistas y esquema `rpt` dedicado a reportería, para no matar la DB transaccional. |
| **Todo con API primero** | La API es el producto; la web es un cliente. Habilita el kiosk de piso y móvil. |

## 4. Qué descartamos de Canvas

| Feature de Canvas | Por qué NO |
|---|---|
| Discussions con hilos anidados | El piso no discute en un foro. La comunicación real es Teams + supervisor. Costo alto, uso cero. |
| Groups / peer review | No hay trabajo colaborativo evaluado en entrenamiento de manufactura. |
| Portal de padres/observadores | No aplica. |
| ePortfolios | No aplica. |
| Terms académicos | Reemplazado por *periodos de compliance* (año fiscal / ciclo de recertificación). |
| Gradebook con ponderación compleja + esquemas de letra | Nosotros necesitamos binario **competente / no competente** con score mínimo. La nota de letra es ruido. |
| Marketplace LTI de 1000+ herramientas | Sobre-ingeniería. LTI 1.3 puntual si algún día integramos algo, no antes. |
| Motor SCORM completo | Ver ADR-007. Contenido nativo cubre 95% del caso. |
| Multi-tenancy con sub-cuentas anidadas arbitrarias | Airlink es un solo tenant. Jerarquía fija: Organización → Sitio → Departamento → Área/Línea. |
| Modelo "curso = contenedor de todo" | Nosotros separamos **Course** (contenido) de **CompetencyRequirement** (obligación). Un curso no obliga a nadie; un requisito sí. Esta es la diferencia arquitectónica más importante. |

---

## 5. El gap: lo que Canvas no hace y Airlink necesita

Esto es el corazón del proyecto. Canvas es un LMS académico; Airlink es una
planta de refurbishment certificada ISO 9001 + R2v3. Los siguientes 10 requisitos
no existen en Canvas (ni en la mayoría de LMS comerciales) y son la razón para
construir en casa.

### GAP-01 — Matriz de competencias por posición
ISO 9001 cl. 7.2 exige determinar la competencia necesaria de las personas que
hacen trabajo que afecta la calidad, asegurar que sean competentes, tomar
acciones para adquirir la competencia y **retener información documentada como
evidencia**. La forma canónica de documentarlo es una matriz de habilidades /
training matrix: Posición × Competencia × Nivel requerido.

Canvas no tiene concepto de "posición" ni de "competencia requerida por
posición". Un curso en Canvas no sabe a quién obliga.

**Implementación:** `comp.Position`, `comp.Competency`, `comp.CompetencyRequirement`
(posición → competencia → nivel mínimo → vigencia en meses), y motor que evalúa
`Empleado × Requisito` y genera brechas automáticamente.

### GAP-02 — Vínculo a Work Instructions con revisión controlada
Airlink maneja WIs versionadas (ej. `WI-IP68-RXR-001 Rev.1`). Cuando una WI pasa
a Rev.2, **todo el personal certificado en Rev.1 queda no-conforme** hasta que
lea y firme la nueva revisión. Hoy eso se rastrea a mano y es exactamente el tipo
de hallazgo que un auditor encuentra.

**Implementación:** `lms.ControlledDocument` + `lms.ControlledDocumentRevision`,
y el SP `comp.usp_Requirement_InvalidateByDocumentRevision` que al publicar una
revisión nueva marca las certificaciones afectadas como `RetrainingRequired` y
genera las inscripciones automáticamente. Esto solo vale la pena si el LMS lo
hace solo.

### GAP-03 — Certificación con vencimiento y recertificación
Un LMS académico registra "completó el curso" una vez, para siempre. Compliance
requiere: entrenamiento vigente, entrenamiento vencido, entrenamiento por vencer
(ventana de alerta), entrenamiento sin confirmar.

**Implementación:** `comp.Certification` con `IssuedAtUtc`, `ExpiresAtUtc`,
`Status`, y estado derivado `Valid | ExpiringSoon | Expired | Revoked |
RetrainingRequired`. Job nocturno que recalcula y notifica a 60/30/7 días.

### GAP-04 — Entrenamiento presencial (ILT) como ciudadano de primera clase
Realidad de piso: ~70% del entrenamiento en Airlink es presencial en la estación,
no e-learning. R2v3 exige requisitos de competencia técnica para los
trabajadores, y en FA4 (reuse/repair) registros de prueba de funcionalidad por
dispositivo o lote. El entrenamiento que soporta eso es hands-on.

Canvas trata lo presencial como un afterthought (un `calendar_event` sin roster
formal ni firma).

**Implementación:** módulo completo `lms.TrainingSession` con instructor,
capacidad, lista de espera, roster de asistencia con check-in, y firma del
instructor y del participante.

### GAP-05 — OJT sign-off con evaluación práctica
La evidencia de competencia no es un score de quiz: es un supervisor certificando
que vio al operador ejecutar la tarea correctamente N veces. La cláusula 7.2 pide
explícitamente registros de entrenamiento en el puesto (on-the-job training).

**Implementación:** `asmt.PracticalAssessment` con checklist de criterios
observables, evaluador, intentos, y firma dual (evaluador + evaluado).

### GAP-06 — E-signature con integridad verificable
Un auditor debe poder confirmar que la firma del operador no se alteró después.

**Implementación:** `aud.SignatureRecord` con hash SHA-256 sobre el payload
canónico (usuario + documento + revisión + timestamp UTC + método), más
`PreviousSignatureHash` formando una cadena por empleado. Cualquier modificación
rompe la cadena y es detectable.

### GAP-07 — Paquete de evidencia de auditoría exportable
La causa #1 de no-conformidades en auditorías es brechas de documentación. El
auditor pide: "muéstrame los registros de competencia de estos 12 operadores de
la línea de data sanitization" y hoy eso son 3 días de trabajo manual.

**Implementación:** `rpt.usp_AuditEvidence_GeneratePackage` que produce, para un
rango de fechas / departamento / requisito: matriz de competencias, registros
individuales de entrenamiento, certificados con firma, historia de revisiones de
WI, y el log de excepciones/waivers. Salida a PDF+ZIP. Esto solo justifica el
proyecto.

### GAP-08 — Gating operacional (integración con producción)
El LMS debe poder responder en tiempo real: *"¿puede el empleado 4471 operar la
estación de Roxer SmartRox hoy?"*. Y Nexus/Movement deben poder consultarlo antes
de asignar la tarea.

**Implementación:** `comp.usp_Eligibility_CheckEmployeeForStation` +
`comp.vw_EmployeeStationEligibility`, consumible por API. Canvas no tiene nada
remotamente parecido.

### GAP-09 — Autenticación de piso sin correo corporativo
Muchos operadores no tienen cuenta M365. No pueden loguearse con Entra ID.

**Implementación:** modo kiosk con login por **código de empleado + PIN**, en
estación compartida con auto-logout, y sesión atada a la terminal. Auth dual:
Entra ID SSO para staff, credencial local para piso.

### GAP-10 — Bilingüe ES-DO / EN-US en el mismo curso
Canvas soporta 33 idiomas en su UI, pero el **contenido** de un curso es
monolingüe: para dos idiomas creas dos cursos, y entonces tienes dos registros de
compliance para la misma competencia. Inaceptable.

**Implementación:** contenido versionado por locale bajo un mismo
`CourseVersion`; el registro de compliance es del curso, no del idioma.

---

## 6. Veredicto: construir vs. adoptar

Para ser justo con la alternativa, estos son los argumentos reales **a favor** de
usar Canvas (o Moodle) en lugar de construir:

- Canvas open source es AGPLv3, gratis de licencia, y se autohospeda.
- Elimina 6–9 meses de desarrollo del core LMS (quizzes, gradebook, módulos).
- Trae accesibilidad, i18n, apps móviles y 99.9% de uptime probado.
- Comunidad grande, seguridad revisada por miles de instituciones.
- El equipo de Software de Airlink son 3 personas incluyéndote. Construir un LMS
  compite con THOR, OmniCore y FAI.

Y estos son los contra-argumentos, que en este caso pesan más:

- Los 10 gaps de arriba requieren desarrollo custom **de todos modos**. Hacerlos
  como plugins de Rails sobre un codebase de 1M+ líneas que nadie en el equipo
  domina es más costoso que construirlos nativos, no menos.
- AGPLv3 implica obligaciones de licencia sobre modificaciones que hay que
  evaluar legalmente.
- El equipo ya opera SQL Server, .NET, Power Automate y Entra ID. Canvas
  significa introducir Ruby, Rails y PostgreSQL a un equipo de 4 personas —
  deuda operacional permanente.
- Los datos de compliance tienen que vivir junto a los datos de producción para
  el gating de GAP-08. Con Canvas eso es un pipeline de sincronización más.
- El 60% de las features de Canvas es peso muerto para nosotros (sección 4).

**Recomendación:** construir. Pero con dos condiciones honestas:
1. Alcance disciplinado. La sección 8 de `CLAUDE.md` es un contrato, no una
   sugerencia. Cada feature "tipo Canvas" que se agregue sin estar en el roadmap
   es un mes que se retrasa el compliance, que es el único ROI real del proyecto.
2. Fase 1 útil en 8 semanas. Si a los 3 meses no hay nada en producción, la
   decisión correcta era Canvas + plugins.

---

## 7. Referencias de estándares de contenido

Para no re-litigar esto después: SCORM 1.2 sigue siendo lo más soportado y
funciona bien para contenido de compliance auditable; SCORM 2004 4ª edición sigue
siendo el más desplegado aunque congelado desde 2009; xAPI captura eventos ricos
cross-sistema pero requiere un LRS y una estrategia de datos previa — sin ella se
produce "data flooding" donde el LRS se llena de datos granulares que no
responden preguntas de compliance; cmi5 es el perfil de xAPI que agrega semántica
de launch/completion tipo SCORM y es la ruta recomendada para contenido nuevo en
2026, endorsada por el DoD como sucesor de SCORM.

Para Airlink, donde lo que importa es un registro de completación auditable con
matriz de competencias integrada, SCORM 1.2 o cmi5 dan el 80–90% del valor con
una fracción del overhead de infraestructura. Decisión: **contenido nativo en
fases 1–4, cmi5 como import opcional en fase 5**. Ver ADR-007.
