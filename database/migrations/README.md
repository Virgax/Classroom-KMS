# Migraciones

Los archivos numerados de `database/` (`00` a `99`) definen el **estado
deseado** del esquema y son idempotentes: se pueden re-ejecutar sobre una
base existente sin romperla.

Esta carpeta es para lo que **no** es idempotente: cambios que mueven
datos existentes.

## Cuando va aqui un cambio

| Cambio | Donde va |
|---|---|
| Columna nueva, tabla nueva, indice nuevo | archivo numerado que corresponda |
| Cambio en un stored procedure o vista | archivo numerado (usan `CREATE OR ALTER`) |
| Renombrar una columna con datos | migracion aqui |
| Backfill de datos | migracion aqui |
| Cambiar el significado de un codigo de estado | migracion aqui |
| Dividir o fusionar tablas | migracion aqui |

## Convencion de nombres

```
YYYYMMDD_NNN_descripcion_corta.sql
20260815_001_backfill_certification_evidence_dates.sql
```

## Reglas

1. **Una migracion nunca se edita despues de correr en PROD.** Si estuvo
   mal, se escribe otra que lo corrija. El historial es evidencia.
2. **Toda migracion declara su rollback** en un comentario al inicio, aunque
   sea "no reversible: restaurar del respaldo".
3. **Se corre primero en DEV, luego QA, luego PROD.** Nunca al reves.
4. **Respaldo antes de correr en PROD.** Sin excepcion.
5. **Nada de `DELETE` sobre evidencia de compliance** (firmas,
   certificaciones, inscripciones, evaluaciones). Si una migracion parece
   necesitarlo, el diseno esta mal.

## Plantilla

```sql
/* ---------------------------------------------------------------------
   20260815_001_descripcion.sql
   Autor      :
   Fecha      :
   Ticket     :
   Proposito  :
   Rollback   :
   Duracion estimada :
   Requiere ventana de mantenimiento: si / no
   --------------------------------------------------------------------- */
USE AIRLINK_LMS;
GO
SET XACT_ABORT ON;
BEGIN TRANSACTION;

-- cambios aqui

COMMIT TRANSACTION;
GO
```
