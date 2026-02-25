#!/usr/bin/env bash
# Install a systemd service + timer to run cron backups for all DBs (configs/*.env) daily at midnight.
# Usage:
#   ./install-cron-backup-service.sh              # system-wide (requires sudo)
#   ./install-cron-backup-service.sh --user       # user units (~/.config/systemd/user)
#   ./install-cron-backup-service.sh --dry-run    # print units only, do not install

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="mysql-cron-backup"
USER_MODE=false
DRY_RUN=false
SKIP_ENABLE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)      USER_MODE=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --skip-enable) SKIP_ENABLE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--user] [--dry-run] [--skip-enable]"
      echo "  --user       Install user units (~/.config/systemd/user). No sudo."
      echo "  --dry-run    Print service and timer unit content only; do not install."
      echo "  --skip-enable  Install units but do not enable or start the timer."
      exit 0
      ;;
    *) echo "Unknown option: $1" 1>&2; exit 1 ;;
  esac
done

if [[ "$USER_MODE" == true ]]; then
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  LOG_FILE="$SCRIPT_DIR/logs/cron-backup.log"
  SYSTEMCTL_OPTS=(--user)
else
  UNIT_DIR="/etc/systemd/system"
  LOG_FILE="/var/log/mysql-cron-backup.log"
  SYSTEMCTL_OPTS=()
  if [[ "$DRY_RUN" != true ]] && [[ "$(id -u)" -ne 0 ]]; then
    echo "System-wide install requires root. Run: sudo $0" 1>&2
    echo "Or use --user to install for your user only." 1>&2
    exit 1
  fi
fi

# Ensure log directory exists for user mode
if [[ "$USER_MODE" == true ]] && [[ "$DRY_RUN" != true ]]; then
  mkdir -p "$(dirname "$LOG_FILE")"
fi

SERVICE_CONTENT="[Unit]
Description=MySQL cron backup (all configs in configs/*.env)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$SCRIPT_DIR
ExecStart=$SCRIPT_DIR/cron-backup-all.sh
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=default.target
"

TIMER_CONTENT="[Unit]
Description=Run MySQL cron backup daily at midnight
Requires=${SERVICE_NAME}.service

[Timer]
OnCalendar=*-*-* 00:00:00
Persistent=true

[Install]
WantedBy=timers.target
"

if [[ "$DRY_RUN" == true ]]; then
  echo "=== ${SERVICE_NAME}.service ==="
  echo "$SERVICE_CONTENT"
  echo "=== ${SERVICE_NAME}.timer ==="
  echo "$TIMER_CONTENT"
  echo ""
  echo "Would install to: $UNIT_DIR"
  echo "Log file: $LOG_FILE"
  exit 0
fi

mkdir -p "$UNIT_DIR"
echo "$SERVICE_CONTENT" > "$UNIT_DIR/${SERVICE_NAME}.service"
echo "$TIMER_CONTENT" > "$UNIT_DIR/${SERVICE_NAME}.timer"
echo "Installed $UNIT_DIR/${SERVICE_NAME}.service"
echo "Installed $UNIT_DIR/${SERVICE_NAME}.timer"

if [[ "$USER_MODE" == true ]]; then
  systemctl "${SYSTEMCTL_OPTS[@]}" daemon-reload
else
  systemctl daemon-reload
fi

if [[ "$SKIP_ENABLE" != true ]]; then
  systemctl "${SYSTEMCTL_OPTS[@]}" enable "${SERVICE_NAME}.timer"
  systemctl "${SYSTEMCTL_OPTS[@]}" start "${SERVICE_NAME}.timer"
  echo "Timer enabled and started. Next run:"
  systemctl "${SYSTEMCTL_OPTS[@]}" list-timers "${SERVICE_NAME}.timer" --no-pager
else
  echo "Skipped enable/start. Run:"
  if [[ "$USER_MODE" == true ]]; then
    echo "  systemctl --user enable --now ${SERVICE_NAME}.timer"
  else
    echo "  sudo systemctl enable --now ${SERVICE_NAME}.timer"
  fi
fi

echo ""
echo "Logs: $LOG_FILE"
echo "Manual run: systemctl ${SYSTEMCTL_OPTS[*]} start ${SERVICE_NAME}.service"
