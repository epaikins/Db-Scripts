#!/usr/bin/env bash
# Restore from Percona XtraBackup. Run on target host; MySQL must be stopped.
# Usage: ./restore-xtrabackup.sh <xtrabackup_directory>

set -euo pipefail
BACKUP_DIR="${1:-}"
TARGET_DIR="${2:-/var/lib/mysql}"  # or your datadir

if [[ -z "$BACKUP_DIR" || ! -d "$BACKUP_DIR" ]]; then
  echo "Usage: $0 <xtrabackup_backup_directory> [target_datadir]"
  exit 1
fi

echo "Prepare (decompress + apply log)..."
xtrabackup --prepare --target-dir="$BACKUP_DIR"

echo "Stop MySQL, then: xtrabackup --copy-back --target-dir=$BACKUP_DIR"
echo "Or move: rsync -av $BACKUP_DIR/ $TARGET_DIR/"
echo "Fix ownership (e.g. chown -R mysql:mysql $TARGET_DIR) and start MySQL."
