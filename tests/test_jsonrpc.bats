#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/mocks'

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_TEMP="$(mktemp -d)"
  setup_mocks

  SCRIPT_NAME="test-jsonrpc"
  LOG_FILE="$TEST_TEMP/test.log"
  export XDG_CACHE_HOME="$TEST_TEMP/cache"
  mkdir -p "$XDG_CACHE_HOME"
  # Test seams in lib/jsonrpc.sh: skip the system-websocat lookup, force arch,
  # and clear the explicit override so cache/download paths are exercised.
  export SCRIPT_NAME LOG_FILE XDG_CACHE_HOME
  export WEBSOCAT="" WEBSOCAT_SKIP_SYSTEM=1 WEBSOCAT_ARCH=aarch64

  source "$PROJECT_ROOT/lib/common.sh"
  source "$PROJECT_ROOT/lib/jsonrpc.sh"
}

teardown() {
  teardown_mocks
  rm -rf "$TEST_TEMP"
}

# Mock curl that records the call and writes a fake "websocat" binary to the
# -o target. Used by the download-path tests.
make_download_curl() {
  cat > "$MOCK_DIR/curl" <<'SCRIPT'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_CALLS_DIR/curl_calls"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    printf '#!/usr/bin/env bash\necho "websocat 1.14.1"\n' > "$2"
    shift 2
  else
    shift
  fi
done
SCRIPT
  chmod +x "$MOCK_DIR/curl"
}

# ── request building ─────────────────────────────────────────────────

@test "_jsonrpc_build_request builds a JSON-RPC 2.0 envelope" {
  req="$(_jsonrpc_build_request "foo.bar" '[{"a":1}]' 7)"
  assert_equal "$(printf '%s' "$req" | jq -r '.jsonrpc')" "2.0"
  assert_equal "$(printf '%s' "$req" | jq -r '.method')" "foo.bar"
  assert_equal "$(printf '%s' "$req" | jq -r '.id')" "7"
  assert_equal "$(printf '%s' "$req" | jq -c '.params')" '[{"a":1}]'
}

# ── websocat provisioning helpers ────────────────────────────────────

@test "_websocat_asset_name maps known arches and rejects unknown" {
  assert_equal "$(_websocat_asset_name aarch64)" "websocat.aarch64-unknown-linux-musl"
  assert_equal "$(_websocat_asset_name x86_64)" "websocat.x86_64-unknown-linux-musl"
  run _websocat_asset_name arm64
  assert_failure
}

@test "_websocat_download_url uses redirect for latest and tag for pinned" {
  assert_equal \
    "$(_websocat_download_url latest websocat.x)" \
    "https://github.com/vi/websocat/releases/latest/download/websocat.x"
  assert_equal \
    "$(_websocat_download_url v1.14.1 websocat.x)" \
    "https://github.com/vi/websocat/releases/download/v1.14.1/websocat.x"
}

@test "_websocat_sha256 returns embedded hash for known pin, empty otherwise" {
  assert_equal \
    "$(_websocat_sha256 v1.14.1 aarch64)" \
    "711a69576a2ff473fb01a90ffafb571c2ed019e55479d7ae71b12c2eadeb7011"
  assert_equal "$(_websocat_sha256 v9.9.9 aarch64)" ""
}

# ── resolve_websocat ─────────────────────────────────────────────────

@test "resolve_websocat returns the WEBSOCAT override directly" {
  WEBSOCAT="/custom/path/websocat"
  assert_equal "$(resolve_websocat)" "/custom/path/websocat"
}

@test "resolve_websocat reuses a matching cached binary without downloading" {
  cache="$XDG_CACHE_HOME/acme-deploy"
  mkdir -p "$cache"
  printf '#!/usr/bin/env bash\necho cached\n' > "$cache/websocat"
  chmod +x "$cache/websocat"
  echo "v1.14.1" > "$cache/websocat.version"
  WEBSOCAT_VERSION="v1.14.1"

  create_mock curl 0 ""   # should NOT be called

  result="$(resolve_websocat)"
  assert_equal "$result" "$cache/websocat"
  assert_equal "$(mock_call_count curl)" "0"
}

@test "resolve_websocat downloads the binary on cache miss (latest, no checksum)" {
  make_download_curl
  WEBSOCAT_VERSION="latest"

  result="$(resolve_websocat)"
  assert_equal "$result" "$XDG_CACHE_HOME/acme-deploy/websocat"
  [[ -x "$result" ]]
  assert_equal "$(mock_call_count curl)" "1"
  [[ -f "$XDG_CACHE_HOME/acme-deploy/websocat.version" ]]
}

