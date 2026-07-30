# 06 — Seguridad, RBAC y manejo de credenciales

## 1. Manejo de credenciales — acción requerida

La contraseña de `AlAppUser` se compartió en texto claro por chat. Eso constituye
una exposición de credencial y hay que tratarla como tal:

1. **Rotar** la contraseña de `AlAppUser` en la instancia
   `192.168.181.248,13999`.
2. **No reutilizarla** para el LMS. Los principals del LMS son nuevos y sus
   contraseñas se generan aleatoriamente (≥ 24 caracteres) y nunca circulan por
   chat, correo, Teams ni el repositorio.
3. **Almacenamiento:**
   - Producción: Azure Key Vault, o Windows Credential Manager bajo la cuenta de
     servicio de la app.
   - Mejor aún: cuenta de servicio gestionada de dominio (**gMSA**) con
     autenticación integrada de Windows → cero contraseñas en configuración.
   - Desarrollo: `dotnet user-secrets`, nunca `appsettings.json`.
4. **Rotación programada** cada 180 días, con el procedimiento documentado.
5. `.gitignore` ya bloquea `.env`, `appsettings.*.json` (excepto el base) y
   `*.pfx`.

En este repositorio **no existe ningún archivo con la contraseña real**. El
`.env.example` tiene placeholders.

---

## 2. Principals de SQL Server

### 2.1 Definición

| Login | DB | Rol de DB | Permisos |
|---|---|---|---|
| `AlLmsAppUser` | `AIRLINK_LMS` | `db_lms_app` | `EXECUTE` sobre `sec, org, lms, dlv, asmt, comp, rpt, ops`. **Cero `SELECT`** |
| `AlLmsSyncUser` | `AIRLINK_LMS`, `SPN`, `AIRLINK` | `db_lms_sync` | `EXECUTE` sobre `intg` en LMS; `SELECT` sobre vistas específicas en SPN/AIRLINK |
| `AlLmsReportUser` | `AIRLINK_LMS` | `db_lms_report` | `SELECT` sobre `rpt` únicamente |
| `AlAppUser` | `SPN`, `AIRLINK` | (existente) | Sin cambios. **No se usa en el LMS** |

### 2.2 Por qué `AlAppUser` no sirve

`AlAppUser` es read-only. El LMS escribe constantemente: progreso, intentos de
quiz, firmas, certificaciones, asistencia. Con un principal read-only el 60% del
sistema es imposible. Además el principio de menor privilegio dice que el user que
lee producción no debe ser el mismo que escribe compliance.

### 2.3 La propiedad clave del diseño

`AlLmsAppUser` **no tiene `SELECT` sobre ninguna tabla**. Solo `EXECUTE`. Esto
significa que:

- La regla de "todo por stored procedure" no es una convención de código que se
  puede olvidar en un PR: es una restricción de la base de datos. Si alguien
  escribe un query ad-hoc, falla en runtime con "permission denied". El sistema se
  autoenforza.
- SQL injection deja de ser un vector. No existe superficie donde inyectar porque
  la app no puede emitir SQL arbitrario.
- Un atacante que capture las credenciales de la app solo puede ejecutar las
  ~209 operaciones de negocio definidas, con toda su validación y auditoría. No
  puede hacer `SELECT * FROM comp.Certification` ni un `DROP`.

Esto funciona por la **cadena de propiedad** (*ownership chaining*): los SPs y las
tablas tienen el mismo dueño (`dbo`), así que el SP accede a las tablas sin que el
caller tenga permiso directo.

---

## 3. RBAC de aplicación

### 3.1 Modelo

```
Permission  (código granular)
    ↑
RolePermission
    ↑
Role  ←── UserRoleAssignment (con ScopeType + ScopeId) ──→ User
```

Un usuario tiene N asignaciones de rol, cada una con un **scope**:

| ScopeType | Significado |
|---|---|
| `Global` | Toda la organización |
| `Site` | Un sitio |
| `Department` | Un departamento y sus áreas |
| `Area` | Un área/línea |
| `Self` | Solo sus propios datos |

Un supervisor de SMT con rol `Supervisor` scope `Department=SMT` ve el equipo de
SMT y nada más. Los SPs de listado aplican el filtro de scope
**dentro del SP** vía `sec.fn_UserScopeIncludes`, no en la aplicación. Nunca se
confía en que el front filtre.

### 3.2 Catálogo de permisos

