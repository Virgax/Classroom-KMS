# 07 — Integración con SPN y AIRLINK

## 1. Principio

`SPN` y `AIRLINK` son **fuentes de verdad ajenas**. Classroom:
- **lee** de ellas, nunca escribe;
- **nunca** asume que su esquema es estable — todo acceso pasa por una vista de
  contrato en `intg`, así un cambio en SPN se arregla en un solo lugar;
- **copia** lo que necesita a `org.Employee` (no hace joins en vivo contra SPN en
  el path de request).

```
SPN.dbo.<tablas de empleados>
        │  SELECT (AlLmsSyncUser)
        ▼
intg.vw_SourceEmployee            ← VISTA DE CONTRATO. Único punto de acoplamiento.
        │  intg.usp_EmployeeSync_LoadStaging
        ▼
intg.EmployeeStaging              ← landing crudo + validación
        │  intg.usp_EmployeeSync_Merge  (MERGE con detección de cambios)
        ▼
org.Employee  ·  org.EmployeePosition  ·  org.EmployeeAssignment
        │
        └──► comp.usp_Gap_RecalculateForEmployee  (si cambió posición/depto/estado)
```

---

## 2. Sincronización de empleados desde SPN

### 2.1 Campos que necesitamos

| Campo en Classroom | Origen esperado en SPN | Uso |
|---|---|---|
| `EmployeeCode` | código de empleado | Clave natural, login de kiosko |
| `FirstName`, `LastName` | nombre / apellido | Certificados, reportes |
| `NationalId` | cédula | Solo si el certificado lo exige (cifrado) |
| `PositionCode` / `PositionName` | puesto | **Motor de requisitos de competencia** |
| `DepartmentCode` / `DepartmentName` | departamento | Scope, reportes |
| `SiteCode` | sitio / planta | Scope |
| `ShiftCode` | turno | Programación de sesiones ILT |
| `SupervisorEmployeeCode` | supervisor | Jerarquía, escalamiento, digest |
| `HireDate` | fecha de ingreso | Inducción automática, antigüedad |
| `TerminationDate` | fecha de salida | Desactivación |
| `Status` | activo / inactivo | Desactivación |
| `Email` | correo corporativo | Notificaciones, mapeo a Entra ID |

**Acción pendiente:** confirmar los nombres reales de tablas y columnas en `SPN`.
El script `database/17_procs_integration.sql` define
`intg.vw_SourceEmployee` con placeholders marcados `-- TODO: mapear a SPN`.
Es el **único** objeto que hay que ajustar cuando se conozca el esquema real.

### 2.2 Cadencia

| Job | Frecuencia | Alcance |
|---|---|---|
| `LMS_EmployeeSync_Incremental` | cada hora, 6am–8pm | Cambios desde el watermark |
| `LMS_EmployeeSync_Full` | diario 2:00am | Reconciliación completa, detecta bajas |
| `LMS_GapRecalculate` | diario 3:00am | Recalcula brechas de toda la planta |
| `LMS_CertificationRefresh` | diario 3:30am | Actualiza estados de vigencia |
| `LMS_EnrollmentExpire` | diario 4:00am | Marca inscripciones vencidas |
| `LMS_NotificationDigest` | diario 7:00am | Digest de supervisores |
| `LMS_Retention` | mensual, día 1 | Archivado y purga |

Definidos en `database/19_jobs_agent.sql`.

### 2.3 Lógica de merge y eventos derivados

`intg.usp_EmployeeSync_Merge` detecta y actúa:

| Cambio detectado | Acción automática |
|---|---|
| **Empleado nuevo** | Crea `org.Employee`, crea `sec.User` con PIN temporal, asigna rol `Learner`, inscribe en el programa de inducción según posición, recalcula brechas |
| **Cambio de posición** | Cierra `EmployeePosition` anterior, abre la nueva, **recalcula brechas** (aparecen requisitos nuevos y otros dejan de aplicar), notifica al supervisor de las brechas críticas |
| **Cambio de departamento/sitio** | Actualiza `EmployeeAssignment`, ajusta scope de reportes |
| **Cambio de supervisor** | Actualiza jerarquía; el nuevo supervisor recibe el estado del empleado |
| **Terminación** | Marca `IsActive = 0`, revoca sesiones, cancela inscripciones abiertas (estado `Withdrawn` con motivo `Terminated`), **conserva toda la evidencia histórica** |
| **Reingreso** | Reactiva el `Employee` existente por `EmployeeCode`; su historia previa sigue ahí y las certificaciones no vencidas siguen válidas |
| **Cambio de nombre** | Actualiza; los certificados ya emitidos conservan el nombre del momento de emisión (evidencia inmutable) |

**Regla dura:** nunca borrar un `Employee`. Los registros de entrenamiento son
evidencia con retención de 7 años.

### 2.4 Manejo de errores

- Filas que no validan van a `intg.IntegrationError` con el motivo, **sin abortar
  el lote completo**.
- Si un `PositionCode` de SPN no existe en `org.Position`, se crea como
  "sin mapear" y se alerta a Calidad: una posición sin requisitos definidos es un
  hueco de compliance, no un error silencioso.
- Si el sync falla 2 veces consecutivas, alerta a Teams (canal de IT).
- `intg.SyncRun` guarda métricas por corrida: filas leídas, insertadas,
  actualizadas, rechazadas, duración.

---

## 3. Lectura de AIRLINK (producción)

### 3.1 Para qué

Tres usos, todos de lectura:

