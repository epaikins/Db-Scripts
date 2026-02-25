#!/usr/bin/env bash
# Send a notification to a Microsoft Teams channel via Incoming Webhook.
# Set TEAMS_WEBHOOK_URL in config.env (or env). If unset, no-op.
# Usage (sourced):  notify_teams "Title" "Body text" [success|failure]
# Usage (script):   TEAMS_WEBHOOK_URL=... ./notify-teams.sh "Title" "Body" [success|failure]

set -euo pipefail

notify_teams() {
  local title="${1:-}"
  local body="${2:-}"
  local status="${3:-success}"
  local webhook="${TEAMS_WEBHOOK_URL:-}"

  [[ -z "$webhook" ]] && return 0
  [[ "$webhook" != https://* ]] && return 0

  # Plain text message (avoids JSON escaping issues)
  local msg
  msg="$title"$'\n\n'"$body"

  # Minimal JSON: "text" is required by Teams webhooks (use python3 for safe escaping)
  local payload
  if ! payload=$(printf '%s' "$msg" | python3 -c "import sys,json; print(json.dumps({'text': sys.stdin.read()}))" 2>/dev/null); then
    payload="{\"text\": \"Backup/restore notification\"}"
  fi
  [[ -z "$payload" ]] && return 0

  if command -v curl &>/dev/null; then
    curl -sf -X POST -H "Content-Type: application/json" -d "$payload" "$webhook" || true
  elif command -v wget &>/dev/null; then
    wget -q -O /dev/null --post-data="$payload" --header="Content-Type: application/json" "$webhook" || true
  fi
}

# When run as script: notify_teams "$1" "$2" "${3:-success}"
if [[ "${BASH_SOURCE[0]:-}" != "${0:-}" ]]; then
  : # sourced, notify_teams is available
else
  [[ $# -ge 2 ]] || { echo "Usage: $0 \"Title\" \"Body\" [success|failure]"; exit 0; }
  notify_teams "$1" "$2" "${3:-success}"
fi
