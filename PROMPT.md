# Arranque con Claude Code

Este archivo es para **ti** (humano), no para el agente. Explica cómo entregarle
el proyecto a Claude Code sin que se invente cosas.

---

## Paso 1 — Subir el repo a GitHub

```bash
cd classroom-lms
git init
git add .
git commit -m "Capa de datos completa: esquema, 198 SPs, jobs, seed"

gh repo create airlink/classroom-lms --private --source=. --push
# o si no usas gh:
# git remote add origin git@github.com:airlink/classroom-lms.git
# git branch -M main && git push -u origin main
```

Verifica que `.env` **no** subió. El `.gitignore` ya lo bloquea, pero míralo:

```bash
git ls-files | grep -i env    # debe mostrar solo .env.example
```

---

## Paso 2 — Abrir Claude Code en la carpeta

```bash
cd classroom-lms
claude
```

Claude Code carga `CLAUDE.md` automáticamente en cada sesión. Ahí ya están la
REGLA CERO, las convenciones de nombres, los tipos duros, la plantilla de
contrato de SP y los rangos de código de error. **No hace falta repetírselo.**

---

## Paso 3 — El prompt de arranque

Copia y pega esto tal cual en la primera sesión:

---

```
Este repo tiene la capa de datos completa de Classroom, el LMS interno de
Airlink Distribution DR: 95 tablas, 198 stored procedures, 12 vistas, 7
funciones y el seed de referencia. Todo desplegable y verificado.

Antes de escribir nada, lee en este orden:
  1. CLAUDE.md                              (reglas del proyecto)
  2. docs/03-arquitectura.md                (stack, capas, los 8 ADRs)
  3. docs/02-modulos-y-requerimientos.md    (los 14 módulos y 7 roles)
  4. docs/05-catalogo-stored-procedures.md  (el contrato de la capa de datos)
  5. src/*/README.md                        (qué va en cada proyecto)

No leas los archivos .sql completos todavía. Son ~14,700 líneas. Cuando
necesites la firma exacta de un SP, búscala con grep:

    grep -A 20 "CREATE OR ALTER PROCEDURE comp.usp_Certification_EvaluateAndIssue" database/15_procs_compliance.sql

Lo que quiero de ti, en este orden:

FASE 1 — Andamiaje y una vertical completa
  a) Crea la solución .NET 8: Classroom.Domain, Classroom.Infrastructure,
     Classroom.Api. Sin EF Core. Dapper solo como mapeador de resultsets.
  b) En Classroom.Domain: todos los enums que reflejan los TINYINT del
     esquema. Sácalos de los comentarios del DDL en database/02-08. Tienen
     que coincidir exactamente; un desfase silencioso aquí es de los bugs
     más caros de encontrar.
  c) En Classroom.Infrastructure: SqlConnectionFactory y
     StoredProcedureExecutor. El executor es el ÚNICO lugar del código que
     ejecuta comandos SQL.
  d) Middleware que mapea los códigos THROW de los SPs a HTTP según la tabla
     de src/Classroom.Domain/README.md.
  e) Una vertical funcionando de punta a punta: login con Entra ID +
     GET /api/courses (llama a lms.usp_Course_List) + tests de integración.

Antes de arrancar, dime tu plan y espera mi OK.

Reglas que no negocio:
- Cero SQL en C#. Ni un string. La app solo tiene EXECUTE.
- Si necesitas una consulta que no existe como SP, NO la escribas en C#:
  propón el SP nuevo, dime por qué hace falta, y lo agregamos al archivo
  numerado que corresponda.
- Los mensajes de error de los SPs vienen en español y son aptos para
  mostrarse al usuario. No los reemplaces por texto genérico.
- Cuando dudes de una columna, léela del DDL. No la adivines.
```

---

## Paso 4 — Las fases siguientes

No le pidas todo de una. Cada fase es una sesión limpia:

| Fase | Pídele esto |
|---|---|
| 1 | Andamiaje + una vertical (arriba) |
| 2 | Auth completa: Entra ID + PIN de kiosco con PBKDF2 + registro de dispositivos |
| 3 | Endpoints de catálogo, contenido y entrega |
| 4 | Evaluaciones: quizzes con snapshot y evaluación práctica OJT |
| 5 | Compliance: matriz, certificaciones, gating |
| 6 | Reportería y paquete de evidencia de auditoría |
| 7 | Worker de notificaciones (Graph) |
| 8 | Frontend React: primero kiosco, después escritorio |

`docs/08-roadmap.md` tiene el detalle y los criterios de aceptación de cada una.

---

## Cosas que te van a ahorrar dolor

**Despliega la base primero.** Que Claude Code trabaje contra un esquema real,
no contra su idea del esquema:

```powershell
.\scripts\deploy-db.ps1 -Server "TU-SERVIDOR-DEV" -Database "AIRLINK_LMS_DEV"
.\scripts\verify-db.ps1 -Server "TU-SERVIDOR-DEV" -Database "AIRLINK_LMS_DEV"
```

**Un branch por fase.** `git checkout -b fase-1-andamiaje`. Si una sesión se
va por un barranco, `git reset --hard` y vuelves a empezar sin perder lo bueno.

**Cuando proponga un SP nuevo, revísalo tú.** Es la única puerta por donde se
puede colar lógica de negocio fuera de la capa de datos.

**Si empieza a escribir SQL en C#, párala en seco.** No es pedantería: es lo
único que sostiene la firma, la auditoría y el gating. Y de todos modos
`AlLmsAppUser` no tiene permisos para ejecutarlo — fallaría en runtime.

---

## Lo que Claude Code NO debe tocar

- `database/*.sql` — para agregar objetos, sí; para cambiar los existentes,
  solo si tú lo apruebas explícitamente
- `database/migrations/` — las migraciones las escribes tú
- Cualquier cosa con contraseñas reales

---

## Antes de producción

1. Rotar las credenciales de SQL. La contraseña vieja circuló por chat.
2. Reemplazar las contraseñas placeholder de los 3 logins en
   `00_setup_database_roles.sql`
3. Reemplazar los GUID placeholder de `sec.RoleGroupMapping` con los ObjectId
   reales de Entra ID
4. Cambiar `@owner_login_name` de los jobs de `sa` a una cuenta de servicio
5. `Gating.Enforce` sigue apagado. Se enciende después de semanas en Shadow,
   revisando `comp.GatingDecisionLog`.
