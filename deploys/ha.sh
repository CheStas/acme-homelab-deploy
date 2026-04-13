#!/bin/bash
# Deploy certificate to Home Assistant via SSH/SCP.

SCRIPT_NAME="ha"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/http.sh"
load_env
setup_error_handling
require_vars HA_HOST HA_USER HA_CERT_DIR SSH_KEY CERT KEY

log INFO "Uploading certificate to Home Assistant"
scp_logged "$CERT" "${HA_USER}@${HA_HOST}:${HA_CERT_DIR}/fullchain.pem"
scp_logged "$KEY"  "${HA_USER}@${HA_HOST}:${HA_CERT_DIR}/privkey.pem"

log INFO "Restarting Home Assistant core"
ssh_logged "${HA_USER}@${HA_HOST}" "ha core restart"
