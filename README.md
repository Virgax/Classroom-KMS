# Classroom — LMS by Airlink

Learning Management System interno de Airlink Distribution DR. Diseñado para
entrenamiento de piso de producción, certificación de operadores y evidencia
documentada de competencia para auditorías **ISO 9001:2015 (cl. 7.2 / 7.3)** y
**R2v3 (Core 4, FA4 technical competency)**.

> No es un clon de Canvas. Canvas es el benchmark de UX y del modelo de dominio;
> Classroom resuelve el problema que Canvas **no** resuelve: matriz de
> competencias por posición, entrenamiento ligado a Work Instructions con
> revisión controlada, recertificación con vencimiento, y evidencia de auditoría
> firmada y trazable.

---

## Estado

| Fase | Alcance | Estado |
|---|---|---|
| 0 | Análisis, modelo de datos, catálogo de SPs | ✅ Documentado |
| 0.5 | **Capa de datos completa: esquema, SPs, jobs, seed** | ✅ **Implementado** |
| 1 | API + auth Entra ID + catálogo de cursos | ⬜ Pendiente |
| 2 | Delivery: módulos, progreso, quizzes, ILT + asistencia | ⬜ Pendiente |
| 3 | Compliance: matriz de competencias, certificados, vencimientos | ⬜ Pendiente |
| 4 | Reportería, evidencia de auditoría, kiosk mode de piso | ⬜ Pendiente |
| 5 | Integraciones (Nexus/Movement gating, xAPI/cmi5 opcional) | ⬜ Pendiente |

Ver [`docs/08-roadmap.md`](docs/08-roadmap.md).

### Lo que ya está construido

| | |
|---|---|
| Tablas | 95 (4 temporales con versionado del sistema) |
| Stored procedures | 198 |
| Vistas de reporting | 12 |
| Funciones | 7 |
| Jobs del Agent | 7 |
| Permisos / roles | 45 / 7 |
| Líneas de T-SQL | ~14,700 |

Verificado: cero SPs invocados sin definir, cero funciones huérfanas, los 45
permisos que el código valida existen exactamente en el seed, y cada cursor
tiene su `DEALLOCATE`.

---

## Documentación

| Doc | Contenido |
|---|---|
| [`docs/01-analisis-canvas-y-gap.md`](docs/01-analisis-canvas-y-gap.md) | Teardown de Canvas, qué copiamos, qué descartamos, gap analysis Airlink |
| [`docs/02-modulos-y-requerimientos.md`](docs/02-modulos-y-requerimientos.md) | 14 módulos funcionales, requerimientos, roles, casos de uso |
| [`docs/03-arquitectura.md`](docs/03-arquitectura.md) | Stack, capas, deployment, decisiones (ADR) |
| [`docs/04-modelo-de-datos.md`](docs/04-modelo-de-datos.md) | Modelo lógico, 8 esquemas, ~60 tablas, convenciones |
| [`docs/05-catalogo-stored-procedures.md`](docs/05-catalogo-stored-procedures.md) | Contrato de SPs, convenciones, catálogo completo |
| [`docs/06-seguridad-y-rbac.md`](docs/06-seguridad-y-rbac.md) | Principals SQL, permisos, RBAC, e-signature, retención |
| [`docs/07-integracion-spn-airlink.md`](docs/07-integracion-spn-airlink.md) | Sync de empleados desde SPN, lectura de AIRLINK, gating |
| [`docs/08-roadmap.md`](docs/08-roadmap.md) | Fases, entregables, criterios de aceptación |

---

## Deploy de base de datos

```powershell
# Ver el plan sin tocar nada
.\scripts\deploy-db.ps1 -Server "192.168.181.248,13999" -WhatIf

# Desplegar
.\scripts\deploy-db.ps1 -Server "192.168.181.248,13999" -Database "AIRLINK_LMS"

# Verificar (15 checks: estructura, seguridad, integridad)
.\scripts\verify-db.ps1 -Server "192.168.181.248,13999" -Database "AIRLINK_LMS"
```

Todo es idempotente — se puede re-ejecutar sobre una base existente.

> **El orden de despliegue NO es el orden numérico.** `18_procs_platform.sql`
> corre **antes** que `11`–`17`, porque todos los SPs de negocio llaman a
> `aud.usp_Error_Log`, `aud.usp_Signature_Create` y `ops.usp_Notification_Enqueue`.
> SQL Server permite compilarlos igual (*deferred name resolution*), así que el
> deploy no falla — pero el primer error real en producción revienta dentro del
> `CATCH` al intentar loguear, enmascarando el error original.
> `deploy-db.ps1` ya maneja este orden.

### Pendientes de despliegue

1. Reemplazar las contraseñas placeholder de los 3 logins en `00_setup_database_roles.sql`
2. Reemplazar los GUID placeholder de `sec.RoleGroupMapping` con los ObjectId reales de Entra ID
3. Ajustar `@owner_login_name` de los jobs a la cuenta de servicio (no `sa`)
4. `Gating.Enforce` queda **apagado**. Encender solo tras semanas en modo Shadow
   y revisar `comp.GatingDecisionLog` para confirmar que lo que bloquearía son
   brechas reales y no datos sucios.

---

## Regla no negociable

**Toda** operación de datos (lectura y escritura) pasa por stored procedure.
Cero SQL ad-hoc, cero ORM generando queries, cero string concat.

Esto no depende de la disciplina del equipo: `AlLmsAppUser` tiene `EXECUTE` y
nada más — ni un `SELECT`. Una query directa **falla en runtime** por permisos.
`verify-db.ps1` (check 8) lo comprueba en cada despliegue.

Es lo que sostiene todo lo demás. Un LMS de compliance que expone las tablas no
vale nada: bastaría un `UPDATE` para falsificar una certificación sin pasar por
la firma, la validación ni la bitácora. Ver [`CLAUDE.md`](CLAUDE.md).
