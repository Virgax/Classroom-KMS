# 08 — Roadmap

Supuesto de capacidad: tú + Jorge + Wilson, con Claude Code acelerando el
scaffolding y los SPs repetitivos. Estimaciones en semanas de calendario
asumiendo que Classroom **no** es el 100% del tiempo del equipo (THOR, OmniCore y
FAI siguen corriendo).

---

## Fase 0 — Diseño y fundaciones · 1 semana

**Entregables**
- [x] Análisis de Canvas y gap analysis
- [x] Modelo de datos y catálogo de SPs
- [x] ADRs de arquitectura
- [ ] Confirmar esquema real de `SPN` (tablas y columnas de empleados)
- [ ] Crear `AIRLINK_LMS_DEV` + principals + permisos
- [ ] Repo en GitHub + `CLAUDE.md` + CI (build + análisis estático)
- [ ] Sign-off de alcance con Victor y Calidad

**Criterio de salida:** DB de DEV creada con esquemas y principals, repo con CI
verde, y una decisión escrita de qué NO se va a construir.

**Riesgo a cerrar aquí:** si el esquema de SPN no se puede leer con un principal
dedicado, el proyecto se traba en la semana 3. Resolverlo ahora.

---

## Fase 1 — Core: identidad, catálogo, contenido · 4 semanas

**DB:** `sec`, `org`, `lms` (~55 tablas, ~60 SPs)
**API:** auth Entra ID, RBAC con scopes, CRUD de cursos, autoría de contenido
**Web:** shell admin, login, catálogo, editor de curso/módulos/items

**Entregables**
- Sync de empleados desde SPN funcionando (incremental + full)
- Login SSO con Entra ID + login por PIN (kiosko)
- RBAC completo con scopes por departamento
- CRUD de cursos con versionado y workflow Draft → InReview → Published
- Editor de módulos e items (page, file, video, link)
- Biblioteca de archivos
- i18n de UI y de contenido (es-DO / en-US)
- Audit log operativo

**Criterio de aceptación:** Calidad puede crear un curso bilingüe con 3 módulos y
publicarlo, sin ayuda de IT.

---

## Fase 2 — Delivery: inscripción, progreso, evaluación · 5 semanas

**DB:** `dlv`, `asmt` (~25 tablas, ~60 SPs)
**API:** inscripción, progreso, player, quizzes, ILT
**Web:** shell learner, player de curso, motor de quiz, kiosko de piso

**Entregables**
- Inscripción individual, masiva y auto-inscripción
- Cohortes por turno
- Player con progreso granular y continuación
- Anti-skip de video y tiempo mínimo
- Bancos de preguntas con 10 tipos, randomización, snapshot de intento
- Auto-calificación + cola de calificación manual
- Sesiones ILT con roster, check-in, asistencia y firma
- **Modo kiosko** operativo en tablet de piso
- Notificaciones por correo y Teams
- Modo offline básico (curso en progreso)

**Criterio de aceptación:** un operador se loguea en la tablet de la línea con su
código, toma un curso de 20 min con quiz, aprueba, y su supervisor ve el resultado
sin refrescar nada a mano. **Piloto real con un departamento.**

**Hito de negocio:** aquí ya hay valor entregado. Si el proyecto se cancela en
este punto, tienes un LMS funcional.

---

## Fase 3 — Compliance: competencias y certificación · 5 semanas

**DB:** `comp` (~14 tablas, ~40 SPs)
**API:** requisitos, brechas, certificación, documentos controlados
**Web:** matriz de competencias, gestión de requisitos, firma de documentos

**Entregables**
- Catálogo de competencias con niveles
- Requisitos por posición/depto/área/estación, con vigencia y criticidad
- Motor de brechas (nocturno + on-demand + al cambiar posición)
- Emisión automática de certificación con vigencia y firma
- Estados de vigencia y notificaciones de vencimiento 60/30/7
- Documentos controlados con revisiones y aprobadores
- **Trigger de re-entrenamiento por revisión de WI** (GAP-02)
- Evaluación práctica / OJT con firma dual y validación de evaluador
- Waivers con workflow de aprobación
- Certificado en PDF con QR verificable
- Temporal tables activas en las tablas críticas

**Criterio de aceptación:** se publica `WI-IP68-RXR-001 Rev.2` y el sistema, solo,
invalida las certificaciones de Rev.1, genera las inscripciones de
re-entrenamiento con fecha límite, y notifica a los 14 operadores afectados y a su
supervisor. Sin intervención manual.

**Este es el hito que justifica el proyecto.**

---

## Fase 4 — Reportería y evidencia de auditoría · 3 semanas

**DB:** `rpt` (vistas + ~14 SPs)
**API:** reportes, exportación, generación de paquete
**Web:** dashboards (ejecutivo, supervisor, learner), reportes con filtros

