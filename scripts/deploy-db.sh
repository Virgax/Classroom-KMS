#!/usr/bin/env bash
# =====================================================================
# Despliegue de la capa de datos en Linux/contenedores (equivalente a
# deploy-db.ps1 para entornos sin PowerShell).
#
# Espeja el MISMO orden de dependencia que deploy-db.ps1:
#   18_procs_platform.sql corre ANTES que 11-17. Ver README.
#
# Uso (contenedor de desarrollo):
#   KMS_SQL_CONTAINER=kms-sql KMS_SA_PASSWORD='...' ./deploy-db.sh
#
# Variables:
#   KMS_SQL_CONTAINER  contenedor docker con SQL Server (default kms-sql)
#   KMS_SA_PASSWORD    contraseña de sa (obligatoria)
#   KMS_DATABASE       base destino (default AIRLINK_KMS)
#   KMS_APP_PASSWORD / KMS_SYNC_PASSWORD / KMS_REPORT_PASSWORD
#                      contraseñas para los 3 logins (obligatorias en el
#                      primer deploy; reemplazan los placeholders SOLO en
#                      la copia staging, nunca en el repo)
# =====================================================================
set -euo pipefail

CONTAINER="${KMS_SQL_CONTAINER:-kms-sql}"
DB="${KMS_DATABASE:-AIRLINK_KMS}"
: "${KMS_SA_PASSWORD:?Definir KMS_SA_PASSWORD}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$REPO_ROOT"/database/*.sql "$STAGE/"

# Nombre de base y contraseñas solo en la copia staging.
sed -i "s/AIRLINK_LMS/$DB/g" "$STAGE"/*.sql
if grep -q "REEMPLAZAR-DESDE-KEY-VAULT" "$STAGE"/00_setup_database_roles.sql; then
    : "${KMS_APP_PASSWORD:?Definir KMS_APP_PASSWORD (primer deploy)}"
    : "${KMS_SYNC_PASSWORD:?Definir KMS_SYNC_PASSWORD (primer deploy)}"
    : "${KMS_REPORT_PASSWORD:?Definir KMS_REPORT_PASSWORD (primer deploy)}"
    sed -i "s/<<REEMPLAZAR-DESDE-KEY-VAULT-APP>>/$KMS_APP_PASSWORD/" "$STAGE"/00_setup_database_roles.sql
    sed -i "s/<<REEMPLAZAR-DESDE-KEY-VAULT-SYNC>>/$KMS_SYNC_PASSWORD/" "$STAGE"/00_setup_database_roles.sql
    sed -i "s/<<REEMPLAZAR-DESDE-KEY-VAULT-REPORT>>/$KMS_REPORT_PASSWORD/" "$STAGE"/00_setup_database_roles.sql
fi

docker exec -u root "$CONTAINER" rm -rf /tmp/db-stage
docker cp "$STAGE" "$CONTAINER":/tmp/db-stage >/dev/null

# -I es OBLIGATORIO: QUOTED_IDENTIFIER ON para indices filtrados.
SQLCMD="/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I"

# Orden de dependencia. NO reordenar sin leer el README.
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

for f in "${ORDER[@]}"; do
  case "$f" in
    00_*|19_*) TARGETDB=master ;;
    *)         TARGETDB=$DB ;;
  esac
  printf '%-38s' "$f"
  if OUT=$(docker exec -e SQLCMDPASSWORD="$KMS_SA_PASSWORD" "$CONTAINER" $SQLCMD -d "$TARGETDB" -i "/tmp/db-stage/$f" 2>&1); then
    echo "OK"
  else
    echo "FALLO"
    echo "$OUT" | tail -20
    exit 1
  fi
done

echo
echo "=== Conteo de objetos ==="
docker exec -e SQLCMDPASSWORD="$KMS_SA_PASSWORD" "$CONTAINER" $SQLCMD -d "$DB" -Q "
SELECT  Tablas         = (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0 AND temporal_type <> 1)
      , Temporales     = (SELECT COUNT(*) FROM sys.tables WHERE temporal_type = 2)
      , Vistas         = (SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0)
      , Funciones      = (SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN','IF','TF'))
      , Procedimientos = (SELECT COUNT(*) FROM sys.procedures)
      , Permisos       = (SELECT COUNT(*) FROM sec.Permission)
      , Roles          = (SELECT COUNT(*) FROM sec.Role);"