@test "resolve_websocat re-downloads when WEBSOCAT_FORCE_DOWNLOAD=1" {
  cache="$XDG_CACHE_HOME/acme-deploy"
  mkdir -p "$cache"
  printf '#!/usr/bin/env bash\necho old\n' > "$cache/websocat"
  chmod +x "$cache/websocat"
  echo "old" > "$cache/websocat.version"
  make_download_curl
  WEBSOCAT_VERSION="latest"
  WEBSOCAT_FORCE_DOWNLOAD=1

  result="$(resolve_websocat)"
  assert_equal "$result" "$cache/websocat"
  assert_equal "$(mock_call_count curl)" "1"
}

@test "resolve_websocat verifies checksum for pinned version and fails on mismatch" {
  make_download_curl
  WEBSOCAT_VERSION="v1.14.1"   # has an embedded SHA256 for aarch64

  run resolve_websocat
  assert_failure
  assert_output --partial "checksum mismatch"
  [[ ! -e "$XDG_CACHE_HOME/acme-deploy/websocat.tmp" ]]
  [[ ! -e "$XDG_CACHE_HOME/acme-deploy/websocat" ]]
}

@test "resolve_websocat fails on an unsupported arch" {
  WEBSOCAT_ARCH="mips64"
  run resolve_websocat
  assert_failure
  assert_output --partial "No websocat build for arch"
}

# ── jsonrpc_call (via faked WS file descriptors) ─────────────────────
# Faking WS[0]/WS[1] with real file FDs avoids coproc/bash-version and
# pipe-buffering flakiness while still exercising the real jsonrpc_call
# code path: request build, write, read, id correlation, result/error/EOF.

@test "jsonrpc_call returns the result for a matching id and writes the request" {
  _JSONRPC_ID=0
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":42}' > "$TEST_TEMP/reply.in"
  exec {rfd}<"$TEST_TEMP/reply.in"
  exec {wfd}>"$TEST_TEMP/req.out"
  WS=("$rfd" "$wfd")

  result="$(jsonrpc_call "certificate.create" '[{"name":"x"}]')"

  exec {rfd}<&-
  exec {wfd}>&-
  assert_equal "$result" "42"
  assert_equal "$(jq -r '.method' "$TEST_TEMP/req.out")" "certificate.create"
  assert_equal "$(jq -r '.id' "$TEST_TEMP/req.out")" "1"
  assert_equal "$(jq -r '.params[0].name' "$TEST_TEMP/req.out")" "x"
}

@test "jsonrpc_call skips unsolicited frames until the matching id arrives" {
  _JSONRPC_ID=0
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":99,"result":"noise"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":42}'
  } > "$TEST_TEMP/reply.in"
  exec {rfd}<"$TEST_TEMP/reply.in"
  exec {wfd}>/dev/null
  WS=("$rfd" "$wfd")

  result="$(jsonrpc_call "foo" "[]")"
  exec {rfd}<&-
  exec {wfd}>&-
  assert_equal "$result" "42"
}

@test "jsonrpc_call returns failure on a JSON-RPC error reply" {
  _JSONRPC_ID=0
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"message":"boom"}}' > "$TEST_TEMP/reply.in"
  exec {rfd}<"$TEST_TEMP/reply.in"
  exec {wfd}>/dev/null
  WS=("$rfd" "$wfd")

  run jsonrpc_call "foo" "[]"
  exec {rfd}<&-
  exec {wfd}>&-
  assert_failure
  assert_output --partial "JSON-RPC error calling foo"
  assert_output --partial "boom"
}

@test "jsonrpc_call returns failure on EOF / closed socket" {
  _JSONRPC_ID=0
  : > "$TEST_TEMP/reply.in"   # empty -> immediate EOF
  exec {rfd}<"$TEST_TEMP/reply.in"
  exec {wfd}>/dev/null
  WS=("$rfd" "$wfd")

  run jsonrpc_call "foo" "[]"
  exec {rfd}<&-
  exec {wfd}>&-
  assert_failure
  assert_output --partial "WebSocket closed or timed out"
}

@test "jsonrpc_call tolerates no-reply when tolerate_no_reply=1" {
  # Simulates system.general.update: the server restarts and drops the socket
  # without replying. With tolerate_no_reply=1 this is success, not failure.
  _JSONRPC_ID=0
  : > "$TEST_TEMP/reply.in"   # empty -> immediate EOF
  exec {rfd}<"$TEST_TEMP/reply.in"
  exec {wfd}>/dev/null
  WS=("$rfd" "$wfd")

  run jsonrpc_call "system.general.update" "[]" 1
  exec {rfd}<&-
  exec {wfd}>&-
  assert_success
  assert_output --partial "No reply"
}