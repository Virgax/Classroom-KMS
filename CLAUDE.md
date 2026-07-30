# CLAUDE.md — Classroom LMS by Airlink

Instrucciones para Claude Code trabajando en este repo. Leer completo antes de
escribir cualquier línea de código.

---

## 1. Contexto del producto

Classroom es el LMS interno de Airlink Distribution DR (Santo Domingo). Usuarios
reales: ~400 empleados, mayoría operadores de piso de producción (celulares:
refurbishment, testing, QC). El propósito principal **no** es e-learning
académico — es:

1. Entrenar y certificar operadores en Work Instructions (WI) y procesos.
2. Mantener evidencia documentada de competencia para auditorías ISO 9001 y R2v3.
3. Disparar re-entrenamiento automático cuando una WI cambia de revisión.
4. Impedir que un operador trabaje una estación sin certificación vigente.

Cuando haya que decidir entre "feature bonita tipo Canvas" y "trazabilidad de
auditoría", **siempre gana trazabilidad de auditoría**.

---

## 2. REGLA CERO: todo por stored procedure

**Prohibido absolutamente:**

- SQL inline / ad-hoc en C#, TypeScript o cualquier capa.
- ORMs que generen SQL (EF Core `DbSet<T>` con LINQ traducido, Prisma, TypeORM,
  Sequelize). EF Core está permitido **únicamente** como mapper de resultados.
- `SELECT * FROM ...` en código de aplicación.
- Dynamic SQL construido por concatenación **dentro** de un SP.
  Si un SP necesita filtros opcionales, usar el patrón `OPTION (RECOMPILE)` con
  predicados `(@p IS NULL OR col = @p)`, o `sp_executesql` con parámetros
  tipados y whitelist de columnas de ordenamiento.

**Obligatorio:**

- Todo acceso a datos: `CommandType.StoredProcedure` (Dapper) con parámetros
  tipados.
- Un SP = una responsabilidad de negocio. No SPs "genéricos" tipo
  `usp_ExecuteQuery`.
- El app user (`AlLmsAppUser`) tiene **solo** `EXECUTE` sobre los esquemas de
  SPs. No tiene `SELECT` sobre ninguna tabla. Si el código intenta leer una
  tabla directo, falla en runtime — eso es intencional.

---

## 3. Convenciones de base de datos

### Naming

| Objeto | Patrón | Ejemplo |
|---|---|---|
| Esquema | minúscula, 3-5 letras | `lms`, `asmt`, `comp`, `intg`, `aud` |
| Tabla | PascalCase singular | `lms.Course`, `comp.Certification` |
| PK | `<Tabla>Id`, INT IDENTITY | `CourseId` |
| ID público | `PublicId UNIQUEIDENTIFIER` | expuesto en API, nunca el INT |
| FK | `<TablaReferida>Id` | `CourseId`, `EmployeeId` |
| Stored proc | `<schema>.usp_<Entidad>_<Acción>` | `lms.usp_Course_Publish` |
| Vista | `<schema>.vw_<Nombre>` | `rpt.vw_TrainingRecord` |
| Función | `<schema>.fn_<Nombre>` | `comp.fn_IsCertificationValid` |
| Índice | `IX_<Tabla>_<Cols>` | `IX_Enrollment_EmployeeId_Status` |
| Constraint | `CK_/UQ_/FK_<Tabla>_<Detalle>` | `UQ_Course_Code` |

### Tipos de dato — reglas duras

- Fechas: `DATETIME2(3)`. **Nunca** `DATETIME` ni `SMALLDATETIME`.
- Texto: `NVARCHAR`. **Nunca** `VARCHAR` (contenido bilingüe ES/EN + acentos).
- Dinero/decimales: `DECIMAL(18,4)`. **Nunca** `FLOAT` ni `MONEY`.
- Booleanos: `BIT NOT NULL` con `DEFAULT 0`.
- IDs públicos: `UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID()` (no `NEWSEQUENTIALID`
  para no filtrar orden de creación) + índice único no-clustered.
