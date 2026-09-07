#!/usr/bin/env bash
# JSON-RPC 2.0 over WebSocket client for TrueNAS, via websocat.
# Requires common.sh to be sourced first.
#
# The deprecated REST API (/api/v2.0) is removed in TrueNAS 26.04; the
# supported replacement is JSON-RPC 2.0 over WebSocket at /api/current.
# Authentication uses auth.login_with_api_key (plain API-key mechanism),
# which TrueNAS still accepts on 25.10 and 26.x (SCRAM is the default on
# 26+ but plain remains server-supported; it is no worse than the previous
# Bearer-header REST auth, which also sent the raw key over TLS).

# ── websocat binary provisioning ────────────────────────────────────
# No binary is committed to the repo. resolve_websocat locates one via:
#   1. $WEBSOCAT          - explicit override (e.g. nix devShell websocat)
#   2. `command -v websocat` - system install
#   3. cache (~/.cache/acme-deploy/websocat) - reused if version matches
#   4. download - fetch the static musl binary from GitHub releases
# Update to the latest release with WEBSOCAT_FORCE_DOWNLOAD=1, or pin a
# specific release with WEBSOCAT_VERSION=v1.14.1.

# SHA256 of known-good pinned builds (aarch64 only; x86_64 uses nix/dev).
_websocat_sha256() { # <version> <arch> -> sha256 or empty
  case "$1:$2" in
    v1.14.1:aarch64)
      printf '711a69576a2ff473fb01a90ffafb571c2ed019e55479d7ae71b12c2eadeb7011' ;;
    *) printf '' ;;
  esac
}

# Map uname -m to the websocat release asset name.
_websocat_asset_name() { # <arch> -> asset name (or fail)
  case "$1" in
    aarch64) printf 'websocat.aarch64-unknown-linux-musl' ;;
    x86_64)  printf 'websocat.x86_64-unknown-linux-musl' ;;
    *) return 1 ;;
  esac
}

# Build the GitHub release download URL for a version + asset.
_websocat_download_url() { # <version> <asset>
  if [[ "$1" == "latest" ]]; then
    printf 'https://github.com/vi/websocat/releases/latest/download/%s' "$2"
  else
    printf 'https://github.com/vi/websocat/releases/download/%s/%s' "$1" "$2"
  fi
}

