#!/usr/bin/env bash
# Shared library: logging, env loading, error handling
# Source this file from every deploy script.

# ── Project root detection ──────────────────────────────────────────
# Works regardless of the caller's working directory or symlinks.
_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$_COMMON_DIR/.." && pwd)"

# ── Script identity ─────────────────────────────────────────────────
# Each script should set SCRIPT_NAME before sourcing common.sh.
# Fallback: derive from $0.
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0" .sh)}"

# ── Logging ─────────────────────────────────────────────────────────
# Format: [ISO-8601] [SCRIPT_NAME] [LEVEL] message
# Outputs to stderr (console) and appends to LOG_FILE.

log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp="$(date -Is)"
  local line="[$timestamp] [$SCRIPT_NAME] [$level] $message"

  echo "$line" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$line" >> "$LOG_FILE"
  fi
}

log_section_start() {
  local separator="========================================================================"
  local timestamp
  timestamp="$(date -Is)"
  local block
  block=$(printf '%s\n[%s] [deploy-all] [INFO] DEPLOYMENT RUN STARTED\n%s' \
    "$separator" "$timestamp" "$separator")

  echo "$block" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$block" >> "$LOG_FILE"
  fi
}

log_section_end() {
  local status="$1"
  local separator="========================================================================"
  local timestamp
  timestamp="$(date -Is)"
  local block
  block=$(printf '%s\n[%s] [deploy-all] [INFO] DEPLOYMENT RUN %s\n%s' \
    "$separator" "$timestamp" "$status" "$separator")

  echo "$block" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$block" >> "$LOG_FILE"
  fi
}

# ── Environment loading ─────────────────────────────────────────────
# Sources .env and .env.secret, derives CERT and KEY full paths.

load_env() {
  local env_file="$PROJECT_ROOT/.env"
  local secret_file="$PROJECT_ROOT/.env.secret"

  if [[ ! -f "$env_file" ]]; then
    log ERROR "Missing config file: $env_file"
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$env_file"

  if [[ -f "$secret_file" ]]; then
    # shellcheck source=/dev/null
    source "$secret_file"
  else
    log WARN "Missing secrets file: $secret_file (some deploys may fail)"
  fi

  # Derive full cert/key paths
  CERT="${CERT_DIR}/${CERT_FILE}"
  KEY="${CERT_DIR}/${KEY_FILE}"

  # Resolve LOG_FILE (uses PROJECT_ROOT which is now set)
  LOG_FILE="${LOG_FILE:-$PROJECT_ROOT/deploy.log}"

  export CERT KEY LOG_FILE
}

# ── Variable validation ─────────────────────────────────────────────
# Usage: require_vars VAR1 VAR2 VAR3

require_vars() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log ERROR "Missing required variables: ${missing[*]}"
    exit 1
  fi
}

# ── Error handling ──────────────────────────────────────────────────
# Traps ERR and EXIT to log failures automatically.
# Call setup_error_handling() after load_env.

_HAD_ERROR=0

_error_trap() {
  _HAD_ERROR=1
  local exit_code=$?
  local line_number="${BASH_LINENO[0]}"
  log ERROR "Failed at line $line_number (exit code $exit_code)"
}

_exit_trap() {
  local exit_code=$?
  if [[ $exit_code -eq 0 && $_HAD_ERROR -eq 0 ]]; then
    log INFO "ENDED successfully"
  else
    log ERROR "ENDED with failure (exit code $exit_code)"
  fi
}

setup_error_handling() {
  set -euo pipefail
  trap '_error_trap' ERR
  trap '_exit_trap' EXIT
  log INFO "STARTED"
}
