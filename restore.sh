#!/usr/bin/env bash
# Fast MySQL restore for 50GB+ dumps (target: sub-1-hour)
# Uses myloader for mydumper dumps, else mysql client for .sql/.sql.gz

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load config (safe for passwords with special characters)
if [[ -f config.env ]]; then
  source "$SCRIPT_DIR/load-config.sh"
  load_config_env "$SCRIPT_DIR/config.env"
fi

PARALLEL_JOBS="${PARALLEL_JOBS:-16}"
# Use RESTORE_THREADS for myloader if set (e.g. 1 or 2 to avoid Trace/breakpoint trap crash)
RESTORE_THREADS="${RESTORE_THREADS:-$PARALLEL_JOBS}"
RESTORE_DIR="${1:-}"

if [[ -z "$RESTORE_DIR" || ! -d "$RESTORE_DIR" ]]; then
  echo "Usage: $0 <backup_directory>"
  echo "  backup_directory: path from backup (e.g. ./backups/mydb_20250223_120000)"
  exit 1
fi

echo "[$(date -Iseconds)] Starting restore from $RESTORE_DIR -> $TARGET_DATABASE on $TARGET_HOST"

# Detect backup type: mydumper (metadata + .sql[.gz]) or single dump file
if [[ -f "$RESTORE_DIR/metadata" ]]; then
  echo "Detected mydumper backup; using myloader"
  if ! command -v myloader &>/dev/null; then
    echo "myloader not found. Install mydumper package (includes myloader)."
    exit 1
  fi
  myloader \
    --host="$TARGET_HOST" \
    --port="${TARGET_PORT:-3306}" \
    --user="$TARGET_USER" \
    --password="$TARGET_PASSWORD" \
    --directory="$RESTORE_DIR" \
    --threads="$RESTORE_THREADS" \
    --overwrite-tables \
    --verbose=2
  echo "[$(date -Iseconds)] myloader finished."
else
  echo "Detected single-file dump; using mysql with bulk optimizations"
  DUMP_FILE=""
  for f in "$RESTORE_DIR"/dump.sql.gz "$RESTORE_DIR"/dump.sql; do
    [[ -f "$f" ]] && DUMP_FILE="$f" && break
  done
  if [[ -z "$DUMP_FILE" ]]; then
    echo "No dump.sql or dump.sql.gz found in $RESTORE_DIR"
    exit 1
  fi
  # Create DB if not exists, then restore with bulk-friendly session vars
  mysql -h "$TARGET_HOST" -P "${TARGET_PORT:-3306}" -u "$TARGET_USER" -p"$TARGET_PASSWORD" \
    -e "CREATE DATABASE IF NOT EXISTS \`$TARGET_DATABASE\`;"
  if [[ "$DUMP_FILE" == *.gz ]]; then
    gunzip -c "$DUMP_FILE" | mysql -h "$TARGET_HOST" -P "${TARGET_PORT:-3306}" -u "$TARGET_USER" -p"$TARGET_PASSWORD" \
      --init-command="SET SESSION foreign_key_checks=0; SET SESSION unique_checks=0; SET SESSION sql_log_bin=0; SET SESSION autocommit=0;" \
      "$TARGET_DATABASE"
  else
    mysql -h "$TARGET_HOST" -P "${TARGET_PORT:-3306}" -u "$TARGET_USER" -p"$TARGET_PASSWORD" \
      --init-command="SET SESSION foreign_key_checks=0; SET SESSION unique_checks=0; SET SESSION sql_log_bin=0; SET SESSION autocommit=0;" \
      "$TARGET_DATABASE" < "$DUMP_FILE"
  fi
  echo "[$(date -Iseconds)] mysql restore finished."
fi

echo "[$(date -Iseconds)] Restore complete: $TARGET_DATABASE"
