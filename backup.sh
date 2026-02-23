#!/usr/bin/env bash
# Fast MySQL backup for 50GB+ databases (target: sub-1-hour)
# Uses mydumper (parallel) when available, else tuned mysqldump.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load config (safe for passwords with special characters)
if [[ -f config.env ]]; then
  source "$SCRIPT_DIR/load-config.sh"
  load_config_env "$SCRIPT_DIR/config.env"
else
  echo "Create config.env from config.example.env and set SOURCE_* and BACKUP_DIR."
  exit 1
fi

BACKUP_DIR="${BACKUP_DIR:-./backups}"
PARALLEL_JOBS="${PARALLEL_JOBS:-16}"
COMPRESS="${COMPRESS:-1}"
CHUNK_SIZE_MB="${CHUNK_SIZE_MB:-64}"
BACKUP_TOOL="${BACKUP_TOOL:-mydumper}"

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
    --trx-consistency-only \
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

# Push to S3 if configured
if [[ -n "${S3_BUCKET:-}" ]]; then
  if ! command -v aws &>/dev/null; then
    echo "Warning: aws CLI not found; skipping S3 upload."
  else
    S3_PREFIX="${S3_PREFIX:-mysql-backups}"
    S3_URI="s3://${S3_BUCKET}/${S3_PREFIX}/$(basename "$OUT_DIR")/"
    echo "[$(date -Iseconds)] Uploading to $S3_URI ..."
    aws s3 sync "$OUT_DIR" "$S3_URI" ${AWS_REGION:+--region "$AWS_REGION"} --only-show-errors
    echo "[$(date -Iseconds)] S3 upload complete. S3_PATH=$S3_URI"
  fi
fi

echo "BACKUP_PATH=$OUT_DIR"
