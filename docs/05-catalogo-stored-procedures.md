# 05 — Catálogo de stored procedures

Contrato y convenciones en `CLAUDE.md` §4. Este documento es el índice completo.
**Regla:** si una operación no está aquí, la app no la puede hacer.

Leyenda: **W** = escritura (requiere `@ActorUserId`) · **R** = lectura ·
**J** = ejecutado por job, no por la app.

---

## sec — Identidad y seguridad (`database/11_procs_identity.sql`)

| SP | Tipo | Propósito |
|---|---|---|
| `sec.usp_User_GetByExternalId` | R | Resolver usuario por `oid` de Entra ID (login SSO) |
| `sec.usp_User_GetByEmployeeCode` | R | Resolver usuario por código de empleado (kiosko) |
| `sec.usp_User_AuthenticatePin` | W | Validar PIN, registrar intento, aplicar lockout |
| `sec.usp_User_SetPin` | W | Establecer/cambiar PIN (hash PBKDF2 recibido de la app) |
| `sec.usp_User_Create` | W | Crear usuario de aplicación (ligado o no a empleado) |
| `sec.usp_User_Update` | W | Actualizar perfil, idioma preferido, estado |
| `sec.usp_User_Deactivate` | W | Desactivar (no borra) y revocar sesiones |
| `sec.usp_User_List` | R | Listado paginado con filtros y scope del actor |
| `sec.usp_User_GetPermissions` | R | Permisos efectivos + scopes de un usuario |
| `sec.usp_Role_Create` / `_Update` / `_List` | W/R | Gestión de roles |
| `sec.usp_Role_SetPermissions` | W | Reemplaza el set de permisos de un rol |
| `sec.usp_UserRole_Assign` | W | Asigna rol con `ScopeType` + `ScopeId` |
| `sec.usp_UserRole_Revoke` | W | Revoca asignación (cierra el periodo temporal) |
| `sec.usp_Session_Create` | W | Abre sesión, devuelve id + expiración |
| `sec.usp_Session_Validate` | R | Valida sesión activa, actualiza `LastSeenAtUtc` |
| `sec.usp_Session_Revoke` | W | Cierra sesión (logout, o revocación admin) |
| `sec.usp_Session_RevokeAllForUser` | W | Cierra todas (cambio de rol, incidente) |
| `sec.usp_Device_Register` | W | Registra terminal de kiosko, emite `DeviceToken` |
| `sec.usp_Device_Validate` | R | Valida terminal autorizada |
| `sec.usp_Device_List` / `_Revoke` | R/W | Administración de terminales |

Funciones: `sec.fn_UserHasPermission(@UserId, @PermissionCode)`,
`sec.fn_UserScopeIncludes(@UserId, @ScopeType, @ScopeId)`.

---

## org — Organización y empleados

| SP | Tipo | Propósito |
|---|---|---|
| `org.usp_Employee_Get` | R | Ficha de empleado (respeta scope del actor) |
| `org.usp_Employee_List` | R | Listado paginado: depto, posición, sitio, estado |
| `org.usp_Employee_GetTeam` | R | Reportes directos e indirectos de un supervisor |
| `org.usp_Employee_GetPositions` | R | Posiciones (primaria + secundarias) |
| `org.usp_EmployeePosition_Assign` | W | Asigna posición; **dispara recálculo de brechas** |
| `org.usp_EmployeePosition_End` | W | Cierra vigencia de una posición |
| `org.usp_EmployeeAssignment_Set` | W | Ubica al empleado (sitio/depto/área/estación/turno); **dispara recálculo de brechas** |
| `sec.usp_User_ProvisionForEmployees` | W | Aprovisionamiento masivo de usuarios de piso (login = código de empleado); devuelve pendientes de PIN con su semilla |
| `org.usp_Position_Create` / `_Update` / `_List` | W/R | Catálogo de posiciones |
| `org.usp_Department_List` / `_GetTree` | R | Jerarquía organizacional |
| `org.usp_Site_List`, `org.usp_Area_List`, `org.usp_Station_List` | R | Catálogos |
| `org.usp_Station_Upsert` | W | Estación de trabajo (para gating) |

