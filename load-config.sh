#!/usr/bin/env bash
# Safe config loader: reads config.env without interpreting special chars in values.
# Use: source load-config.sh  (then call load_config_env)
# Or: source load-config.sh && load_config_env

load_config_env() {
  local file="${1:-config.env}"
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    # First = separates key from value (value may contain =)
    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    # Remove one layer of surrounding quotes so we re-quote safely
    if [[ "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
    if [[ "$value" == \"*\" ]]; then value="${value:1:${#value}-2}"; fi
    [[ -n "$key" ]] || continue
    # Export with value safely quoted (handles ' " $ ( ) etc)
    eval "export $(printf '%s=%q' "$key" "$value")"
  done < "$file"
  return 0
}
