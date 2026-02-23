#!/usr/bin/env bash
# Physical backup via Percona XtraBackup (fastest for 50GB+; same MySQL version required).
# Restore with restore-xtrabackup.sh on the target host.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ -f config.env ]]; then
  set -a
  source config.env
  set +a
fi

BACKUP_DIR="${BACKUP_DIR:-./backups}"
STAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="${BACKUP_DIR}/xtra_${STAMP}"
mkdir -p "$OUT_DIR"

if ! command -v xtrabackup &>/dev/null && ! command -v innobackupex &>/dev/null; then
  echo "Percona XtraBackup not found. Install: https://www.percona.com/downloads/XtraBackup/"
  exit 1
fi

echo "[$(date -Iseconds)] Starting XtraBackup: $SOURCE_HOST -> $OUT_DIR"
xtrabackup --backup \
  --host="$SOURCE_HOST" \
  --port="${SOURCE_PORT:-3306}" \
  --user="$SOURCE_USER" \
  --password="$SOURCE_PASSWORD" \
  --target-dir="$OUT_DIR" \
  --parallel="${PARALLEL_JOBS:-4}" \
  --compress \
  --compress-threads="${PARALLEL_JOBS:-4}"

echo "[$(date -Iseconds)] Backup complete: $OUT_DIR"
echo "BACKUP_PATH=$OUT_DIR"