---

## lms — Catálogo y contenido (`database/12_procs_catalog_content.sql`)

| SP | Tipo | Propósito |
|---|---|---|
| `lms.usp_Course_Create` | W | Crea curso + `CourseVersion` v1 en Draft |
| `lms.usp_Course_Update` | W | Metadata del curso (no del contenido) |
| `lms.usp_Course_Get` | R | Curso + versión vigente + resumen de módulos |
| `lms.usp_Course_List` | R | Catálogo paginado con filtros y búsqueda |
| `lms.usp_Course_Retire` | W | Retira; valida que no haya requisitos ni inscripciones activas |
| `lms.usp_CourseVersion_CreateDraft` | W | Clona la versión publicada a un Draft nuevo |
| `lms.usp_CourseVersion_SubmitForReview` | W | Draft → InReview |
| `lms.usp_CourseVersion_Publish` | W | InReview → Published. Valida `es-DO`, contenido no vacío, quizzes válidos. Retira la versión anterior. Si `RequiresRetraining`, invalida certificaciones |
| `lms.usp_CourseVersion_Get` | R | Estructura completa de una versión (módulos + items) |
| `lms.usp_CourseVersion_GetForLearner` | R | Estructura + progreso del empleado + gating de prerequisitos, en su locale |
| `lms.usp_Module_Add` / `_Update` / `_Delete` / `_Reorder` | W | Módulos |
| `lms.usp_Module_SetRequirements` | W | Requisitos de completación y prerequisitos |
| `lms.usp_ModuleItem_Add` | W | Agrega item; **valida que el target exista según `ItemType`** |
| `lms.usp_ModuleItem_Update` / `_Delete` / `_Reorder` | W | Items |
| `lms.usp_Page_Upsert` | W | Contenido rich text (HTML ya sanitizado por la app) |
| `lms.usp_Page_Get` | R | Página en un locale, con fallback |
| `lms.usp_Translation_Upsert` | W | Traducción de cualquier entidad/locale |
| `lms.usp_Translation_GetStatus` | R | Cobertura de traducción de una versión |
| `lms.usp_Program_Create` / `_Update` / `_SetCourses` / `_Get` / `_List` | W/R | Learning paths |
| `lms.usp_Blueprint_Link` | W | Liga curso derivado a maestro |
| `lms.usp_Blueprint_PushUpdates` | W | Propaga cambios del maestro a los derivados |
| `lms.usp_Category_Upsert` / `_GetTree` | W/R | Categorías |

---

## dlv — Inscripción, progreso, ILT (`database/13_procs_delivery_progress.sql`)

### Inscripción
| SP | Tipo | Propósito |
|---|---|---|
| `dlv.usp_Enrollment_Create` | W | Inscribe 1 empleado. Valida duplicado activo, prerequisitos de programa, curso publicado |
| `dlv.usp_Enrollment_CreateBulk` | W | Masiva vía TVP `dlv.EmployeeCourseList`. Devuelve éxitos y rechazos con motivo |
| `dlv.usp_Enrollment_CreateFromRequirement` | J | Genera inscripciones desde brechas de competencia |
| `dlv.usp_Enrollment_Withdraw` | W | Retira; bloquea si el origen es `CompetencyRequired` y el actor no es dueño del requisito |
| `dlv.usp_Enrollment_Get` | R | Detalle + progreso + evidencia |
| `dlv.usp_Enrollment_ListForEmployee` | R | Dashboard del learner (pendientes, por vencer, vencidos, completos) |
| `dlv.usp_Enrollment_ListForCourse` | R | Roster de un curso/cohorte |
| `dlv.usp_Enrollment_ListForSupervisor` | R | Equipo del supervisor con semáforo |
| `dlv.usp_Enrollment_ExtendDueDate` | W | Prórroga con justificación y aprobador; queda en audit |
| `dlv.usp_Enrollment_Reassign` | W | Cambia cohorte/instructor |
| `dlv.usp_Enrollment_Complete` | W | Marca completo. Valida toda la evidencia. **Dispara evaluación de certificación** |
| `dlv.usp_Enrollment_Fail` | W | Marca fallido, incrementa intento, notifica supervisor si agotó intentos |
| `dlv.usp_Enrollment_ExpireOverdue` | J | Job nocturno: marca `Expired` los vencidos |

