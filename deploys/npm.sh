#!/bin/bash
# Deploy certificate to Nginx Proxy Manager via REST API.
# Creates certificate, uploads files, updates proxy hosts, cleans up old certs.

SCRIPT_NAME="npm"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/http.sh"
load_env
setup_error_handling
require_vars NPM_URL NPM_EMAIL NPM_PASSWORD CERT KEY

# Parse space-separated domains into array
IFS=' ' read -ra DOMAINS <<< "$NPM_DOMAINS"

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  log ERROR "NPM_DOMAINS is empty, nothing to deploy"
  exit 1
fi

# ── Authenticate ────────────────────────────────────────────────────
log INFO "Authenticating with NPM"

AUTH_RESPONSE=$(http_post "$NPM_URL/api/tokens" \
  -H "Content-Type: application/json" \
  --data "{
    \"identity\": \"$NPM_EMAIL\",
    \"secret\": \"$NPM_PASSWORD\"
  }")

TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.token')

if [[ "$TOKEN" == "null" || -z "$TOKEN" ]]; then
  log ERROR "Authentication failed"
  exit 1
fi

log INFO "Authenticated successfully"

# ── Create certificate entry ────────────────────────────────────────
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
log INFO "Creating certificate entry: uploaded-by-acme.sh-$TIMESTAMP"

CREATE_RESPONSE=$(http_post "$NPM_URL/api/nginx/certificates" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data "{
    \"provider\": \"other\",
    \"nice_name\": \"uploaded-by-acme.sh-$TIMESTAMP\"
  }")

NEW_CERT_ID=$(echo "$CREATE_RESPONSE" | jq -r '.id')

if [[ -z "$NEW_CERT_ID" || "$NEW_CERT_ID" == "null" ]]; then
  log ERROR "Failed to create certificate entry"
  exit 1
fi

log INFO "Created certificate ID: $NEW_CERT_ID"

# ── Upload certificate files ───────────────────────────────────────
log INFO "Uploading certificate files"

UPLOAD_RESPONSE=$(http_upload "$NPM_URL/api/nginx/certificates/$NEW_CERT_ID/upload" \
  -H "Authorization: Bearer $TOKEN" \
  -F "certificate=@$CERT" \
  -F "certificate_key=@$KEY")

if [[ "$HTTP_STATUS" != "200" ]]; then
  log ERROR "Certificate upload failed (HTTP $HTTP_STATUS)"
  exit 1
fi

log INFO "Certificate files uploaded"

# ── Fetch proxy hosts ──────────────────────────────────────────────
log INFO "Fetching proxy hosts"

PROXIES=$(http_get "$NPM_URL/api/nginx/proxy-hosts" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json")

# ── Update matching proxy hosts ─────────────────────────────────────
for DOMAIN in "${DOMAINS[@]}"; do
  log INFO "Updating proxy for $DOMAIN"

  PROXY=$(echo "$PROXIES" | jq -r \
    ".[] | select(.domain_names[] == \"$DOMAIN\")")

  if [[ -z "$PROXY" ]]; then
    log WARN "No proxy found for $DOMAIN, skipping"
    continue
  fi

  PROXY_ID=$(echo "$PROXY" | jq -r '.id')
  OLD_CERT_ID=$(echo "$PROXY" | jq -r '.certificate_id')

  UPDATED_PROXY=$(echo "$PROXY" | jq \
    --argjson cert_id "$NEW_CERT_ID" \
    '{
      domain_names,
      forward_host,
      forward_port,
      access_list_id,
      certificate_id: $cert_id,
      ssl_forced: true
    }')

  log INFO "Updating proxy $PROXY_ID with certificate $NEW_CERT_ID"

  UPDATE_RESPONSE=$(http_put "$NPM_URL/api/nginx/proxy-hosts/$PROXY_ID" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data "$UPDATED_PROXY")

  if [[ "$HTTP_STATUS" != "200" ]]; then
    log ERROR "Failed to update proxy $PROXY_ID (HTTP $HTTP_STATUS)"
    exit 1
  fi

  log INFO "Proxy $PROXY_ID updated"

  # ── Delete old cert if unused ──────────────────────────────────
  if [[ "$OLD_CERT_ID" != "null" && -n "$OLD_CERT_ID" ]]; then
    log INFO "Checking if old certificate $OLD_CERT_ID is still in use"

    CURRENT_PROXIES=$(http_get "$NPM_URL/api/nginx/proxy-hosts" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json")

    STILL_USED=$(echo "$CURRENT_PROXIES" | \
      jq "[.[] | select(.certificate_id == $OLD_CERT_ID)] | length")

    if [[ "$STILL_USED" -eq 0 ]]; then
      log INFO "Deleting unused certificate $OLD_CERT_ID"
      http_delete "$NPM_URL/api/nginx/certificates/$OLD_CERT_ID" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" || true
    else
      log INFO "Certificate $OLD_CERT_ID still used by $STILL_USED proxy host(s)"
    fi
  fi
done

log INFO "NPM deployment completed"