| Dominio | Permisos |
|---|---|
| Cursos | `course.view`, `course.create`, `course.edit`, `course.publish`, `course.retire` |
| Contenido | `content.edit`, `content.translate`, `content.approve` |
| Inscripción | `enrollment.view.self`, `enrollment.view.team`, `enrollment.view.all`, `enrollment.create`, `enrollment.bulk`, `enrollment.withdraw`, `enrollment.extend` |
| Progreso | `progress.view.self`, `progress.view.team`, `progress.view.all` |
| Evaluación | `quiz.take`, `quiz.author`, `quiz.grade`, `attempt.view.all`, `question.manage` |
| Práctica | `practical.evaluate`, `practical.template.manage` |
| ILT | `session.create`, `session.instruct`, `session.attendance`, `session.close`, `session.cancel` |
| Competencias | `competency.manage`, `requirement.manage`, `requirement.view` |
| Certificación | `certification.view.self`, `certification.view.team`, `certification.view.all`, `certification.revoke`, `certification.reinstate` |
| Waivers | `waiver.request`, `waiver.approve` |
| Documentos | `document.view`, `document.manage`, `document.revision.activate`, `document.acknowledge` |
| Reportes | `report.view.team`, `report.view.all`, `report.audit.generate`, `report.export` |
| Admin | `user.manage`, `role.manage`, `setting.manage`, `device.manage`, `integration.manage`, `audit.view` |

### 3.3 Matriz Rol × Permiso (base)

| Permiso (agrupado) | Learner | Instructor | Evaluator | Supervisor | ContentAuthor | QualityMgr | Admin |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Ver y tomar cursos propios | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Firmar documentos | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ver equipo | — | — | — | ✅ | — | ✅ | ✅ |
| Dictar ILT / asistencia | — | ✅ | — | — | — | ✅ | ✅ |
| Calificar | — | ✅ | — | — | — | ✅ | ✅ |
| Evaluación práctica | — | — | ✅ | — | — | ✅ | ✅ |
| Asignar cursos | — | — | — | ✅ | — | ✅ | ✅ |
| Prorrogar fecha límite | — | — | — | ✅ | — | ✅ | ✅ |
| Crear/editar contenido | — | — | — | — | ✅ | ✅ | ✅ |
| Publicar curso | — | — | — | — | — | ✅ | ✅ |
| Definir competencias/requisitos | — | — | — | — | — | ✅ | ✅ |
| Revocar certificación | — | — | — | — | — | ✅ | ✅ |
| Aprobar waiver | — | — | — | — | — | ✅ | ✅ |
| Activar revisión de documento | — | — | — | — | — | ✅ | ✅ |
| Generar evidencia de auditoría | — | — | — | — | — | ✅ | ✅ |
| Usuarios, roles, configuración | — | — | — | — | — | — | ✅ |

Los roles son **datos**, no código. Se pueden crear roles nuevos y ajustar
permisos desde administración sin desplegar.

### 3.4 Separación de funciones (SoD)

Controles duros, validados en SP, no en UI:

- Nadie se evalúa a sí mismo (`asmt.usp_Practical_Start`).
- El evaluador debe tener `EvaluatorQualification` vigente en esa competencia a
  nivel igual o superior.
- Quien solicita un waiver no puede aprobarlo.
- El autor de un curso no puede ser el único aprobador de su publicación.
- Un supervisor no puede revocar ni fabricar una certificación de su propio
  equipo: solo `QualityManager`.
- La emisión de certificación es **siempre** automática desde
  `comp.usp_Certification_EvaluateAndIssue`. No existe un SP "crear certificación
  a mano". Un admin puede revocar, nunca inventar.

---

## 4. Autenticación

### 4.1 Staff — Entra ID (OIDC)

- Authorization Code + PKCE. Airlink ya opera Entra ID / M365.
- El `oid` del token mapea a `sec.User.ExternalObjectId`.
- Los grupos de Entra pueden mapear a roles de Classroom
  (`sec.RoleGroupMapping`), para no gestionar dos veces.
- MFA lo impone Entra, no el LMS.
- Sin contraseñas del LMS para staff. Cero superficie de gestión de passwords.

### 4.2 Piso — código de empleado + PIN

Para los operadores sin cuenta M365:

- PIN de 6 dígitos, hasheado con **PBKDF2-HMAC-SHA256**, ≥ 210.000 iteraciones,
  salt de 16 bytes por usuario. El hash y el salt los calcula la **API**, no el
  SP: T-SQL no debe hacer criptografía de contraseñas.
- El SP `sec.usp_User_AuthenticatePin` recibe el hash calculado y compara; nunca
  recibe el PIN en claro.