### Progreso
| SP | Tipo | Propósito |
|---|---|---|
| `dlv.usp_Progress_StartItem` | W | Registra primer acceso a un item; valida prerequisitos |
| `dlv.usp_Progress_UpsertItem` | W | Actualiza estado, tiempo acumulado, posición de video |
| `dlv.usp_Progress_CompleteItem` | W | Marca item completo. Valida tiempo mínimo (anti-skip) y recalcula módulo/curso |
| `dlv.usp_Progress_Heartbeat` | W | Latido de 30s; acumula tiempo real de sesión |
| `dlv.usp_Progress_GetForEnrollment` | R | Progreso completo de una inscripción |
| `dlv.usp_Progress_Recalculate` | J | Reconstruye `ModuleProgress` y % de curso (reparación) |

### Cohortes y sesiones presenciales
| SP | Tipo | Propósito |
|---|---|---|
| `dlv.usp_Cohort_Create` / `_Update` / `_List` | W/R | Cohortes (turno + instructor) |
| `dlv.usp_Session_Create` | W | Sesión ILT. Valida conflicto de instructor y de sala |
| `dlv.usp_Session_CreateRecurring` | W | Serie recurrente |
| `dlv.usp_Session_Update` / `_Cancel` | W | Cancelar notifica a todos los inscritos |
| `dlv.usp_Session_Get` / `_List` / `_ListForInstructor` | R | Consulta |
| `dlv.usp_Session_GetRoster` | R | Roster con estado de cada participante |
| `dlv.usp_SessionRegistration_Add` | W | Inscribe o encola en lista de espera según capacidad |
| `dlv.usp_SessionRegistration_Cancel` | W | Cancela y **promueve al primero de la lista de espera** |
| `dlv.usp_Attendance_CheckIn` | W | Check-in por badge/código/manual, con timestamp |
| `dlv.usp_Attendance_SetStatus` | W | `Present/Late/LeftEarly/Absent/Excused` + minutos |
| `dlv.usp_Attendance_SignRoster` | W | Firma del instructor (cierra el roster) |
| `dlv.usp_Attendance_SignParticipant` | W | Firma del participante |
| `dlv.usp_Session_Close` | W | Cierra sesión. Requiere roster firmado. Marca resultados y dispara certificación |
| `dlv.usp_Session_GetConflicts` | R | Choques de instructor/sala/impacto en línea |

---

## asmt — Evaluación (`database/14_procs_assessment.sql`)

### Bancos y preguntas
| SP | Tipo | Propósito |
|---|---|---|
| `asmt.usp_Bank_Create` / `_Update` / `_List` / `_Get` | W/R | Bancos de preguntas |
| `asmt.usp_Question_Create` | W | Pregunta + opciones en una transacción |
| `asmt.usp_Question_Update` / `_Delete` | W | Delete es soft; si tiene intentos, solo se desactiva |
| `asmt.usp_Question_List` | R | Por banco, tipo, competencia, dificultad |
| `asmt.usp_Question_ImportBulk` | W | Import vía TVP con validación previa |
| `asmt.usp_Question_GetStatistics` | R | % de acierto, discriminación, distractores más elegidos |

### Quizzes
| SP | Tipo | Propósito |
|---|---|---|
| `asmt.usp_Quiz_Create` / `_Update` / `_Get` / `_List` | W/R | Quizzes |
| `asmt.usp_Quiz_SetSections` | W | Secciones y fuentes (N preguntas del banco X) |
| `asmt.usp_Quiz_Validate` | R | Verifica que sea publicable (suficientes preguntas, puntos > 0) |
| `asmt.usp_Quiz_Duplicate` | W | Clona |

