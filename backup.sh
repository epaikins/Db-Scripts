#!/usr/bin/env bash
# Fast MySQL backup for 50GB+ databases (target: sub-1-hour)
# Uses mydumper (parallel) when available, else tuned mysqldump.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Config: CONFIG_FILE env, or first argument, or default config.env
CONFIG_FILE="${CONFIG_FILE:-${1:-config.env}}"
[[ "$CONFIG_FILE" != /* ]] && CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE"

# Load config (safe for passwords with special characters)
if [[ -f "$CONFIG_FILE" ]]; then
  source "$SCRIPT_DIR/load-config.sh"
  load_config_env "$CONFIG_FILE"
else
  echo "Config not found: $CONFIG_FILE — create from config.example.env and set SOURCE_* and BACKUP_DIR."
  exit 1
fi

source "$SCRIPT_DIR/notify-teams.sh" 2>/dev/null || true

BACKUP_DIR="${BACKUP_DIR:-./backups}"
PARALLEL_JOBS="${PARALLEL_JOBS:-16}"
COMPRESS="${COMPRESS:-1}"
CHUNK_SIZE_MB="${CHUNK_SIZE_MB:-64}"
BACKUP_TOOL="${BACKUP_TOOL:-mydumper}"

_backup_failed() {
  local rc=$?
  if type notify_teams &>/dev/null && [[ -n "${TEAMS_WEBHOOK_URL:-}" ]]; then
    notify_teams "MySQL backup failed" "Database: ${SOURCE_DATABASE:-unknown}
Config: ${CONFIG_FILE:-}
Exit code: $rc" failure
  fi
}
trap _backup_failed ERR

STAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="${BACKUP_DIR}/${SOURCE_DATABASE:-db}_${STAMP}"
mkdir -p "$OUT_DIR"

echo "[$(date -Iseconds)] Starting backup: $SOURCE_DATABASE -> $OUT_DIR"

if command -v mydumper &>/dev/null && [[ "$BACKUP_TOOL" == mydumper ]]; then
  echo "Using mydumper (parallel dump)"
  COMPRESS_ARG=""
  [[ "$COMPRESS" == 1 ]] && COMPRESS_ARG="--compress"
  mydumper \
    --host="$SOURCE_HOST" \
    --port="${SOURCE_PORT:-3306}" \
    --user="$SOURCE_USER" \
    --password="$SOURCE_PASSWORD" \
    --database="$SOURCE_DATABASE" \
    --outputdir="$OUT_DIR" \
    --threads="$PARALLEL_JOBS" \
    --chunk-filesize=$((CHUNK_SIZE_MB)) \
    $COMPRESS_ARG \
    --trx-tables \
    --long-query-guard=7200 \
    --verbose=2
  echo "[$(date -Iseconds)] mydumper finished. Metadata in $OUT_DIR/metadata"
else
  echo "Using mysqldump (single-threaded fallback)"
  DUMP_FILE="$OUT_DIR/dump.sql"
  if [[ "$COMPRESS" == 1 ]]; then
    DUMP_FILE="$OUT_DIR/dump.sql.gz"
    mysqldump \
      -h "$SOURCE_HOST" -P "${SOURCE_PORT:-3306}" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
      --single-transaction --quick --lock-tables=false --routines --triggers \
      "$SOURCE_DATABASE" | gzip -c > "$DUMP_FILE"
  else
    mysqldump \
      -h "$SOURCE_HOST" -P "${SOURCE_PORT:-3306}" -u "$SOURCE_USER" -p"$SOURCE_PASSWORD" \
      --single-transaction --quick --lock-tables=false --routines --triggers \
      "$SOURCE_DATABASE" > "$DUMP_FILE"
  fi
  echo "[$(date -Iseconds)] mysqldump finished: $DUMP_FILE"
fi

echo "[$(date -Iseconds)] Backup complete: $OUT_DIR"

# Push to S3 if configured: bucket / YYYYMMDD / folder / db_YYYYMMDD.tar.gz (one per day per DB; new backup overwrites existing)
if [[ -n "${S3_BUCKET:-}" ]]; then
  if ! command -v aws &>/dev/null; then
    echo "Warning: aws CLI not found; skipping S3 upload."
  else
    DATE_PREFIX=$(date +%Y%m%d)
    S3_FOLDER="${S3_PREFIX:-upt}"
    ARCHIVE_NAME="${SOURCE_DATABASE:-db}_${DATE_PREFIX}.tar.gz"
    # Path: s3://bucket/YYYYMMDD/upt/db_YYYYMMDD.tar.gz (replaces existing same-day backup)
    S3_URI="s3://${S3_BUCKET}/${DATE_PREFIX}/${S3_FOLDER}/${ARCHIVE_NAME}"
    echo "[$(date -Iseconds)] Creating and uploading $ARCHIVE_NAME to $S3_URI ..."
    tar -czf - -C "$BACKUP_DIR" "$(basename "$OUT_DIR")" | aws s3 cp - "$S3_URI" ${AWS_REGION:+--region "$AWS_REGION"} --only-show-errors
    echo "[$(date -Iseconds)] S3 upload complete. S3_PATH=$S3_URI"
    echo "S3_UPLOADED=1"
    if [[ "${CLEAN_AFTER_S3_UPLOAD:-1}" == 1 ]]; then
      rm -rf "$OUT_DIR"
      echo "[$(date -Iseconds)] Removed local backup dir (uploaded to S3): $OUT_DIR"
    fi
  fi
fi

# Notify Teams if webhook configured
if type notify_teams &>/dev/null && [[ -n "${TEAMS_WEBHOOK_URL:-}" ]]; then
  BODY="Database: $SOURCE_DATABASE
Path: $OUT_DIR"
  [[ -n "${S3_URI:-}" ]] && BODY="$BODY
S3: $S3_URI"
  notify_teams "MySQL backup completed" "$BODY" success
fi

echo "BACKUP_PATH=$OUT_DIR"
