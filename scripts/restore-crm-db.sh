#!/usr/bin/env bash
# Restore Twenty CRM Postgres from a plain SQL gzip dump under migrations/.
# Destructive: drops non-system schemas in the crm database before loading.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

YES=0
DUMP_ARG=""

usage() {
  cat <<'EOF'
Usage: restore-crm-db.sh [--yes] [dump.sql.gz]

  Restores the Twenty CRM database (crm_db / database crm) from a plain
  SQL gzip dump. Defaults to the newest migrations/*-crm-crm.sql.gz.

  --yes    Skip confirmation prompt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -y | --yes)
      YES=1
      shift
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$DUMP_ARG" ]]; then
        echo "error: unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      DUMP_ARG="$1"
      shift
      ;;
  esac
done

resolve_dump() {
  if [[ -n "$DUMP_ARG" ]]; then
    if [[ "$DUMP_ARG" = /* ]]; then
      printf '%s\n' "$DUMP_ARG"
    else
      printf '%s\n' "$ROOT/$DUMP_ARG"
    fi
    return
  fi

  local newest=""
  shopt -s nullglob
  local candidates=("$ROOT"/migrations/*-crm-crm.sql.gz)
  shopt -u nullglob
  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "error: no dumps matching migrations/*-crm-crm.sql.gz" >&2
    exit 1
  fi

  newest="$(printf '%s\n' "${candidates[@]}" | sort | tail -n1)"
  printf '%s\n' "$newest"
}

DUMP_HOST="$(resolve_dump)"
if [[ ! -f "$DUMP_HOST" ]]; then
  echo "error: dump not found: $DUMP_HOST" >&2
  exit 1
fi

case "$DUMP_HOST" in
  "$ROOT"/migrations/*) ;;
  *)
    echo "error: dump must live under $ROOT/migrations (mounted into crm_db)" >&2
    exit 1
    ;;
esac

DUMP_BASENAME="$(basename "$DUMP_HOST")"
DUMP_CONTAINER="/app/migrations/$DUMP_BASENAME"

echo "CRM restore dump: $DUMP_HOST"
echo "This wipes CRM DB schemas and reloads from that dump."

if [[ "$YES" -ne 1 ]]; then
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    y | Y | yes | YES) ;;
    *)
      echo "Aborted."
      exit 1
      ;;
  esac
fi

echo "Stopping crm_server and worker..."
docker compose stop crm_server worker

echo "Ensuring crm_db is up..."
docker compose up -d crm_db

echo "Waiting for crm_db to accept connections..."
for _ in $(seq 1 60); do
  if docker compose exec -T crm_db pg_isready -U crm -h localhost -d crm >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! docker compose exec -T crm_db pg_isready -U crm -h localhost -d crm >/dev/null 2>&1; then
  echo "error: crm_db did not become ready in time" >&2
  exit 1
fi

echo "Terminating open sessions and dropping non-system schemas..."
docker compose exec -T crm_db psql -U crm -d crm -v ON_ERROR_STOP=1 <<'SQL'
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = current_database()
  AND pid <> pg_backend_pid();

DO $$
DECLARE
  sch text;
BEGIN
  FOR sch IN
    SELECT nspname
    FROM pg_namespace
    WHERE nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND nspname NOT LIKE 'pg_temp_%'
      AND nspname NOT LIKE 'pg_toast_temp_%'
  LOOP
    EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', sch);
  END LOOP;

  CREATE SCHEMA public;
  GRANT ALL ON SCHEMA public TO crm;
  GRANT ALL ON SCHEMA public TO public;
END
$$;
SQL

echo "Loading dump into crm..."
docker compose exec -T crm_db bash -c \
  "zcat '$DUMP_CONTAINER' | psql -U crm -d crm -v ON_ERROR_STOP=1"

echo "Starting crm_server and worker..."
docker compose up -d crm_server worker

echo
docker compose ps crm_db crm_server worker
echo
echo "Restore complete. Check crm_server health (e.g. curl healthz on CRM_SERVER_PORT)."