**Entregables**
- Matriz de competencias con semáforo, filtrable y exportable
- Expediente individual de entrenamiento en PDF firmado
- Cumplimiento por departamento
- Reporte de efectividad del entrenamiento (ISO 7.2c)
- Registro de waivers
- Reporte histórico "estado al día X" con temporal tables
- **Paquete de evidencia de auditoría** en ZIP con MANIFEST hasheado
- Conexión de Power BI al esquema `rpt`
- Credencial física con ZPL + QR

**Criterio de aceptación:** generar el paquete completo de evidencia para un
alcance R2v3/ISO en **menos de 20 minutos**, y que Calidad lo valide como
suficiente para presentar a un auditor.

---

## Fase 5 — Integración operacional y extras · 4 semanas

**Entregables**
- API de elegibilidad con caché
- **Shadow mode** de gating con Nexus/Movement (mínimo 4 semanas de medición)
- Correlación entrenamiento ↔ calidad desde `AIRLINK`
- Blueprint courses con push de actualizaciones
- Programas / learning paths completos
- Import cmi5 (si aparece la necesidad real)
- App móvil PWA instalable
- Estadísticas de preguntas (discriminación, distractores)

**Criterio de aceptación:** shadow mode corriendo con tasa de falsos positivos
medida y documentada, y decisión formal de Operaciones sobre pasar a warn mode.

---

## Resumen de calendario

| Fase | Semanas | Acumulado | Hito |
|---|---|---|---|
| 0 | 1 | 1 | Fundaciones listas |
| 1 | 4 | 5 | Calidad crea cursos sola |
| 2 | 5 | 10 | **Piloto en piso — valor entregado** |
| 3 | 5 | 15 | **Re-entrenamiento automático por WI** |
| 4 | 3 | 18 | **Auditoría en 20 minutos** |
| 5 | 4 | 22 | Gating en shadow mode |

~22 semanas (5.5 meses) a producción completa, con valor utilizable en la semana
10.

---

## Riesgos y mitigaciones

| # | Riesgo | Impacto | Mitigación |
|---|---|---|---|
| R1 | **Scope creep hacia features de Canvas** | Alto | `CLAUDE.md` §8 es un contrato. Cualquier feature fuera del roadmap requiere sacar otra. |
| R2 | El esquema de SPN no es lo que esperamos | Alto | Cerrarlo en fase 0. La vista de contrato aísla el impacto. |
| R3 | Data de competencias sucia o inexistente | **Muy alto** | La matriz de competencias es un proyecto de Calidad, no de IT. Empezar a levantarla **en paralelo desde la fase 1**, no en la fase 3. Si no hay matriz, no hay LMS de compliance. |
| R4 | Gating para la línea de producción | Muy alto | Shadow mode obligatorio de 4 semanas. Nunca enforce sin sign-off de Operaciones. |
| R5 | Adopción del piso (operadores no lo usan) | Alto | Kiosko en el flujo de trabajo, no un portal aparte. Piloto con un departamento voluntario. Supervisores como dueños, no IT. |
| R6 | Competencia con THOR/OmniCore/FAI por tiempo del equipo | Alto | Fases cortas con valor entregable. Fase 2 es el punto de "cancelable sin pérdida total". |
| R7 | Deuda de contenido: nadie crea los cursos | Alto | Empezar convirtiendo las WIs existentes a items de `DocumentAcknowledgment` — contenido instantáneo con valor de compliance inmediato, sin producir un solo video. |
| R8 | Bus factor de una persona | Medio | `CLAUDE.md` + docs + catálogo de SPs son el knowledge transfer. Jorge y Wilson deben tocar DB y API desde la fase 1. |
| R9 | Performance de la matriz de competencias con 400 empleados × 60 competencias | Medio | `comp.CompetencyGap` materializada, no calculada en vivo. Refresco nocturno + on-demand puntual. |

---

## Quick win para la semana 1 (antes de escribir código de app)

Si quieres mostrar valor en 5 días con solo la DB y un reporte:

1. Aplicar `00`–`08` + `15_procs_compliance.sql` en DEV.
2. Cargar a mano (o con Excel) el catálogo de competencias y requisitos de **un**
   departamento con Calidad.
3. Sync de empleados desde SPN.
4. Correr `comp.usp_Gap_RecalculateAll`.
5. Conectar Excel/Power BI a `rpt.vw_CompetencyMatrix`.

Resultado: la matriz de competencias real de ese departamento, con brechas
identificadas, sin una sola línea de frontend. Eso es exactamente lo que Calidad
va a pedir en la próxima auditoría, y es el mejor argumento para que el proyecto
tenga sponsorship.