### Intentos
| SP | Tipo | Propósito |
|---|---|---|
| `asmt.usp_Attempt_Start` | W | **Selecciona y congela** las preguntas y opciones del intento (snapshot). Valida intentos disponibles |
| `asmt.usp_Attempt_GetCurrent` | R | Intento en curso con preguntas snapshot, sin revelar respuestas correctas |
| `asmt.usp_Attempt_SaveAnswer` | W | Guarda respuesta parcial (autosave) |
| `asmt.usp_Attempt_Submit` | W | Cierra, auto-califica objetivas, calcula score, decide aprobado/no. Encola subjetivas |
| `asmt.usp_Attempt_AbandonExpired` | J | Cierra intentos que excedieron el límite de tiempo |
| `asmt.usp_Attempt_Get` | R | Intento completo (para review y auditoría) |
| `asmt.usp_Attempt_ListForEnrollment` | R | Historia de intentos |
| `asmt.usp_Attempt_GradeManual` | W | Calificación manual de essay/upload con rúbrica |
| `asmt.usp_Attempt_GetPendingManualGrading` | R | Cola de calificación del instructor |

### Rúbricas y evaluación práctica
| SP | Tipo | Propósito |
|---|---|---|
| `asmt.usp_Rubric_Create` / `_SetCriteria` / `_Get` / `_List` | W/R | Rúbricas |
| `asmt.usp_RubricAssessment_Submit` | W | Califica con rúbrica |
| `asmt.usp_PracticalTemplate_Create` / `_SetCriteria` / `_Get` | W/R | Plantillas de evaluación práctica |
| `asmt.usp_Practical_Start` | W | Inicia evaluación. **Valida que el evaluador esté calificado y no sea el evaluado** |
| `asmt.usp_Practical_SetCriterionResult` | W | Resultado por criterio observable |
| `asmt.usp_Practical_AddAttachment` | W | Foto/evidencia |
| `asmt.usp_Practical_Submit` | W | Cierra. Un criterio crítico fallido reprueba todo. Requiere firma dual |
| `asmt.usp_Practical_Get` / `_ListForEmployee` / `_ListForEvaluator` | R | Consulta |

---

## comp — Compliance y certificación (`database/15_procs_compliance.sql`)

### Competencias y requisitos
| SP | Tipo | Propósito |
|---|---|---|
| `comp.usp_Competency_Create` / `_Update` / `_Get` / `_List` | W/R | Catálogo de competencias |
| `comp.usp_Competency_SetLevels` | W | Niveles de una competencia |
| `comp.usp_Requirement_Create` | W | Requisito de competencia con scope, vigencia, criticidad, base regulatoria |
| `comp.usp_Requirement_Update` | W | Actualiza (temporal table guarda la historia) |
| `comp.usp_Requirement_SetSatisfiers` | W | Qué cursos/programas/evaluaciones lo satisfacen |
| `comp.usp_Requirement_SetDocuments` | W | Documentos controlados ligados |
| `comp.usp_Station_SetRequirements` | W | Requisitos que exige una estación (`IsBlocking` = lo que evalúa el gating) |
| `comp.usp_Requirement_Deactivate` | W | Desactiva; certificaciones existentes se mantienen |
| `comp.usp_Requirement_Get` / `_List` | R | Consulta |
| `comp.usp_Requirement_GetForEmployee` | R | Requisitos efectivos (unión de todas sus posiciones + scopes) |
| `comp.usp_Requirement_GetAsOf` | R | Requisitos vigentes a una fecha (`FOR SYSTEM_TIME AS OF`) |

