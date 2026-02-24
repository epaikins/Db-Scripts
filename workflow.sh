#!/usr/bin/env bash
# Full workflow: backup from source -> [optional transfer] -> restore to target
# For 50GB+ DBs; aim: complete in under 1 hour with mydumper/myloader.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODE="${1:-full}"   # full | backup-only | restore-only
BACKUP_PATH="${2:-}"  # for restore-only: path to backup dir (local or after transfer)

if [[ -f config.env ]]; then
  source "$SCRIPT_DIR/load-config.sh"
  load_config_env "$SCRIPT_DIR/config.env"
else
  echo "Create config.env from config.example.env"
  exit 1
fi

BACKUP_DIR="${BACKUP_DIR:-./backups}"

case "$MODE" in
  backup-only)
    echo "=== Backup only ==="
    exec "$SCRIPT_DIR/backup.sh"
    ;;
  restore-only)
    if [[ -z "$BACKUP_PATH" ]]; then
      echo "Usage: $0 restore-only <backup_directory_or_s3_uri>"
      echo "  e.g. ./backups/mydb_20250223_120000  or  s3://bucket/prefix/mydb_20250223_120000.tar.gz"
      exit 1
    fi
    echo "=== Restore only ==="
    RESTORE_DIR="$BACKUP_PATH"
    if [[ "$BACKUP_PATH" == s3://* ]]; then
      if ! command -v aws &>/dev/null; then
        echo "Error: aws CLI required to restore from S3."
        exit 1
      fi
      DOWNLOAD_DIR="${BACKUP_DIR:-./backups}/restore_from_s3_$$"
      mkdir -p "$DOWNLOAD_DIR"
      if [[ "$BACKUP_PATH" == *.tar.gz ]]; then
        echo "[$(date -Iseconds)] Downloading archive from S3: $BACKUP_PATH"
        aws s3 cp "$BACKUP_PATH" "$DOWNLOAD_DIR/backup.tar.gz" ${AWS_REGION:+--region "$AWS_REGION"} --only-show-errors
        echo "[$(date -Iseconds)] Extracting..."
        tar -xzf "$DOWNLOAD_DIR/backup.tar.gz" -C "$DOWNLOAD_DIR"
        rm -f "$DOWNLOAD_DIR/backup.tar.gz"
        # Archive contains one top-level dir (e.g. mydb_20250224_000000)
        RESTORE_DIR=$(find "$DOWNLOAD_DIR" -mindepth 1 -maxdepth 1 -type d | head -1)
        [[ -z "$RESTORE_DIR" || ! -d "$RESTORE_DIR" ]] && { echo "Error: could not find backup dir inside archive."; exit 1; }
      else
        echo "[$(date -Iseconds)] Downloading from S3: $BACKUP_PATH -> $DOWNLOAD_DIR"
        aws s3 sync "$BACKUP_PATH" "$DOWNLOAD_DIR" ${AWS_REGION:+--region "$AWS_REGION"} --only-show-errors
        RESTORE_DIR="$DOWNLOAD_DIR"
      fi
    fi
    "$SCRIPT_DIR/restore.sh" "$RESTORE_DIR"
    [[ -n "${DOWNLOAD_DIR:-}" ]] && rm -rf "$DOWNLOAD_DIR"
    ;;
  full)
    echo "=== Full: backup -> [transfer] -> restore ==="
    START=$(date +%s)
    "$SCRIPT_DIR/backup.sh" | tee /tmp/backup_output.$$.txt
    BACKUP_PATH=$(grep '^BACKUP_PATH=' /tmp/backup_output.$$.txt | cut -d= -f2)
    rm -f /tmp/backup_output.$$.txt
    if [[ -z "$BACKUP_PATH" ]]; then
      echo "Could not determine BACKUP_PATH from backup script."
      exit 1
    fi
    if [[ -n "${REMOTE_BACKUP_PATH:-}" ]]; then
      echo "Transferring backup to $REMOTE_BACKUP_PATH..."
      rsync -avz --progress "$BACKUP_PATH/" "$REMOTE_BACKUP_PATH/"
      END=$(date +%s)
      echo "=== Backup + transfer time: $(( (END - START) / 60 )) minutes ==="
      echo "On target host run: ./workflow.sh restore-only $REMOTE_BACKUP_PATH"
    else
      "$SCRIPT_DIR/restore.sh" "$BACKUP_PATH"
      END=$(date +%s)
      echo "=== Total time: $(( (END - START) / 60 )) minutes ==="
    fi
    ;;
  *)
    echo "Usage: $0 {full|backup-only|restore-only} [backup_directory]"
    exit 1
    ;;
esac