- Lockout: 5 intentos fallidos → bloqueo de 15 minutos + evento de auditoría +
  alerta si son 3 códigos distintos desde la misma terminal (posible fuerza bruta).
- El PIN se cambia obligatoriamente en el primer login y cada 365 días.
- La sesión de kiosko dura 15 minutos con auto-logout a los 90 segundos de
  inactividad.

### 4.3 Terminales de kiosko

Cada terminal se registra (`sec.usp_Device_Register`) y recibe un `DeviceToken`
de larga duración, guardado en el almacenamiento seguro del dispositivo. Los
endpoints de kiosko exigen `DeviceToken` **más** sesión de usuario. Un token se
puede revocar remotamente si se pierde una tablet.

---

## 5. Firma electrónica e integridad

`aud.SignatureRecord` implementa una cadena de hashes por empleado:

```
Payload canónico (JSON con claves ordenadas, sin espacios):
{
  "u": <UserId>,
  "e": <EmployeeId>,
  "t": "<SignatureType>",
  "r": "<EntityType>:<EntityId>",
  "d": "<datos específicos, ej. WI-IP68-RXR-001|Rev.1>",
  "ts": "<ISO-8601 UTC con milisegundos>",
  "m": "<Pin|EntraId|Biometric>",
  "ip": "<origen>",
  "dev": "<DeviceId o null>"
}

Hash        = SHA256( PayloadCanonico + "|" + PreviousHash )
PreviousHash = hash de la firma anterior del mismo empleado ("GENESIS" si es la primera)
```

**Propiedades:**
- Alterar cualquier firma rompe el hash de esa firma y de todas las posteriores
  del mismo empleado. Detectable con `aud.usp_Signature_Verify`.
- No es criptografía de clave pública (no hay repudio criptográfico fuerte), pero
  sí **detección de manipulación**, que es lo que ISO 9001 y R2v3 requieren para
  evidencia de competencia. Si en el futuro hace falta no-repudio real, se agrega
  firma con certificado del usuario sin cambiar el esquema.
- Todo lo firmable: acknowledgment de documento, asistencia a sesión, roster de
  instructor, evaluación práctica (evaluado + evaluador), emisión de certificación.

El paquete de evidencia de auditoría incluye `MANIFEST.json` con el hash SHA-256
de cada archivo generado, para que el auditor pueda verificar que el paquete no se
alteró después de generarse.

---

## 6. Privacidad y PII

- Los expedientes de entrenamiento son **PII de empleados**. Toda lectura de un
  expediente ajeno se registra en `aud.DataAccessLog`: quién vio el de quién y
  cuándo.
- Cédula/documento de identidad: se sincroniza de SPN solo si es indispensable
  para el certificado; si se guarda, va enmascarada en la UI (últimos 4) y
  cifrada en reposo con **Always Encrypted** (determinístico para poder buscar).
- Sin PII en URLs, query strings ni logs. Los IDs expuestos son GUIDs.
- Los correos de notificación no llevan resultados de evaluación en el cuerpo;
  llevan un enlace al sistema.
- Reportes exportados a Excel llevan marca de agua con usuario y timestamp de
  generación.

---

## 7. Seguridad de datos en reposo y en tránsito

| Control | Implementación |
|---|---|
| TDE (cifrado de DB) | Habilitado en `AIRLINK_LMS` |
| Always Encrypted | Columnas de identificación personal |
| TLS | 1.2+ obligatorio; `Encrypt=True` en la connection string |
| Backups | Cifrados, con contraseña gestionada en Key Vault |
| Archivos de curso | Sin ruta pública; endpoint autorizado con URL firmada de 5 min |
| Logs | Sin PII, sin tokens, sin connection strings |

---

## 8. Auditoría del propio sistema

Todo SP de escritura llama `aud.usp_Event_Log` con: actor, entidad, acción,
timestamp UTC, y JSON de valores antes/después para los cambios sensibles. Los
eventos que **siempre** se registran con detalle completo:

- Emisión, revocación y reinstalación de certificación
- Aprobación de waiver
- Activación de revisión de documento controlado
- Cambio de requisito de competencia
- Asignación y revocación de rol
- Prórroga de fecha límite
- Calificación manual y corrección de score
- Generación de paquete de evidencia de auditoría
- Login fallido, lockout, y registro/revocación de terminal

El audit log es append-only para la aplicación: `AlLmsAppUser` puede ejecutar
`aud.usp_Event_Log` (INSERT) pero no existe ningún SP que actualice o borre
`aud.EventLog`. La purga por retención la ejecuta un job con un principal
distinto.