### Motor de brechas y certificación
| SP | Tipo | Propósito |
|---|---|---|
| `comp.usp_Gap_RecalculateForEmployee` | W | Recalcula brechas de un empleado |
| `comp.usp_Gap_RecalculateAll` | J | Job nocturno para toda la planta |
| `comp.usp_Gap_List` | R | Brechas por depto/severidad/empleado |
| `comp.usp_Gap_GetSummary` | R | Conteos por severidad para dashboards |
| `comp.usp_Certification_EvaluateAndIssue` | W | **El SP más importante.** Evalúa si la evidencia completa satisface un requisito y, si sí, emite la certificación con vigencia y firma |
| `comp.usp_Certification_Get` / `_ListForEmployee` | R | Consulta |
| `comp.usp_Certification_Revoke` | W | Revoca con motivo. Notifica producción (gating) |
| `comp.usp_Certification_Reinstate` | W | Reinstala tras corrección, con justificación |
| `comp.usp_Certification_RefreshStatuses` | J | Job nocturno: `Valid → ExpiringSoon → Expired` |
| `comp.usp_Certification_GetExpiring` | R | Vencimientos en N días |
| `comp.usp_Certification_GetCertificateData` | R | Data para renderizar el PDF del certificado |
| `comp.usp_Certification_VerifyByNumber` | R | Verificación pública por número/QR |

### Elegibilidad (gating)
| SP | Tipo | Propósito |
|---|---|---|
| `comp.usp_Eligibility_CheckEmployeeForStation` | R | **API de gating.** ¿Puede el empleado X operar la estación Y hoy? Devuelve decisión + requisitos faltantes |
| `comp.usp_Eligibility_CheckEmployeeForCompetency` | R | Chequeo puntual de competencia + nivel |
| `comp.usp_Eligibility_GetQualifiedEmployees` | R | Quién puede operar la estación Y (para planificación de turnos) |

### Waivers y evaluadores
| SP | Tipo | Propósito |
|---|---|---|
| `comp.usp_Waiver_Request` / `_Approve` / `_Reject` / `_Revoke` | W | Ciclo de vida de excepciones |
| `comp.usp_Waiver_List` | R | Todos los waivers (para auditoría) |
| `comp.usp_EvaluatorQualification_Grant` / `_Revoke` / `_List` | W/R | Quién evalúa qué |

### Documentos controlados
| SP | Tipo | Propósito |
|---|---|---|
| `comp.usp_Document_Create` / `_Update` / `_Get` / `_List` | W/R | Documentos (WI/SOP/Policy/SDS) |
| `comp.usp_DocumentRevision_Create` | W | Nueva revisión en Draft |
| `comp.usp_DocumentRevision_AddApproval` | W | Registra aprobador |
| `comp.usp_DocumentRevision_Activate` | W | Activa revisión. **Supersede la anterior y, si `RequiresReacknowledgment`, invalida certificaciones y genera inscripciones de re-entrenamiento** |
| `comp.usp_DocumentRevision_Get` / `_ListHistory` | R | Consulta e historia |
| `comp.usp_Acknowledgment_Record` | W | Registra firma de lectura con hash, tiempo de lectura y terminal |
| `comp.usp_Acknowledgment_GetStatus` | R | % de firma por revisión / departamento |
| `comp.usp_Acknowledgment_GetPendingForEmployee` | R | Documentos pendientes de firmar |
| `comp.usp_Document_GetPositionMatrix` | R | Matriz Documento × Posición |

---

## rpt — Reportería y auditoría (`database/16_procs_reporting.sql`)

| SP | Tipo | Propósito |
|---|---|---|
| `rpt.usp_CompetencyMatrix_Get` | R | Matriz Empleados × Competencias con semáforo |
| `rpt.usp_TrainingRecord_GetForEmployee` | R | Expediente completo de entrenamiento (el "training record") |
| `rpt.usp_ComplianceByDepartment_Get` | R | % de cumplimiento, brechas, vencimientos por depto |
| `rpt.usp_ExpiringCertifications_Get` | R | Vencimientos 30/60/90 |
| `rpt.usp_DocumentAcknowledgment_Get` | R | Estado de firma por revisión |
| `rpt.usp_TrainingEffectiveness_Get` | R | Tasa de aprobación, intentos promedio, tiempo — evidencia ISO 7.2(c) |
| `rpt.usp_InstructorActivity_Get` | R | Sesiones, participantes, horas por instructor |
| `rpt.usp_WaiverRegister_Get` | R | Registro de excepciones vigentes e históricas |
| `rpt.usp_AuditEvidence_GetScope` | R | Resuelve el alcance del paquete de auditoría |
| `rpt.usp_AuditEvidence_GeneratePackage` | W | Genera el paquete de evidencia (registra la generación en audit) |
| `rpt.usp_Dashboard_GetExecutive` | R | KPIs para gerencia |
| `rpt.usp_Dashboard_GetSupervisor` | R | KPIs del equipo |
| `rpt.usp_Dashboard_GetLearner` | R | Vista del empleado |
| `rpt.usp_AsOfDate_GetComplianceSnapshot` | R | Estado de compliance a una fecha histórica (temporal tables) |