1. **Contexto operacional.** Saber en qué estación/línea está trabajando un
   empleado hoy, para priorizar entrenamiento relevante y detectar si alguien está
   operando sin certificación vigente.
2. **Correlación de efectividad.** Cruzar tasa de defectos / scrap / rework por
   operador contra su estado de entrenamiento. Esto es la evidencia de
   "evaluar la efectividad de las acciones" que pide ISO 9001 cl. 7.2(c), y es el
   argumento más fuerte que puedes llevar a un auditor: no solo entrenamos, medimos
   si el entrenamiento funcionó.
3. **Catálogo de estaciones y procesos.** Alinear `org.Station` con las estaciones
   reales de THOR/Nexus para que el gating hable el mismo lenguaje.

### 3.2 Cómo

- Vista de contrato `intg.vw_SourceProductionContext` (placeholders a mapear).
- Sin joins en vivo en el path de request: un job carga los agregados que
  necesita reportería a `rpt` una vez al día.
- El único SP que lee AIRLINK en línea es
  `intg.usp_ProductionContext_GetForEmployee`, y solo para el dashboard de
  supervisor.

### 3.3 Lo que NO hacemos

- No escribimos nada en `AIRLINK`.
- No dependemos de `AIRLINK` para operar: si está caído, Classroom sigue
  funcionando completo (solo se degrada el dashboard de correlación).

---

## 4. Gating operacional (Classroom → Nexus / Movement)

El caso de uso que convierte el LMS de "sistema de registro" a "control de
proceso".

### 4.1 Contrato de API

```
GET /api/v1/eligibility/check
    ?employeeCode=4471
    &stationCode=RXR-01
    [&competencyCode=IP68-ROXER-OP]

200 OK
{
  "employeeCode": "4471",
  "stationCode": "RXR-01",
  "decision": "Blocked",              // Allowed | AllowedWithSupervision | Blocked
  "evaluatedAtUtc": "2026-07-30T14:12:03.117Z",
  "requirements": [
    {
      "competencyCode": "IP68-ROXER-OP",
      "competencyName": "Operación Roxer SmartRox",
      "requiredLevel": "Competent",
      "currentLevel": "Basic",
      "certificationStatus": "Expired",
      "expiredAtUtc": "2026-06-30T04:00:00.000Z",
      "criticality": "Critical",
      "regulatoryBasis": "R2v3 Core 4 · FA4",
      "remediation": {
        "courseCode": "CRS-RXR-002",
        "enrollmentId": "8f3c...",
        "nextSessionUtc": "2026-08-02T12:00:00.000Z"
      }
    }
  ],
  "activeWaiver": null
}
```

Implementado por `comp.usp_Eligibility_CheckEmployeeForStation`. Objetivo de
latencia: **< 100 ms P95** (es una consulta contra `comp.Certification` con
índice cubridor; se cachea 60 segundos en la API).

### 4.2 Decisiones

| Decisión | Cuándo |
|---|---|
| `Allowed` | Todos los requisitos críticos y mayores de la estación satisfechos con certificación `Valid` |
| `AllowedWithSupervision` | Certificación `Provisional`, o waiver activo que exige supervisión directa |
| `Blocked` | Al menos un requisito crítico sin satisfacer, expirado, revocado o en `RetrainingRequired` |

### 4.3 Rollout — importante

El gating es la feature con más riesgo operativo del sistema. Si se activa en
modo bloqueo antes de que la matriz de competencias esté completa y limpia, **para
la línea de producción** y el proyecto pierde credibilidad de inmediato.

Rollout obligatorio en tres etapas:

1. **Shadow mode (mínimo 4 semanas).** El API responde pero Nexus solo registra
   la respuesta; no bloquea a nadie. Se mide la tasa de `Blocked` y se limpia la
   data hasta que los falsos positivos sean cero.
2. **Warn mode (2–4 semanas).** El supervisor recibe alerta; el operador trabaja.
3. **Enforce mode.** Bloqueo real, y solo para competencias `Critical`, con
   procedimiento de override documentado (waiver de emergencia con aprobación de
   Calidad y registro en audit log).

Nunca activar enforce sin sign-off explícito de Operaciones y Calidad.

---

## 5. Otras integraciones

| Sistema | Dirección | Mecanismo | Fase |
|---|---|---|---|
| **Entra ID** | ↔ | OIDC + Graph (grupos) | 1 |
| **Microsoft Graph** | → | Correo de notificaciones; invitaciones de calendario a sesiones ILT | 2 |
| **Teams** | → | Webhook / Power Automate (ya tienes el patrón del news poster) | 2 |
| **Power BI** | ← | Conexión directa al esquema `rpt` con `AlLmsReportUser` | 4 |
| **Zebra ZPL** | → | Credencial de certificación con QR (reutiliza tu stack de ZPL) | 4 |
| **Nexus / Movement** | ← | Consumen la API de elegibilidad | 5 |
| **cmi5 / xAPI** | ← | Import de contenido de terceros (opcional) | 5 |

### Nota sobre el QR de certificación

El QR del certificado apunta a
`https://classroom.airlink.local/verify/{CertificateNumber}` y resuelve con
`comp.usp_Certification_VerifyByNumber`, que devuelve solo: nombre, competencia,
nivel, fecha de emisión, fecha de vencimiento y estado. **Sin PII adicional**, y
sin requerir login — un auditor con el certificado en mano puede verificarlo en
segundos. Usa un namespace reservado distinto al `ZZ-` que ya usas en THOR para
no colisionar.
