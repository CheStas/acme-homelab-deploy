#!/bin/bash
# HTTP/SCP/SSH wrappers with logging and timeouts.
# Requires common.sh to be sourced first.

# ── HTTP request ────────────────────────────────────────────────────
# Usage: http_request METHOD URL [-H "Header: val"...] [--data "body"]
# Sets global HTTP_STATUS. Returns response body on stdout.

HTTP_STATUS=""

http_request() {
  local method="$1"
  local url="$2"
  shift 2

  local -a headers=()
  local data=""
  local -a extra_flags=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -H)       headers+=(-H "$2"); shift 2 ;;
      --data)   data="$2"; shift 2 ;;
      -F)       extra_flags+=(-F "$2"); shift 2 ;;
      -k)       extra_flags+=(-k); shift ;;
      *)        extra_flags+=("$1"); shift ;;
    esac
  done

  # Log request (mask Authorization header values)
  log INFO "HTTP $method $url"
  if [[ -n "$data" ]]; then
    log INFO "Request body: $data"
  fi

  local response_body
  local tmp_body
  tmp_body="$(mktemp)"

  local -a cmd=(
    curl -sS
    --connect-timeout "${CURL_TIMEOUT:-30}"
    --max-time "${CURL_MAX_TIME:-120}"
    -X "$method"
    "${headers[@]}"
    -w '%{http_code}'
    -o "$tmp_body"
  )

  if [[ -n "$data" ]]; then
    cmd+=(--data "$data")
  fi

  cmd+=("${extra_flags[@]}" "$url")

  local curl_exit=0
  HTTP_STATUS=$("${cmd[@]}") || curl_exit=$?

  response_body="$(cat "$tmp_body")"
  rm -f "$tmp_body"

  if [[ $curl_exit -ne 0 ]]; then
    log ERROR "HTTP $method $url failed (curl exit $curl_exit)"
    echo "$response_body"
    return $curl_exit
  fi

  # Truncate long responses for logging
  local log_body="$response_body"
  if [[ ${#log_body} -gt 500 ]]; then
    log_body="${log_body:0:500}...(truncated)"
  fi
  log INFO "HTTP $HTTP_STATUS response: $log_body"

  echo "$response_body"
}

# ── Convenience wrappers ────────────────────────────────────────────

http_get() {
  local url="$1"
  shift
  http_request GET "$url" "$@"
}

http_post() {
  local url="$1"
  shift
  http_request POST "$url" "$@"
}

http_put() {
  local url="$1"
  shift
  http_request PUT "$url" "$@"
}

http_delete() {
  local url="$1"
  shift
  http_request DELETE "$url" "$@"
}

# ── File upload via curl ────────────────────────────────────────────
# Usage: http_upload URL [-H "Header: val"...] -F "field=@file" ...

http_upload() {
  local url="$1"
  shift
  http_request POST "$url" "$@"
}

# ── SCP wrapper ─────────────────────────────────────────────────────
# Usage: scp_logged SOURCE DESTINATION

scp_logged() {
  local src="$1"
  local dest="$2"

  log INFO "SCP $src -> $dest"

  local output
  output=$(scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$src" "$dest" 2>&1) || {
    local exit_code=$?
    log ERROR "SCP failed (exit $exit_code): $output"
    return $exit_code
  }

  log INFO "SCP completed: $src -> $dest"
}

# ── SSH wrapper ─────────────────────────────────────────────────────
# Usage: ssh_logged USER@HOST COMMAND

ssh_logged() {
  local target="$1"
  local cmd="$2"

  log INFO "SSH $target: $cmd"

  local output
  output=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$target" "$cmd" 2>&1) || {
    local exit_code=$?
    log ERROR "SSH failed (exit $exit_code): $output"
    return $exit_code
  }

  log INFO "SSH completed ($target): $output"
}