---

## intg — Integraciones (`database/17_procs_integration.sql`)

| SP | Tipo | Propósito |
|---|---|---|
| `intg.usp_EmployeeSync_LoadStaging` | J | Lee `SPN.dbo.*` a `intg.EmployeeStaging` |
| `intg.usp_EmployeeSync_Merge` | J | MERGE staging → `org.Employee`. Detecta altas, cambios de posición/depto y bajas |
| `intg.usp_EmployeeSync_Run` | J | Orquesta: watermark → staging → merge → recálculo de brechas → log |
| `intg.usp_EmployeeSync_GetLastRun` | R | Estado del último sync (health dashboard) |
| `intg.usp_Watermark_Get` / `_Set` | R/W | Marcas de agua de sync |
| `intg.usp_ExternalId_Map` / `_Resolve` | W/R | Mapeo de IDs externos |
| `intg.usp_IntegrationError_Log` / `_List` / `_Retry` | W/R | Errores de integración y reproceso |
| `intg.usp_ProductionContext_GetForEmployee` | R | Lee `AIRLINK` (read-only): estación/línea actual del empleado, para correlación |

---

## aud / ops — Plataforma (`database/18_procs_platform.sql`)

| SP | Tipo | Propósito |
|---|---|---|
| `aud.usp_Event_Log` | W | Registra evento de auditoría (llamado por otros SPs) |
| `aud.usp_Error_Log` | W | Registra error de SP |
| `aud.usp_Event_List` | R | Audit log navegable |
| `aud.usp_Signature_Create` | W | Crea firma con hash + encadena al hash anterior del empleado |
| `aud.usp_Signature_Verify` | R | Verifica integridad de una firma y de la cadena |
| `aud.usp_DataAccess_Log` | W | Registra lectura de PII |
| `aud.usp_Idempotency_Register` / `_Check` | W/R | Idempotencia de escrituras |
| `ops.usp_Setting_Get` / `_Set` / `_List` | R/W | Configuración |
| `ops.usp_FeatureFlag_IsEnabled` / `_List` / `_Set` | R/W | Feature flags |
| `ops.usp_Notification_Enqueue` | W | Encola notificación (llamado por otros SPs) |
| `ops.usp_Notification_Dequeue` | J | El worker toma un lote con `UPDLOCK, READPAST` |
| `ops.usp_Notification_MarkSent` / `_MarkFailed` | J | Resultado del envío, con retry |
| `ops.usp_Notification_GetDeadLetter` | R | Fallidas definitivas |
| `ops.usp_NotificationTemplate_Upsert` / `_Get` | W/R | Plantillas bilingües |
| `ops.usp_FileAsset_Register` / `_Get` / `_Delete` | W/R | Metadata de archivos |
| `ops.usp_JobRun_Start` / `_Finish` | J | Instrumentación de jobs |
| `ops.usp_Health_GetStatus` | R | Health dashboard |
| `ops.usp_Retention_Apply` | J | Archivado y purga mensual |

---

## Resumen

| Área | SPs |
|---|---|
| sec | 22 |
| org | 12 |
| lms | 27 |
| dlv | 35 |
| asmt | 27 |
| comp | 39 |
| rpt | 14 |
| intg | 11 |
| aud / ops | 22 |
| **Total** | **~209** |

Fase 1–2 cubre `sec`, `org`, `lms`, `dlv` (inscripción y progreso) y `asmt`
(quizzes): ~110 SPs. Fase 3–4 agrega `comp` y `rpt`.