- Hora: todo se guarda en **UTC** (`SYSUTCDATETIME()`). La conversión a
  `America/Santo_Domingo` (UTC-4, sin DST) es responsabilidad del cliente.

### Columnas de auditoría — en TODA tabla transaccional

```sql
CreatedAtUtc    DATETIME2(3)   NOT NULL CONSTRAINT DF_<T>_CreatedAtUtc DEFAULT SYSUTCDATETIME(),
CreatedByUserId INT            NOT NULL,
ModifiedAtUtc   DATETIME2(3)   NULL,
ModifiedByUserId INT           NULL,
RowVersion      ROWVERSION     NOT NULL,
IsDeleted       BIT            NOT NULL CONSTRAINT DF_<T>_IsDeleted DEFAULT 0
```

Nunca `DELETE` físico en tablas de negocio. Soft delete + filtro en SP.
Excepción: tablas de staging en `intg` y `aud.EventLog` (purga por retención).

### Temporal tables (obligatorio en tablas críticas de auditoría)

Estas tablas van `WITH (SYSTEM_VERSIONING = ON)` porque un auditor puede
preguntar "¿qué requisito de competencia estaba vigente el 12 de marzo?":

- `comp.CompetencyRequirement`
- `comp.Certification`
- `lms.Enrollment`
- `lms.CourseVersion`
- `sec.UserRoleAssignment`

---

## 4. Contrato estándar de stored procedure

Todo SP sigue esta plantilla. No hay excepciones.

```sql
CREATE OR ALTER PROCEDURE lms.usp_Entidad_Accion
    @ActorUserId    INT,              -- SIEMPRE primero en SPs de escritura
    @ParametroA     NVARCHAR(100),
    @ParametroB     INT           = NULL,
    @IdempotencyKey UNIQUEIDENTIFIER = NULL,  -- SPs de escritura no idempotentes
    @NewEntityId    INT           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* ---------------------------------------------------------------
       Propósito : <una línea>
       Retorna   : <resultset(s) o solo OUTPUT>
       Errores   : 50001 = no encontrado, 50002 = sin permiso, ...
       --------------------------------------------------------------- */

    BEGIN TRY
        -- 1. Validación de parámetros (fail fast, antes de abrir transacción)
        IF @ActorUserId IS NULL
            THROW 50010, 'ActorUserId es requerido.', 1;

        -- 2. Validación de autorización
        IF NOT EXISTS (SELECT 1 FROM sec.fn_UserHasPermission(@ActorUserId, 'course.publish'))
            THROW 50002, 'El usuario no tiene permiso para esta operación.', 1;

        -- 3. Idempotencia
        IF @IdempotencyKey IS NOT NULL
           AND EXISTS (SELECT 1 FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey)
        BEGIN
            SELECT @NewEntityId = ResultEntityId
            FROM aud.IdempotencyKey WHERE IdempotencyKey = @IdempotencyKey;
            RETURN 0;
        END;

        BEGIN TRANSACTION;
            -- 4. Lógica
            -- 5. Auditoría: EXEC aud.usp_Event_Log ...
        COMMIT TRANSACTION;

        RETURN 0;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        EXEC aud.usp_Error_Log @ProcedureName = N'lms.usp_Entidad_Accion',
                               @ActorUserId   = @ActorUserId;
        THROW;
    END CATCH;
END;
GO
```

### Rangos de códigos de error

| Rango | Categoría |
|---|---|
| 50001–50099 | Validación / autorización genérica |
| 50100–50199 | Identidad y empleados |
| 50200–50299 | Catálogo y contenido |
| 50300–50399 | Inscripción y progreso |
| 50400–50499 | Evaluación (quizzes, rúbricas) |
| 50500–50599 | Compliance y certificación |
| 50600–50699 | Integraciones |

### Paginación estándar

Todo SP de listado acepta `@PageNumber INT = 1`, `@PageSize INT = 50`,
`@SortBy NVARCHAR(50) = NULL`, `@SortDir CHAR(4) = 'ASC'` y devuelve un segundo
resultset con `TotalCount`. `@PageSize` topado a 200 dentro del SP.

