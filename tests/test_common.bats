#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  TEST_TEMP="$(mktemp -d)"
  # Create a minimal project structure for testing
  mkdir -p "$TEST_TEMP/lib" "$TEST_TEMP/deploys"
  cp "$PROJECT_ROOT/lib/common.sh" "$TEST_TEMP/lib/common.sh"

  # Create minimal .env
  cat > "$TEST_TEMP/.env" <<'ENV'
CERT_DIR="/tmp/test-certs"
CERT_FILE="fullchain.pem"
KEY_FILE="privkey.pem"
SSH_KEY="/tmp/test-key"
CURL_TIMEOUT=5
CURL_MAX_TIME=10
HA_HOST="test-ha"
HA_USER="root"
HA_CERT_DIR="/ssl"
TRUENAS_URL="https://test-truenas"
TRUENAS_CERT_PREFIX="test"
NPM_URL="http://test-npm:30020"
NPM_EMAIL="test@test.com"
NPM_DOMAINS="test.example.com"
WIKIHOME_HOST="test-wiki"
WIKIHOME_USER="test"
WIKIHOME_CERT_DIR="/etc/certs"
WIKIHOME_RESTART_CMD="echo restarted"
ENV

  cat > "$TEST_TEMP/.env.secret" <<'ENV'
TRUENAS_API_KEY="test-api-key"
NPM_PASSWORD="test-password"
ENV

  # Create cert files for validation
  mkdir -p /tmp/test-certs
  echo "test-cert" > /tmp/test-certs/fullchain.pem
  echo "test-key" > /tmp/test-certs/privkey.pem
}

teardown() {
  rm -rf "$TEST_TEMP" /tmp/test-certs
}

# ── load_env tests ──────────────────────────────────────────────────

@test "load_env sources .env and sets CERT/KEY paths" {
  SCRIPT_NAME="test"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"
  load_env

  assert_equal "$CERT" "/tmp/test-certs/fullchain.pem"
  assert_equal "$KEY" "/tmp/test-certs/privkey.pem"
}

@test "load_env sources .env.secret" {
  SCRIPT_NAME="test"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"
  load_env

  assert_equal "$TRUENAS_API_KEY" "test-api-key"
  assert_equal "$NPM_PASSWORD" "test-password"
}

@test "load_env fails if .env is missing" {
  rm "$TEST_TEMP/.env"
  SCRIPT_NAME="test"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"

  run load_env
  assert_failure
  assert_output --partial "Missing config file"
}

@test "load_env warns if .env.secret is missing" {
  rm "$TEST_TEMP/.env.secret"
  SCRIPT_NAME="test"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"

  run load_env
  assert_success
  assert_output --partial "Missing secrets file"
}

# ── log tests ───────────────────────────────────────────────────────

@test "log outputs correct format with timestamp, script name, and level" {
  SCRIPT_NAME="test-script"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"

  run log INFO "hello world"
  assert_success
  assert_output --regexp '\[.*\] \[test-script\] \[INFO\] hello world'
}

@test "log writes to LOG_FILE when set" {
  SCRIPT_NAME="test-script"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"
  LOG_FILE="$TEST_TEMP/test.log"

  log INFO "logged message" 2>/dev/null

  assert [ -f "$TEST_TEMP/test.log" ]
  run cat "$TEST_TEMP/test.log"
  assert_output --partial "[test-script] [INFO] logged message"
}

@test "log supports ERROR level" {
  SCRIPT_NAME="test-script"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"

  run log ERROR "something broke"
  assert_output --partial "[ERROR] something broke"
}

# ── require_vars tests ──────────────────────────────────────────────

@test "require_vars passes when all vars are set" {
  SCRIPT_NAME="test"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"
  LOG_FILE="$TEST_TEMP/test.log"

  FOO="bar"
  BAZ="qux"
  export FOO BAZ

  run require_vars FOO BAZ
  assert_success
}

@test "require_vars fails when a var is missing" {
  SCRIPT_NAME="test"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"
  LOG_FILE="$TEST_TEMP/test.log"

  FOO="bar"
  unset MISSING_VAR 2>/dev/null || true
  export FOO

  run require_vars FOO MISSING_VAR
  assert_failure
  assert_output --partial "Missing required variables"
  assert_output --partial "MISSING_VAR"
}

@test "require_vars fails when a var is empty" {
  SCRIPT_NAME="test"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"
  LOG_FILE="$TEST_TEMP/test.log"

  EMPTY_VAR=""
  export EMPTY_VAR

  run require_vars EMPTY_VAR
  assert_failure
  assert_output --partial "EMPTY_VAR"
}

# ── log_section tests ──────────────────────────────────────────────

@test "log_section_start prints separator with STARTED" {
  SCRIPT_NAME="test"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"

  run log_section_start
  assert_output --partial "========"
  assert_output --partial "DEPLOYMENT RUN STARTED"
}

@test "log_section_end prints separator with status" {
  SCRIPT_NAME="test"
  _COMMON_DIR="$TEST_TEMP/lib"
  PROJECT_ROOT="$TEST_TEMP"
  source "$TEST_TEMP/lib/common.sh"

  run log_section_end "FINISHED SUCCESSFULLY"
  assert_output --partial "========"
  assert_output --partial "FINISHED SUCCESSFULLY"
}
