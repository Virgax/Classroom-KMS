# Classroom.Infrastructure

Acceso a datos, integraciones externas y servicios de infraestructura. Es la
**única** capa que habla con SQL Server.

## Estructura

```
Data/
  SqlConnectionFactory.cs      abre conexiones, lee la cadena de Key Vault
  StoredProcedureExecutor.cs   el único lugar que ejecuta comandos
  Repositories/                un repositorio por esquema
  Mappers/                     resultset -> entidad de dominio
Integrations/
  SpnEmployeeReader.cs         lee SPN (solo lectura)
  AirlinkProductionReader.cs   lee AIRLINK (solo lectura)
  GraphNotificationSender.cs   worker de la cola de notificaciones
Storage/
  FileAssetStore.cs            file share / blob según configuración
Security/
  PinHasher.cs                 PBKDF2. El PIN nunca llega a T-SQL en claro.
```

## REGLA CERO

**Todo acceso a datos pasa por un stored procedure.** Sin excepciones.

```csharp
// CORRECTO
var result = await _executor.ExecuteAsync(
    "comp.usp_Certification_EvaluateAndIssue",
    new { ActorUserId = actorId, EmployeeId = employeeId, TriggerType = 1 });

// PROHIBIDO — no importa cuán inocente parezca
var sql = "SELECT * FROM comp.Certification WHERE EmployeeId = @id";
```

`AlLmsAppUser` sólo tiene `EXECUTE`, así que una query directa **falla en
runtime** con un error de permisos. La restricción no depende de la disciplina
del equipo: la base la impone. `verify-db.ps1` (check 8) lo comprueba en cada
despliegue.

Tampoco se usa ORM con generación de queries. Dapper es aceptable **sólo** como
mapeador de resultsets de SPs, nunca para construir SQL.

## Autenticación por PIN

El PIN de piso se hashea en C# con PBKDF2 antes de llamar al SP. T-SQL recibe
el hash, nunca el PIN. `sec.usp_User_AuthenticatePin` funciona en dos fases:
devuelve el salt, la aplicación calcula el hash, y una segunda llamada lo
verifica.

## SPs con múltiples resultsets

Varios devuelven varios resultsets en un solo viaje. Hay que leerlos todos:

- `rpt.usp_TrainingRecord_GetForEmployee` → 10 resultsets (el expediente completo)
- `rpt.usp_AuditEvidence_GeneratePackage` → 8 resultsets
- `asmt.usp_Attempt_Start` → 3 (cabecera, preguntas, opciones)

## Idempotencia

Las operaciones que crean cosas aceptan `@IdempotencyKey` (GUID). El cliente lo
genera una vez por intención y lo reenvía en los reintentos. Un timeout de red
no debe producir dos inscripciones ni dos intentos de examen.