# Portable SHA256 of a file (sha256sum on Linux, shasum on macOS).
_sha256_of_file() { # <path>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

resolve_websocat() {
  # 1. explicit override
  if [[ -n "${WEBSOCAT:-}" ]]; then
    printf '%s\n' "$WEBSOCAT"
    return 0
  fi

  # 2. system install (e.g. provided by `nix develop`)
  local sys
  if [[ "${WEBSOCAT_SKIP_SYSTEM:-0}" != "1" ]]; then
    sys="$(command -v websocat 2>/dev/null || true)"
    if [[ -n "$sys" ]]; then
      log INFO "Using system websocat: $sys"
      printf '%s\n' "$sys"
      return 0
    fi
  fi

  local arch version cache_dir bin_path ver_path
  arch="${WEBSOCAT_ARCH:-$(uname -m)}"
  version="${WEBSOCAT_VERSION:-latest}"
  cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/acme-deploy"
  bin_path="$cache_dir/websocat"
  ver_path="$cache_dir/websocat.version"

  # 3. cached + version match + not forced
  if [[ -x "$bin_path" && "${WEBSOCAT_FORCE_DOWNLOAD:-0}" != "1" ]]; then
    local cached_ver=""
    [[ -f "$ver_path" ]] && cached_ver="$(cat "$ver_path")"
    if [[ "$version" == "latest" || "$version" == "$cached_ver" ]]; then
      log INFO "Using cached websocat: $bin_path (${cached_ver:-unknown version})"
      printf '%s\n' "$bin_path"
      return 0
    fi
  fi

  # 4. download the static musl binary
  local asset url tmp_path
  asset="$(_websocat_asset_name "$arch")" || {
    log ERROR "No websocat build for arch '$arch' (need aarch64 or x86_64)"
    return 1
  }
  url="$(_websocat_download_url "$version" "$asset")"
  mkdir -p "$cache_dir"
  tmp_path="$cache_dir/websocat.tmp"

  log INFO "Downloading websocat $version ($arch) from $url"
  if ! curl -sSL --fail \
       --connect-timeout "${CURL_TIMEOUT:-30}" --max-time 300 \
       -o "$tmp_path" "$url"; then
    rm -f "$tmp_path"
    log ERROR "Failed to download websocat from $url"
    return 1
  fi

  # Verify checksum for pinned versions; for `latest` we cannot know the
  # SHA ahead of time, so we trust GitHub's TLS and log that it's unchecked.
  local expected
  expected="$(_websocat_sha256 "$version" "$arch")"
  if [[ -n "$expected" ]]; then
    local actual
    actual="$(_sha256_of_file "$tmp_path")"
    if [[ "$actual" != "$expected" ]]; then
      rm -f "$tmp_path"
      log ERROR "websocat checksum mismatch (expected $expected, got $actual)"
      return 1
    fi
    log INFO "websocat checksum verified"
  else
    log WARN "websocat checksum not verified for $version (no embedded SHA256; trusting GitHub TLS)"
  fi

  chmod +x "$tmp_path"
  mv -f "$tmp_path" "$bin_path"

  if [[ "$version" == "latest" ]]; then
    "$bin_path" --version 2>/dev/null | head -n1 > "$ver_path" || echo "latest" > "$ver_path"
  else
    printf '%s\n' "$version" > "$ver_path"
  fi

  log INFO "websocat installed to $bin_path"
  printf '%s\n' "$bin_path"
}

# ── JSON-RPC over WebSocket ─────────────────────────────────────────
# Uses a bash coproc named WS driving websocat in line mode (one stdin
# line = one WebSocket text message). Requires bash 4+ for coproc.

_JSONRPC_ID=0
_JSONRPC_BIN=""

# Build a JSON-RPC 2.0 request string. <method> <params_json> <id>
_jsonrpc_build_request() {
  jq -nc --arg m "$1" --argjson p "$2" --argjson id "$3" \
    '{jsonrpc:"2.0", id:$id, method:$m, params:$p}'
}

# Open the WebSocket and authenticate. <ws_url> <api_key>
jsonrpc_open() {
  local ws_url="$1" api_key="$2"

  _JSONRPC_BIN="$(resolve_websocat)" || return 1

  log INFO "Opening WebSocket to $ws_url"
  coproc WS { "$_JSONRPC_BIN" -q --insecure "$ws_url"; }
  if [[ -z "${WS[0]:-}" || -z "${WS[1]:-}" ]]; then
    log ERROR "Failed to start websocat coproc"
    return 1
  fi

  _JSONRPC_ID=0

  local login_params
  login_params="$(jq -nc --arg k "$api_key" '[$k]')"
  jsonrpc_call "auth.login_with_api_key" "$login_params" >/dev/null || {
    log ERROR "TrueNAS authentication failed (auth.login_with_api_key)"
    return 1
  }
  log INFO "Authenticated to TrueNAS"
}

# Call a JSON-RPC method. <method> <params_json> [tolerate_no_reply]
# Params must be a raw JSON value (array for positional params), e.g.
#   '[{"name":"x"}]'  or  '[[["id","=",1]]]'
# On success, prints .result (as JSON) to stdout and returns 0.
# A JSON-RPC .error reply always logs and returns 1.
# If the read loop ends without a matching reply (connection closed or
# timeout), this is normally a failure — UNLESS tolerate_no_reply is "1",
# in which case it returns 0. Use tolerate_no_reply for calls (such as
# system.general.update changing the UI certificate) that restart the API
# and drop the WebSocket without replying.
jsonrpc_call() {
  local method="$1" params="$2" tolerate="${3:-0}"

  if [[ -z "${WS[0]:-}" || -z "${WS[1]:-}" ]]; then
    log ERROR "jsonrpc_call '$method' with no open WebSocket"
    return 1
  fi

  _JSONRPC_ID=$((_JSONRPC_ID + 1))
  local id="$_JSONRPC_ID"

  local req
  req="$(_jsonrpc_build_request "$method" "$params" "$id")" || {
    log ERROR "Failed to build JSON-RPC request for $method"
    return 1
  }
  printf '%s\n' "$req" >&"${WS[1]}"

  local line rid
  while IFS= read -r -t "${JSONRPC_READ_TIMEOUT:-30}" line <&"${WS[0]}"; do
    [[ -z "$line" ]] && continue
    rid="$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null)" || continue
    [[ "$rid" != "$id" ]] && continue   # unsolicited/notification: ignore

    if printf '%s' "$line" | jq -e '.error' >/dev/null 2>&1; then
      local errmsg
      errmsg="$(printf '%s' "$line" | jq -r '.error | (.message // (.reason // tostring))' 2>/dev/null || true)"
      log ERROR "JSON-RPC error calling $method: ${errmsg:-unknown}"
      return 1
    fi
    printf '%s' "$line" | jq -cj '.result // empty'
    printf '\n'
    return 0
  done

  if [[ "$tolerate" == "1" ]]; then
    log WARN "No reply to $method (connection dropped — expected if the call restarts the API)"
    return 0
  fi
  log ERROR "WebSocket closed or timed out waiting for reply to $method (id=$id)"
  return 1
}

# Close the WebSocket. Idempotent.
jsonrpc_close() {
  if [[ -n "${WS[1]:-}" ]]; then
    # Short timeout: if the connection is already dead (e.g. after a UI
    # restart), don't hang here waiting for a logout reply.
    JSONRPC_READ_TIMEOUT=2 jsonrpc_call "auth.logout" "[]" >/dev/null 2>&1 || true
    eval "exec ${WS[1]}>&-" 2>/dev/null || true
    WS[1]=""
  fi
  wait 2>/dev/null || true
}