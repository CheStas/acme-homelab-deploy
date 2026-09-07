#!/usr/bin/env bash
# Deploy certificate to TrueNAS via JSON-RPC 2.0 over WebSocket.
# Imports certificate, polls the async job, binds it to the web UI.
#
# This replaces the deprecated REST API (/api/v2.0), which TrueNAS removes
# in 26.04. The replacement is JSON-RPC 2.0 over WebSocket at /api/current.

SCRIPT_NAME="truenas"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/jsonrpc.sh"
load_env
setup_error_handling
require_vars TRUENAS_URL TRUENAS_API_KEY TRUENAS_CERT_PREFIX CERT KEY

# Close the WebSocket on any exit (success or failure). This replaces
# common.sh's generic EXIT trap so the websocat coproc never leaks.
_exit_cleanup_truenas() {
  local ec=$?
  jsonrpc_close 2>/dev/null || true
  if [[ $ec -eq 0 && $_HAD_ERROR -eq 0 ]]; then
    log INFO "ENDED successfully"
  else
    log ERROR "ENDED with failure (exit code $ec)"
  fi
}
trap '_exit_cleanup_truenas' EXIT

# Derive the WebSocket URL from the REST base URL (https:// -> wss://).
# Preserves any explicit :port. $TRUENAS_URL is e.g. https://192.168.1.1
TRUENAS_WS_URL="wss://${TRUENAS_URL#https://}/api/current"

FILE_DATE="$(date +%F-%H-%M)"
CERT_NAME="${TRUENAS_CERT_PREFIX}_${FILE_DATE}"

# Read raw cert/key contents; jq escapes them safely when building params
# (replaces the prior sed newline-escape hack).
CERT_DATA="$(cat "$CERT")"
KEY_DATA="$(cat "$KEY")"

jsonrpc_open "$TRUENAS_WS_URL" "$TRUENAS_API_KEY"

# ── Import certificate ──────────────────────────────────────────────
log INFO "Importing certificate: $CERT_NAME"

IMPORT_PARAMS="$(jq -nc \
  --arg name "$CERT_NAME" \
  --arg cert "$CERT_DATA" \
  --arg key "$KEY_DATA" \
  '[{create_type:"CERTIFICATE_CREATE_IMPORTED", name:$name, certificate:$cert, privatekey:$key}]')"

JOB_ID="$(jsonrpc_call "certificate.create" "$IMPORT_PARAMS")"

if [[ -z "$JOB_ID" ]]; then
  log ERROR "Failed to get job ID from certificate.create"
  exit 1
fi
log INFO "Import job started: $JOB_ID"

# ── Poll job until complete ─────────────────────────────────────────
log INFO "Waiting for import job $JOB_ID to complete"

MAX_POLL=30
POLL_INTERVAL=2
CERT_ID=""

for ((i = 1; i <= MAX_POLL; i++)); do
  JOB_PARAMS="$(jq -nc --argjson j "$JOB_ID" '[[["id","=",$j]]]')"
  JOB_RESULT="$(jsonrpc_call "core.get_jobs" "$JOB_PARAMS")"
  JOB_STATE="$(printf '%s' "$JOB_RESULT" | jq -r '.[0].state // "UNKNOWN"')"

  case "$JOB_STATE" in
    SUCCESS)
      log INFO "Import job $JOB_ID completed successfully"
      # For an imported cert the job result is the full certificate object;
      # for other create types it may be the bare id. Handle both.
      CERT_ID="$(printf '%s' "$JOB_RESULT" | jq -r \
        '.[0].result | (if type=="object" then .id else . end) // empty')"
      break
      ;;
    FAILED)
      JOB_ERROR="$(printf '%s' "$JOB_RESULT" | jq -r '.[0].error // "unknown error"')"
      log ERROR "Import job $JOB_ID failed: $JOB_ERROR"
      exit 1
      ;;
    RUNNING|WAITING)
      log INFO "Job $JOB_ID state: $JOB_STATE (attempt $i/$MAX_POLL)"
      sleep "$POLL_INTERVAL"
      ;;
    *)
      log WARN "Job $JOB_ID unexpected state: $JOB_STATE (attempt $i/$MAX_POLL)"
      sleep "$POLL_INTERVAL"
      ;;
  esac

  if [[ $i -eq $MAX_POLL ]]; then
    log ERROR "Timed out waiting for job $JOB_ID (state: $JOB_STATE)"
    exit 1
  fi
done

# ── Resolve certificate ID (fallback if the job result didn't carry it)
if [[ -z "$CERT_ID" ]]; then
  log INFO "Looking up certificate ID for $CERT_NAME"
  QUERY_PARAMS="$(jq -nc --arg n "$CERT_NAME" '[[["name","=",$n]]]')"
  QUERY_RESULT="$(jsonrpc_call "certificate.query" "$QUERY_PARAMS")"
  CERT_ID="$(printf '%s' "$QUERY_RESULT" | jq -r '.[-1].id // empty')"
fi

if [[ -z "$CERT_ID" ]]; then
  log ERROR "Certificate '$CERT_NAME' ID not found after import"
  exit 1
fi

# ── Bind certificate to UI ──────────────────────────────────────────
# system.general.update changing ui_certificate restarts the web UI, which
# drops the WebSocket without sending a reply. So we tolerate no-reply here
# (only a real JSON-RPC error is a failure) and verify the bind afterwards by
# reconnecting and reading system.general.config.
log INFO "Binding certificate ID $CERT_ID to TrueNAS UI"

BIND_PARAMS="$(jq -nc --argjson id "$CERT_ID" '[{ui_certificate:$id}]')"
JSONRPC_READ_TIMEOUT=8 jsonrpc_call "system.general.update" "$BIND_PARAMS" 1 >/dev/null || {
  log ERROR "system.general.update rejected certificate ID $CERT_ID"
  exit 1
}
jsonrpc_close

# Reconnect (the UI is restarting) and confirm the active UI certificate.
# A middleware restart can take a while, so retry generously.
UI_RESTART_RETRIES="${UI_RESTART_RETRIES:-10}"
UI_RESTART_INTERVAL="${UI_RESTART_INTERVAL:-3}"
_UI_VERIFIED=0
for ((v = 1; v <= UI_RESTART_RETRIES; v++)); do
  jsonrpc_close 2>/dev/null || true
  if jsonrpc_open "$TRUENAS_WS_URL" "$TRUENAS_API_KEY" 2>/dev/null; then
    CFG="$(jsonrpc_call "system.general.config" "[]")" && {
      UI_CERT="$(printf '%s' "$CFG" | jq -r '.ui_certificate // empty')"
      if [[ "$UI_CERT" == "$CERT_ID" ]]; then
        log INFO "Verified: UI certificate is $CERT_ID"
        _UI_VERIFIED=1
        break
      fi
      log WARN "UI certificate is ${UI_CERT:-unset}, expected $CERT_ID (attempt $v/$UI_RESTART_RETRIES)"
    }
  fi
  log INFO "Waiting for TrueNAS web UI to come back (attempt $v/$UI_RESTART_RETRIES)"
  sleep "$UI_RESTART_INTERVAL"
done

if [[ "$_UI_VERIFIED" == "1" ]]; then
  log INFO "Certificate $CERT_NAME (ID $CERT_ID) bound to TrueNAS UI"
else
  log WARN "Certificate $CERT_NAME imported (ID $CERT_ID); UI binding could not be confirmed (UI may still be restarting) — verify in the TrueNAS UI."
fi