---

## 5. Stack y capas

```
classroom-web (React 19 + TS + Vite + Tailwind)
        │  HTTPS / JSON
Classroom.Api (.NET 9 Minimal API)   ← auth Entra ID (OIDC), autorización por policy
        │
Classroom.Infrastructure             ← Dapper. UNA clase por SP. Cero SQL suelto.
        │  CommandType.StoredProcedure
SQL Server 2019+  AIRLINK_LMS        ← toda la lógica de datos
        │  linked-server / job de sync (read-only)
SPN (empleados)  ·  AIRLINK (producción)
```

### Reglas de la capa Infrastructure

- Un archivo por área: `CourseRepository.cs`, `EnrollmentRepository.cs`, etc.
- Cada método mapea 1:1 a un SP. El nombre del método = nombre del SP sin prefijo.
- El nombre del SP vive en una constante `const string Sp = "lms.usp_Course_Create";`
- `DynamicParameters` siempre con `DbType` y `size` explícitos.
- `@ActorUserId` se inyecta desde el `ClaimsPrincipal`, **nunca** viene del body
  del request. Si un endpoint acepta ActorUserId del cliente, es un bug de
  seguridad.

### Reglas de la capa Api

- DTOs de request/response separados de los modelos de dominio.
- Validación con FluentValidation antes de llegar al SP (defensa en profundidad,
  no reemplaza la validación en el SP).
- Nunca exponer `CourseId` (INT). Exponer `PublicId` (GUID).
- Todo endpoint de escritura acepta header `Idempotency-Key`.

---

## 6. Cómo trabajar en este repo

### Al agregar una feature

1. Actualizar `docs/04-modelo-de-datos.md` si hay tablas nuevas.
2. Escribir el DDL en el archivo `database/0X_tables_*.sql` correspondiente.
3. Escribir el SP en `database/1X_procs_*.sql` con el contrato de la sección 4.
4. Registrar el SP en `docs/05-catalogo-stored-procedures.md`.
5. Repositorio en Infrastructure + endpoint en Api.
6. Test de integración que llama al SP real contra la DB de DEV.

### Al modificar la DB

- Los scripts en `database/` son **idempotentes y re-ejecutables**. Usar
  `IF NOT EXISTS` para tablas, `CREATE OR ALTER` para SPs/vistas/funciones.
- Cambios destructivos (drop/rename de columna) van en un archivo nuevo
  `database/migrations/YYYYMMDD_HHMM_descripcion.sql`.
- Nunca editar un script de migración ya aplicado en PROD.

### Prohibiciones de repo

- No commitear `.env`, `appsettings.Production.json`, ni ningún archivo con
  contraseñas. `.gitignore` ya los cubre.
- No hardcodear connection strings. Todo por configuración/secret store.
- No commitear backups `.bak` ni dumps con data de empleados (PII).

---

## 7. Bilingüe por diseño

Español dominicano es el idioma primario del piso; inglés el de la
documentación técnica y de los clientes (Assurant/AT&T).

- Todo contenido de curso, quiz y certificado es **versionado por locale**
  (`es-DO`, `en-US`) vía `lms.ContentTranslation`.
- Los identificadores en código y DB son en **inglés**. Los datos de contenido
  van en el idioma que corresponda.
- Un curso puede publicarse con un locale y quedar pendiente en el otro; el SP
  `lms.usp_Course_Publish` valida que exista al menos `es-DO`.

---

## 8. Cosas que NO vamos a construir (scope discipline)

Descartado deliberadamente de Canvas. No lo agregues sin discutirlo:

- Foros de discusión con hilos anidados (no aplica en piso; usamos Teams).
- Grupos colaborativos / peer review.
- Portal de padres/tutores.
- ePortfolios.
- Marketplace LTI de 1000+ apps (sí LTI 1.3 puntual si algún día hace falta).
- Motor de SCORM en fase 1–4. Ver ADR-007 en `docs/03-arquitectura.md`.
