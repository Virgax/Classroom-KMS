# 03 — Arquitectura

## 1. Vista general

```
┌──────────────────────────────────────────────────────────────────────────┐
│  CLIENTES                                                                │
│  ┌────────────────┐ ┌────────────────┐ ┌────────────────┐               │
│  │ classroom-web  │ │ Kiosko de piso │ │ Power BI       │               │
│  │ React 19 + TS  │ │ (misma SPA,    │ │ (solo esquema  │               │
│  │ Vite+Tailwind  │ │  modo kiosk)   │ │  rpt, read)    │               │
│  └───────┬────────┘ └───────┬────────┘ └───────┬────────┘               │
└──────────┼──────────────────┼──────────────────┼─────────────────────────┘
           │  HTTPS / JSON    │                  │
┌──────────▼──────────────────▼──────────────────┼─────────────────────────┐
│  Classroom.Api  (.NET 9 Minimal API, IIS/Kestrel on-prem)               │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ Auth: Entra ID OIDC (staff)  ·  JWT propio (kiosko código+PIN)     │ │
│  │ Autorización: policies por permiso + scope organizacional          │ │
│  │ Validación: FluentValidation  ·  Idempotency-Key  ·  Rate limiting │ │
│  │ Observabilidad: Serilog → archivo + tabla ops.AppLog               │ │
│  └────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────────┐
│  Classroom.Infrastructure  (Dapper)                                     │
│  UN método por stored procedure. CommandType.StoredProcedure. Nada más. │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │  EXECUTE only
┌──────────────────────────────▼──────────────────────────────────────────┐
│  SQL Server 2019+   ·   192.168.181.248,13999                           │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │ DB: AIRLINK_LMS   (NUEVA — no tocamos AIRLINK)                   │   │
│  │  lms · asmt · comp · sec · aud · intg · rpt · ops                │   │
│  │  Toda la lógica: SPs, vistas, funciones, temporal tables         │   │
│  └───────────────┬──────────────────────────────────────────────────┘   │
│                  │ SQL Agent jobs (sync) — read-only                     │
│  ┌───────────────▼───────────┐  ┌───────────────────────────────────┐   │
│  │ DB: SPN                   │  │ DB: AIRLINK                       │   │
│  │ master de empleados       │  │ producción / calidad              │   │
│  │ (AlAppUser, read-only)    │  │ (AlAppUser, read-only)            │   │
│  └───────────────────────────┘  └───────────────────────────────────┘   │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────────┐
│  SERVICIOS EXTERNOS                                                     │
│  Entra ID · Microsoft Graph (mail/calendar) · Teams webhook             │
│  Azure Blob o file share (archivos y video) · Zebra (ZPL)               │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Decisiones de arquitectura (ADRs)

### ADR-001 — Base de datos propia `AIRLINK_LMS`, no tablas dentro de `AIRLINK`

**Contexto:** el requerimiento inicial planteaba la data del LMS en la DB
`AIRLINK`.

**Decisión:** crear una base de datos nueva `AIRLINK_LMS` en la misma instancia.
`AIRLINK` y `SPN` se consumen **solo en lectura**.

**Razones:**
1. **Blast radius.** `AIRLINK` es la DB productiva de THOR, IQC, BoxShipping y
   los reportes de Assurant. Un lock, un índice mal puesto o un SP con un
   `WHILE` mal escrito del LMS no puede tocar producción.
2. **Superficie de permisos.** El LMS necesita escritura. Si sus tablas viven en
   `AIRLINK`, el app user existe **dentro** de `AIRLINK` — aunque solo tenga
   EXECUTE sobre SPs del LMS, cualquier error de configuración lo pone a un
   `GRANT` de distancia de la data de producción. Separando DB, el principal del
   LMS simplemente no existe en `AIRLINK` con permisos de escritura.
3. **Retención y backup distintos.** Los registros de entrenamiento tienen
   retención de 7 años por compliance; la data operativa de THOR tiene otro
   ciclo. Backups, restores y purgas independientes.
4. **Auditoría.** Un auditor de R2/ISO puede recibir acceso de lectura a
   `AIRLINK_LMS` sin ver nada de producción ni data de clientes (AT&T/Assurant).
5. **Restore selectivo.** Si hay que restaurar el LMS a un punto en el tiempo,
   no arrastras producción.

**Consecuencia:** las lecturas cross-database van con nombre completo
(`SPN.dbo.Employee`) desde SPs de `AIRLINK_LMS`, con `TRUSTWORTHY OFF` y
permisos explícitos al principal de sync. Sin linked servers si están en la misma
instancia.

---

### ADR-002 — `AlAppUser` NO se usa para el LMS

**Contexto:** las credenciales provistas (`AlAppUser`) son de solo lectura.

**Decisión:** tres principals distintos, principio de menor privilegio:

| Principal | Alcance | Permiso |
|---|---|---|
| `AlLmsAppUser` | `AIRLINK_LMS` | `EXECUTE` sobre esquemas `lms, asmt, comp, sec, rpt, ops`. **Cero** `SELECT` sobre tablas. |
| `AlLmsSyncUser` | `AIRLINK_LMS` + `SPN` + `AIRLINK` | `EXECUTE` sobre `intg`; `SELECT` sobre las vistas específicas de SPN/AIRLINK. Nada más. |
| `AlLmsReportUser` | `AIRLINK_LMS` | `SELECT` sobre el esquema `rpt` únicamente (para Power BI). |

`AlAppUser` queda intacto para lo que ya hace. No lo tocamos.

**Nota de seguridad — acción requerida:** la contraseña de `AlAppUser` fue
compartida en un canal de chat en texto claro. Eso es un evento de exposición de
credencial. Recomendación:
1. Rotar la contraseña de `AlAppUser`.
2. Crear los principals nuevos con contraseñas generadas (≥ 24 caracteres) que
   nunca pasen por chat, correo ni el repo.
3. Guardarlas en Azure Key Vault o, si es 100% on-prem, en el Windows Credential
   Manager de la cuenta de servicio + `appsettings` con
   `Microsoft.Extensions.Configuration.UserSecrets` en DEV.
4. Idealmente: autenticación integrada de Windows con una cuenta de servicio
   gestionada (gMSA) y cero contraseñas en configuración.

Nunca voy a poner esa contraseña en un archivo del repo. El `.env.example` lleva
placeholders.

---

### ADR-003 — Stored procedures exclusivamente, y por qué eso elimina el ORM

**Decisión:** Dapper con `CommandType.StoredProcedure`. Sin EF Core como ORM.

**Razones:**
- El requerimiento de "nada de queries abiertos" es incompatible con cualquier
  ORM que traduzca LINQ/queries a SQL. EF Core, Prisma y TypeORM generan SQL
  dinámico por diseño.
- Con SPs exclusivos, el plan de ejecución es estable y cacheado, el permiso es
  `EXECUTE` granular por operación, y el DBA tiene control total de índices y
  planes.
- Beneficio de seguridad real: SQL injection deja de ser un vector, porque no
  hay superficie donde inyectar. La app literalmente no puede emitir un SELECT.
- Beneficio de auditoría: cada operación de negocio es un objeto nombrado y
  versionado en la DB. Un auditor puede leer el catálogo de SPs y entender qué
  puede hacer el sistema.

**Costo honesto que aceptamos:**
- Más código boilerplate. ~2 SPs por entidad mínimo, y no hay scaffolding.
- Refactors de esquema son más caros (hay que tocar los SPs).
- Testing requiere una DB real; no hay in-memory provider.
- Lógica de negocio parcialmente en T-SQL, que es menos expresivo y más difícil
  de testear unitariamente que C#.

**Mitigación:** los SPs contienen validación e integridad transaccional; la
lógica de negocio compleja (cálculo de elegibilidad, generación de PDFs,
orquestación) vive en C#, llamando SPs atómicos. La regla: *el SP garantiza
consistencia, el C# orquesta*.

---

### ADR-004 — .NET 9 en el backend (no Node)

**Decisión:** .NET 9 Minimal API + Dapper.

| Criterio | .NET 9 + Dapper | NestJS + node-mssql |
|---|---|---|
| Fit con SQL Server on-prem | Nativo, mejor tooling | Bueno |
| Fit con SPs | Dapper es el mejor cliente de SPs que existe | Aceptable |
| Entra ID / Windows auth | Nativo (`Microsoft.Identity.Web`) | Requiere más plumbing |
| Skills del equipo Airlink | C# ya en uso (Nexus, herramientas internas) | Node ya en uso (dashboards) |
| Tipos compartidos con el front | No | Sí (ventaja de Node) |
| Deployment on-prem Windows | IIS, trivial | Requiere PM2/servicio |
| Generación de PDF de certificados | QuestPDF, excelente | Playwright (ya lo usas en THOR) |

Gana .NET por el fit con SQL Server, Entra ID y el deployment on-prem Windows,
que es donde vive la infraestructura de Airlink. La ventaja de tipos compartidos
de Node se recupera generando el cliente TypeScript desde el OpenAPI del backend
(NSwag), que da el mismo beneficio sin cambiar de runtime.

---

### ADR-005 — React 19 + TypeScript + Vite + Tailwind en el front

Una sola SPA con tres "shells" según el rol y el dispositivo:
- **Shell administrativo** (denso, tablas, filtros) — Calidad, RH, admin.
- **Shell learner** (limpio, foco en el contenido) — empleados con cuenta.
- **Shell kiosko** (táctil, targets grandes, alto contraste, sesión corta) — piso.

Un solo codebase, tres layouts. Tailwind con design tokens de la paleta de marca
Airlink (la misma que ya usas en los reportes IQC).

---

### ADR-006 — Temporal tables de SQL Server para historia de compliance

En vez de tablas `*_History` mantenidas a mano o triggers, las tablas críticas de
compliance usan `SYSTEM_VERSIONING = ON`.

**Por qué:** cuando un auditor pregunta *"¿cuál era el requisito de competencia
vigente para el puesto de Data Sanitization el 12 de marzo de 2026, y quién
estaba certificado ese día?"*, la respuesta es una query:

```sql
SELECT * FROM comp.CompetencyRequirement
FOR SYSTEM_TIME AS OF '2026-03-12T16:00:00'
WHERE PositionId = @PositionId;
```

Sin temporal tables eso es un proyecto de arqueología de logs. Con ellas es una
línea. Es la feature más subvalorada de SQL Server para compliance.

**Costo:** crecimiento de storage en las tablas de historia. Mitigado con
retención configurada (`HISTORY_RETENTION_PERIOD 7 YEARS`) y compresión de página.

---

### ADR-007 — Sin motor SCORM en fases 1–4

**Contexto:** SCORM 1.2 sigue siendo el estándar más soportado y funciona bien
para contenido de compliance auditable. cmi5 es el perfil de xAPI que agrega
semántica de launch/completion tipo SCORM y es la ruta recomendada para contenido
nuevo. xAPI solo tiene sentido con un LRS y una estrategia de datos definida de
antemano; sin ella, el LRS se llena de eventos granulares que no responden
preguntas de compliance.

**Decisión:** contenido nativo (pages, video, quizzes, acknowledgments,
evaluaciones prácticas) en fases 1–4. Import **cmi5** opcional en fase 5, solo si
aparece la necesidad real de consumir contenido de terceros (típicamente cursos de
EHS comprados, o contenido que Assurant/AT&T provea).

**Por qué:** implementar un runtime de SCORM es 4–6 semanas de trabajo que no
resuelve ninguno de los 10 gaps del documento 01. El contenido de Airlink lo
produce Airlink.

---

### ADR-008 — Notificaciones asíncronas por cola, nunca desde el SP

Los SPs escriben a `ops.NotificationQueue`. Un worker (Hangfire in-process o un
SQL Agent job que llama a un endpoint) drena la cola y envía por Graph API o
webhook de Teams, con retry exponencial y dead-letter.

**Por qué:** un SP que hace `sp_send_dbmail` o llama a `sp_OACreate` bloquea la
transacción, acopla la DB a la red, y hace que un fallo de correo revierta una
certificación legítima. Inaceptable.

---

## 3. Estructura del repositorio

```
classroom-lms/
├── CLAUDE.md                        ← reglas para Claude Code. Leer primero.
├── README.md
├── .gitignore
├── .env.example
├── docs/                            ← 8 documentos de diseño
├── database/
│   ├── 00_setup_database_roles.sql  ← DB, principals, roles, permisos
│   ├── 01_schemas.sql
│   ├── 02_tables_core.sql           ← sec, organización, empleados, posiciones
│   ├── 03_tables_catalog.sql        ← cursos, versiones, programas
│   ├── 04_tables_content.sql        ← módulos, items, páginas, archivos, i18n
│   ├── 05_tables_assessment.sql     ← bancos, preguntas, quizzes, intentos, rúbricas
│   ├── 06_tables_delivery.sql       ← inscripciones, progreso, cohortes, ILT
│   ├── 07_tables_compliance.sql     ← competencias, requisitos, certificaciones, docs
│   ├── 08_tables_platform.sql       ← audit, notificaciones, settings, integración
│   ├── 09_functions.sql              ← funciones escalares y TVF (las vistas dependen de ellas)
│   ├── 10_views_reporting.sql        ← vistas del esquema rpt
│   ├── 11_procs_identity.sql
│   ├── 12_procs_catalog_content.sql
│   ├── 13_procs_delivery_progress.sql
│   ├── 14_procs_assessment.sql
│   ├── 15_procs_compliance.sql
│   ├── 16_procs_reporting.sql
│   ├── 17_procs_integration.sql
│   ├── 18_procs_platform.sql
│   ├── 19_jobs_agent.sql
│   ├── 99_seed_reference_data.sql
│   └── migrations/                  ← cambios destructivos post-PROD
├── scripts/
│   ├── deploy-db.ps1
│   └── verify-db.ps1
└── src/
    ├── Classroom.Api/               ← endpoints, auth, DTOs, validadores
    ├── Classroom.Domain/            ← modelos, enums, lógica pura, sin dependencias
    ├── Classroom.Infrastructure/    ← repositorios Dapper (1 por área), 1 método = 1 SP
    └── classroom-web/               ← React 19 + Vite + TS + Tailwind
