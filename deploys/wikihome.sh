#!/bin/bash
# Deploy certificate to Wikihome (Node-RED) via SSH/SCP.

SCRIPT_NAME="wikihome"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/common.sh"
source "$PROJECT_ROOT/lib/http.sh"
load_env
setup_error_handling
require_vars WIKIHOME_HOST WIKIHOME_USER WIKIHOME_CERT_DIR WIKIHOME_RESTART_CMD SSH_KEY CERT KEY

log INFO "Uploading certificate to Wikihome"
scp_logged "$CERT" "${WIKIHOME_USER}@${WIKIHOME_HOST}:${WIKIHOME_CERT_DIR}/fullchain.pem"
scp_logged "$KEY"  "${WIKIHOME_USER}@${WIKIHOME_HOST}:${WIKIHOME_CERT_DIR}/privkey.pem"

log INFO "Restarting Node-RED"
ssh_logged "${WIKIHOME_USER}@${WIKIHOME_HOST}" "$WIKIHOME_RESTART_CMD"
