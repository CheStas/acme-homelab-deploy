#!/usr/bin/env bats

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# ── --list tests ────────────────────────────────────────────────────

@test "--list shows all available deploys" {
  run "$PROJECT_ROOT/deploy-all.sh" --list
  assert_success
  assert_output --partial "ha"
  assert_output --partial "npm"
  assert_output --partial "truenas"
  assert_output --partial "wikihome"
}

# ── --help tests ────────────────────────────────────────────────────

@test "--help shows usage" {
  run "$PROJECT_ROOT/deploy-all.sh" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "--skip"
  assert_output --partial "--list"
}

# ── --dry-run tests ─────────────────────────────────────────────────

@test "--dry-run shows all deploys without running" {
  run "$PROJECT_ROOT/deploy-all.sh" --dry-run
  assert_success
  assert_output --partial "Would run deploys:"
  assert_output --partial "ha"
  assert_output --partial "npm"
  assert_output --partial "truenas"
  assert_output --partial "wikihome"
}

@test "--dry-run with specific deploys shows only those" {
  run "$PROJECT_ROOT/deploy-all.sh" --dry-run ha truenas
  assert_success
  assert_output --partial "Would run deploys: ha truenas"
  refute_output --partial "npm"
  refute_output --partial "wikihome"
}

@test "--dry-run with --skip excludes skipped" {
  run "$PROJECT_ROOT/deploy-all.sh" --dry-run --skip npm --skip wikihome
  assert_success
  assert_output --partial "Would run deploys:"
  assert_output --partial "ha"
  assert_output --partial "truenas"
  refute_output --partial " npm"
  refute_output --partial "wikihome"
}

# ── argument validation tests ───────────────────────────────────────

@test "unknown deploy name fails" {
  run "$PROJECT_ROOT/deploy-all.sh" --dry-run nonexistent
  assert_failure
  assert_output --partial "Unknown deploy 'nonexistent'"
}

@test "unknown flag fails" {
  run "$PROJECT_ROOT/deploy-all.sh" --invalid-flag
  assert_failure
  assert_output --partial "Unknown option"
}
