#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'helpers/mocks'

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_TEMP="$(mktemp -d)"
  setup_mocks

  SCRIPT_NAME="test-http"
  LOG_FILE="$TEST_TEMP/test.log"
  CURL_TIMEOUT=5
  CURL_MAX_TIME=10
  SSH_KEY="/tmp/test-key"
  export SCRIPT_NAME LOG_FILE CURL_TIMEOUT CURL_MAX_TIME SSH_KEY

  source "$PROJECT_ROOT/lib/common.sh"
  source "$PROJECT_ROOT/lib/http.sh"
}

teardown() {
  teardown_mocks
  rm -rf "$TEST_TEMP"
}

# ── http_request tests ──────────────────────────────────────────────

@test "http_request calls curl with timeout flags" {
  # Mock curl to return status 200 and write body to -o target
  cat > "$MOCK_DIR/curl" <<'SCRIPT'
#!/usr/bin/env bash
# Find -o argument and write response body there
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    echo '{"ok":true}' > "$2"
    shift 2
  else
    shift
  fi
done
echo "200"
SCRIPT
  chmod +x "$MOCK_DIR/curl"

  run http_request GET "http://test.local/api"
  assert_success
  assert_output --partial '{"ok":true}'

  # Check log contains request
  run cat "$TEST_TEMP/test.log"
  assert_output --partial "HTTP GET http://test.local/api"
  assert_output --partial "HTTP 200 response"
}

@test "http_request logs request body" {
  cat > "$MOCK_DIR/curl" <<'SCRIPT'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    echo '{}' > "$2"
    shift 2
  else
    shift
  fi
done
echo "201"
SCRIPT
  chmod +x "$MOCK_DIR/curl"

  run http_request POST "http://test.local/api" --data '{"name":"test"}'
  assert_success

  run cat "$TEST_TEMP/test.log"
  assert_output --partial 'Request body: {"name":"test"}'
}

@test "http_request returns failure on curl error" {
  cat > "$MOCK_DIR/curl" <<'SCRIPT'
#!/usr/bin/env bash
exit 7
SCRIPT
  chmod +x "$MOCK_DIR/curl"

  run http_request GET "http://unreachable.local"
  assert_failure

  run cat "$TEST_TEMP/test.log"
  assert_output --partial "failed (curl exit 7)"
}

# ── scp_logged tests ────────────────────────────────────────────────

@test "scp_logged calls scp and logs" {
  create_mock scp 0 ""

  run scp_logged "/tmp/cert.pem" "user@host:/ssl/cert.pem"
  assert_success

  run cat "$TEST_TEMP/test.log"
  assert_output --partial "SCP /tmp/cert.pem -> user@host:/ssl/cert.pem"
  assert_output --partial "SCP completed"

  count=$(mock_call_count scp)
  assert_equal "$count" "1"
}

@test "scp_logged logs failure" {
  create_mock scp 1 "connection refused"

  run scp_logged "/tmp/cert.pem" "user@host:/ssl/cert.pem"
  assert_failure

  run cat "$TEST_TEMP/test.log"
  assert_output --partial "SCP failed"
}

# ── ssh_logged tests ────────────────────────────────────────────────

@test "ssh_logged calls ssh and logs" {
  create_mock ssh 0 "service restarted"

  run ssh_logged "user@host" "systemctl restart myservice"
  assert_success

  run cat "$TEST_TEMP/test.log"
  assert_output --partial 'SSH user@host: systemctl restart myservice'
  assert_output --partial "SSH completed"
}

@test "ssh_logged logs failure" {
  create_mock ssh 255 "connection timed out"

  run ssh_logged "user@host" "some command"
  assert_failure

  run cat "$TEST_TEMP/test.log"
  assert_output --partial "SSH failed"
}
