#!/usr/bin/env bash
# Deploy certificate to TrueNAS via REST API.
# Imports certificate, polls async job, binds to UI.

SCRIPT_NAME="truenas"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/http.sh"
load_env
setup_error_handling
require_vars TRUENAS_URL TRUENAS_API_KEY TRUENAS_CERT_PREFIX CERT KEY

AUTH_HEADER="Authorization: Bearer $TRUENAS_API_KEY"
CONTENT_TYPE="Content-Type: application/json"

FILE_DATE="$(date +%F-%H-%M)"
CERT_NAME="${TRUENAS_CERT_PREFIX}_${FILE_DATE}"

# Read cert/key contents with escaped newlines for JSON
CERT_DATA=$(sed ':a;N;$!ba;s/\n/\\n/g' "$CERT")
KEY_DATA=$(sed ':a;N;$!ba;s/\n/\\n/g' "$KEY")

# ── Import certificate ──────────────────────────────────────────────
log INFO "Importing certificate: $CERT_NAME"

RAW=$(http_post "$TRUENAS_URL/api/v2.0/certificate" \
  -H "$AUTH_HEADER" \
  -H "$CONTENT_TYPE" \
  -k \
  --data "{
    \"create_type\": \"CERTIFICATE_CREATE_IMPORTED\",
    \"name\": \"$CERT_NAME\",
    \"certificate\": \"$CERT_DATA\",
    \"privatekey\": \"$KEY_DATA\"
  }")

IMPORT_RESPONSE=$(parse_http_body "$RAW")
JOB_ID=$(echo "$IMPORT_RESPONSE" | jq -r 'if type=="number" or type=="string" then . else .id // empty end')

if [[ -z "$JOB_ID" ]]; then
  log ERROR "Failed to get job ID from import response"
  exit 1
fi

# ── Poll job until complete ─────────────────────────────────────────
log INFO "Waiting for import job $JOB_ID to complete"

MAX_POLL=30
POLL_INTERVAL=2

for ((i = 1; i <= MAX_POLL; i++)); do
  RAW=$(http_get "$TRUENAS_URL/api/v2.0/core/get_jobs?id=$JOB_ID" \
    -H "$AUTH_HEADER" -k)

  JOB_RESPONSE=$(parse_http_body "$RAW")
  JOB_STATE=$(echo "$JOB_RESPONSE" | jq -r '.[0].state // "UNKNOWN"')

  case "$JOB_STATE" in
    SUCCESS)
      log INFO "Import job $JOB_ID completed successfully"
      break
      ;;
    FAILED)
      JOB_ERROR=$(echo "$JOB_RESPONSE" | jq -r '.[0].error // "unknown error"')
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

# ── Look up certificate ID ──────────────────────────────────────────
log INFO "Looking up certificate ID for $CERT_NAME"

RAW=$(http_get "$TRUENAS_URL/api/v2.0/certificate" \
  -H "$AUTH_HEADER" -k)

CERTS_RESPONSE=$(parse_http_body "$RAW")
CERT_ID=$(echo "$CERTS_RESPONSE" | jq -r \
  ".[] | select(.name==\"$CERT_NAME\") | .id" | tail -n1)

if [[ -z "$CERT_ID" ]]; then
  log ERROR "Certificate '$CERT_NAME' not found after import"
  exit 1
fi

# ── Bind certificate to UI ──────────────────────────────────────────
log INFO "Binding certificate ID $CERT_ID to TrueNAS UI"

RAW=$(http_put "$TRUENAS_URL/api/v2.0/system/general" \
  -H "$AUTH_HEADER" \
  -H "$CONTENT_TYPE" \
  -k \
  --data "{\"ui_certificate\": $CERT_ID}")

BIND_STATUS=$(parse_http_status "$RAW")

if [[ "$BIND_STATUS" != "200" ]]; then
  log ERROR "Failed to bind certificate (HTTP $BIND_STATUS)"
  exit 1
fi

log INFO "Certificate $CERT_NAME (ID $CERT_ID) bound to TrueNAS UI"
