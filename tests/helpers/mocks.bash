# Mock setup for tests.
# Creates a temp directory with mock binaries prepended to PATH.

MOCK_DIR=""
MOCK_CALLS_DIR=""

setup_mocks() {
  MOCK_DIR="$(mktemp -d)"
  MOCK_CALLS_DIR="$(mktemp -d)"
  export MOCK_CALLS_DIR
  export PATH="$MOCK_DIR:$PATH"
}

teardown_mocks() {
  rm -rf "$MOCK_DIR" "$MOCK_CALLS_DIR"
}

# Create a mock command that logs its call and returns a fixed response.
# Usage: create_mock COMMAND_NAME [EXIT_CODE] [STDOUT_RESPONSE]
create_mock() {
  local cmd="$1"
  local exit_code="${2:-0}"
  local response="${3:-}"

  cat > "$MOCK_DIR/$cmd" <<SCRIPT
#!/usr/bin/env bash
echo "\$@" >> "$MOCK_CALLS_DIR/${cmd}_calls"
echo "$response"
exit $exit_code
SCRIPT
  chmod +x "$MOCK_DIR/$cmd"
}

# Get number of times a mock was called.
mock_call_count() {
  local cmd="$1"
  local calls_file="$MOCK_CALLS_DIR/${cmd}_calls"
  if [[ -f "$calls_file" ]]; then
    wc -l < "$calls_file"
  else
    echo "0"
  fi
}

# Get the Nth call arguments (0-indexed).
mock_call_args() {
  local cmd="$1"
  local n="${2:-0}"
  local calls_file="$MOCK_CALLS_DIR/${cmd}_calls"
  if [[ -f "$calls_file" ]]; then
    sed -n "$((n + 1))p" "$calls_file"
  fi
}
