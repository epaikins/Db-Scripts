#!/usr/bin/env bash
# Run backups for every DB config in configs/*.env (multiple servers/DBs) and push to S3.
# Schedule at midnight via cron: 0 0 * * * /path/to/db-scripts/cron-backup-all.sh >> /var/log/mysql-cron-backup.log 2>&1

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
CONFIGS_DIR="${CONFIGS_DIR:-$SCRIPT_DIR/configs}"
LOG_TAG="cron-backup-all"

if [[ ! -d "$CONFIGS_DIR" ]]; then
  echo "[$LOG_TAG] [$CONFIGS_DIR] Configs directory missing. Create configs/ and add <name>.env per server/DB." 1>&2
  exit 1
fi

shopt -s nullglob
CONFIGS=( "$CONFIGS_DIR"/*.env )
if [[ ${#CONFIGS[@]} -eq 0 ]]; then
  echo "[$LOG_TAG] No configs found in $CONFIGS_DIR (expected *.env). Copy configs/example-server.env.example to configs/<name>.env" 1>&2
  exit 1
fi

echo "[$LOG_TAG] [$(date -Iseconds)] Starting backups for ${#CONFIGS[@]} config(s)"

FAILED=()
for cfg in "${CONFIGS[@]}"; do
  name="$(basename "$cfg" .env)"
  echo "[$LOG_TAG] --- $name ($cfg) ---"
  if CONFIG_FILE="$cfg" "$SCRIPT_DIR/backup.sh"; then
    echo "[$LOG_TAG] OK: $name"
  else
    echo "[$LOG_TAG] FAILED: $name" 1>&2
    FAILED+=( "$name" )
  fi
done

echo "[$LOG_TAG] [$(date -Iseconds)] Finished. Total: ${#CONFIGS[@]}, Failed: ${#FAILED[@]}"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "[$LOG_TAG] Failed configs: ${FAILED[*]}" 1>&2
  exit 1
fi