```

---

## 4. Entornos

| Entorno | DB | Propósito |
|---|---|---|
| DEV | `AIRLINK_LMS_DEV` | Desarrollo. Data sintética. |
| QA | `AIRLINK_LMS_QA` | UAT con Calidad y RH. Subset anonimizado de SPN. |
| PROD | `AIRLINK_LMS` | Producción. |

Los scripts de `database/` son idempotentes y se aplican en orden numérico en los
tres entornos. `99_seed_reference_data.sql` es distinto por entorno (flag
`@Environment`).

---

## 5. Seguridad de la superficie de red

- La API solo escucha en la red interna de Airlink. Sin exposición a internet en
  fase 1.
- HTTPS con certificado interno; HSTS.
- Kiosko: la terminal se autentica con un `DeviceToken` emitido por el admin, más
  el código+PIN del operador. Sin `DeviceToken` válido, el endpoint de kiosko
  rechaza.
- Rate limiting agresivo en el endpoint de login por PIN (5 intentos / 15 min por
  código de empleado) con bloqueo temporal y alerta.
- Los archivos de curso no se sirven por ruta directa: endpoint autorizado que
  valida inscripción y devuelve un stream con URL firmada de corta duración.
- Sin PII en URLs ni en query strings. Los IDs expuestos son GUIDs.
