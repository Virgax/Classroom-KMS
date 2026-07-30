# Classroom.Api

ASP.NET Core. Endpoints, autenticación, DTOs y validación. Capa delgada: la
lógica de negocio vive en los stored procedures, no aquí.

## Autenticación: dos caminos

| Escenario | Método | Sesión |
|---|---|---|
| Oficina, escritorio | Entra ID (OIDC) | 8 horas |
| Piso de producción | Código de empleado + PIN | 10 minutos |

El segundo camino existe por **GAP-09**: la mayoría de los operadores no tiene
correo corporativo. El kiosco es una tableta compartida, por eso el timeout es
agresivo — dejar la sesión de otro abierta invalidaría cualquier firma.

Los dispositivos de piso se registran (`sec.DeviceRegistration`) y el PIN sólo
se acepta desde un dispositivo registrado y activo.

## Mapeo de errores

Los SPs lanzan códigos numéricos. El middleware los traduce:

```csharp
50001–50099 → 404 / 403
50100–50199 → 401
50200–50599 → 409 Conflict  (violación de regla de negocio)
50600–50699 → 502 Bad Gateway
50700–50799 → 500
```

El mensaje del SP viene en español y es apto para mostrarse al usuario: están
escritos para eso. No los reemplaces por texto genérico.

## Bilingüe (GAP-10)

El header `Accept-Language` determina `@LocaleCode`. Los SPs de contenido hacen
fallback a `es-DO` cuando falta la traducción — nunca devuelven vacío. Si un
curso no está traducido, el operador ve el español, no una pantalla en blanco.

## El worker de notificaciones

SQL Server **no** envía correos. Encola en `ops.NotificationQueue` y este
servicio hace el envío real vía Graph:

```
ops.usp_Notification_Dequeue   → toma un lote (READPAST: varios workers en paralelo)
   ... envía por Graph ...
ops.usp_Notification_MarkSent  → confirma, o programa reintento con backoff
```

Tras 5 intentos fallidos pasa a dead-letter. `ops.usp_Health_GetStatus` reporta
el tamaño de la cola: si crece, el worker está caído.

## Endpoint de gating

`GET /api/eligibility/station/{stationCode}?employeeCode={code}`

Lo consumen Nexus y Movement antes de asignar a alguien a una estación.
Responde en milisegundos y **registra toda decisión** en
`comp.GatingDecisionLog`, incluso en modo Shadow. Ese log es lo que permite
medir la tasa de bloqueo antes de encender `Gating.Enforce`.
