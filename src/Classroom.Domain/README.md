# Classroom.Domain

Modelos, enums y lógica pura. **Sin dependencias externas** — ni EF Core, ni
ADO.NET, ni ASP.NET. Si este proyecto necesita un paquete NuGet de acceso a
datos, algo se puso en la capa equivocada.

## Qué vive aquí

```
Entities/        POCOs que reflejan los resultsets de los SPs
Enums/           Los códigos TINYINT del esquema, tipados
ValueObjects/    CertificateNumber, EmployeeCode, LocaleCode
Rules/           Lógica pura que se puede probar sin base de datos
Exceptions/      DomainException y sus derivadas por rango de error
```

## Enums: una sola fuente de verdad

El esquema usa `TINYINT` para todos los estados. Esos valores están
documentados en comentarios del DDL y **tienen que coincidir exactamente**
aquí. Un desfase silencioso entre el enum de C# y el `CHECK` de SQL es de los
bugs más caros de encontrar.

```csharp
public enum CertificationStatus : byte
{
    Valid                = 1,
    ExpiringSoon         = 2,
    Expired              = 3,
    RetrainingRequired   = 4,   // GAP-02: una revisión de WI invalidó la evidencia
    Revoked              = 5,
    Provisional          = 6    // opera bajo supervisión directa
}

public enum GapType : byte
{
    NeverCertified     = 1,
    Expired            = 2,
    ExpiringSoon       = 3,
    RetrainingRequired = 4,
    InsufficientLevel  = 5,
    Revoked            = 6
}

public enum GatingDecision : byte
{
    Allowed                = 1,
    AllowedWithSupervision = 2,   // hay waiver con RequiresSupervision
    Blocked                = 3
}
```

## Rangos de código de error

Los SPs lanzan con `THROW <numero>`. El mapeo a respuesta HTTP vive en la API,
pero el rango lo define el dominio:

| Rango | Origen | HTTP típico |
|---|---|---|
| 50001–50099 | genéricos (no encontrado, sin permiso) | 404 / 403 |
| 50100–50199 | identidad y sesión | 401 |
| 50200–50299 | catálogo y contenido | 409 |
| 50300–50399 | entrega e ILT | 409 |
| 50400–50499 | evaluación | 409 |
| 50500–50599 | compliance | 409 / 422 |
| 50600–50699 | integración | 502 |
| 50700–50799 | plataforma | 500 |

## Regla que no se negocia

Nada en este proyecto arma SQL. Ni un `string`. Si aparece la palabra
`SELECT` en un archivo de `Classroom.Domain`, es un bug.
