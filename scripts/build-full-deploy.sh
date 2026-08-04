#!/usr/bin/env bash
# =====================================================================
# Genera database/remote/kms_full_deploy.sql: TODA la capa de datos del
# KMS en un solo archivo, en el orden de dependencia correcto, para
# correrlo de una vez en clientes sin sqlcmd (DataGrip, SSMS).
#
# El archivo generado NO se edita a mano: se regenera con este script.
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
OUT="$REPO_ROOT/database/remote/kms_full_deploy.sql"

ORDER=(
  00_setup_database_roles.sql
  01_schemas.sql
  02_tables_core.sql
  03_tables_catalog.sql
  04_tables_content.sql
  05_tables_assessment.sql
  06_tables_delivery.sql
  07_tables_compliance.sql
  08_tables_platform.sql
  09_functions.sql
  10_views_reporting.sql
  18_procs_platform.sql
  11_procs_identity.sql
  12_procs_catalog_content.sql
  13_procs_delivery_progress.sql
  14_procs_assessment.sql
  15_procs_compliance.sql
  16_procs_reporting.sql
  17_procs_integration.sql
  99_seed_reference_data.sql
  19_jobs_agent.sql
)

{
  cat <<'HEADER'
/* =============================================================================
   Classroom KMS - DESPLIEGUE COMPLETO DE LA CAPA DE DATOS
   Archivo GENERADO por scripts/build-full-deploy.sh - no editar a mano.

   Crea la base AIRLINK_KMS completa: esquemas, ~100 tablas, funciones,
   vistas, ~200 stored procedures, seed de referencia y jobs del Agent.

   ANTES DE CORRER (una sola vez):
     1. Reemplazar las 3 contrasenas placeholder
        <<REEMPLAZAR-DESDE-KEY-VAULT-...>> en la seccion de logins.
     2. Verificar que la conexion tenga QUOTED_IDENTIFIER ON
        (SSMS y DataGrip lo traen por defecto).
     3. El ultimo bloque (jobs del Agent) requiere SQL Server Agent activo;
        si el Agent no esta disponible, ese bloque fallara y puede
        omitirse sin afectar el resto.

   Idempotente: re-ejecutable sobre una base existente.
   El orden NO es numerico a proposito: 18 corre antes que 11-17 porque
   todos los SPs de negocio llaman a aud.usp_Error_Log / usp_Event_Log.
   ============================================================================= */
HEADER

  for f in "${ORDER[@]}"; do
    echo ""
    echo "/* ############################################################################"
    echo "   ARCHIVO: database/$f"
    echo "   ############################################################################ */"
    cat "$REPO_ROOT/database/$f"
  done
} > "$OUT"

echo "Generado: $OUT ($(wc -l < "$OUT") lineas)"
