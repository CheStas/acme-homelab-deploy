#!/usr/bin/env bash
# Orchestrator: runs all (or selected) deploy scripts.
#
# Usage:
#   ./deploy-all.sh                  # Run all deploys
#   ./deploy-all.sh ha truenas       # Run only these
#   ./deploy-all.sh --skip npm       # Run all except npm
#   ./deploy-all.sh --list           # Show available deploys
#   ./deploy-all.sh --help           # Show usage

SCRIPT_NAME="deploy-all"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

source "$PROJECT_ROOT/lib/common.sh"
load_env

# ── Available deploys (discovered from deploys/ directory) ──────────
ALL_DEPLOYS=()
for f in "$PROJECT_ROOT/deploys/"*.sh; do
  [[ -f "$f" ]] && ALL_DEPLOYS+=("$(basename "$f" .sh)")
done

# ── Argument parsing ────────────────────────────────────────────────
usage() {
  echo "Usage: $(basename "$0") [OPTIONS] [DEPLOY_NAMES...]"
  echo ""
  echo "Options:"
  echo "  --skip NAME   Skip the named deploy (can be repeated)"
  echo "  --list        List available deploys and exit"
  echo "  --dry-run     Show what would run without executing"
  echo "  -h, --help    Show this help"
  echo ""
  echo "Available deploys: ${ALL_DEPLOYS[*]}"
}

SELECTED=()
SKIPPED=()
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip)
      SKIPPED+=("$2")
      shift 2
      ;;
    --list)
      echo "Available deploys:"
      for d in "${ALL_DEPLOYS[@]}"; do
        echo "  $d"
      done
      exit 0
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      SELECTED+=("$1")
      shift
      ;;
  esac
done

# Build final deploy list
if [[ ${#SELECTED[@]} -gt 0 ]]; then
  DEPLOYS=("${SELECTED[@]}")
else
  DEPLOYS=("${ALL_DEPLOYS[@]}")
fi

# Apply skips
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  FILTERED=()
  for d in "${DEPLOYS[@]}"; do
    skip=false
    for s in "${SKIPPED[@]}"; do
      [[ "$d" == "$s" ]] && skip=true && break
    done
    $skip || FILTERED+=("$d")
  done
  DEPLOYS=("${FILTERED[@]}")
fi

# Validate deploy names
for d in "${DEPLOYS[@]}"; do
  if [[ ! -f "$PROJECT_ROOT/deploys/${d}.sh" ]]; then
    echo "ERROR: Unknown deploy '$d'. Available: ${ALL_DEPLOYS[*]}" >&2
    exit 1
  fi
done

if [[ ${#DEPLOYS[@]} -eq 0 ]]; then
  echo "No deploys to run." >&2
  exit 0
fi

# ── Dry run ─────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo "Would run deploys: ${DEPLOYS[*]}"
  exit 0
fi

# ── Run deploys ─────────────────────────────────────────────────────
log_section_start

log INFO "Deploys to run: ${DEPLOYS[*]}"

SUCCESSES=()
FAILURES=()

for deploy in "${DEPLOYS[@]}"; do
  log INFO "--- Starting: $deploy ---"

  # pipefail ensures the pipeline returns the deploy script's exit code,
  # not tee's (which always succeeds).
  if bash -o pipefail -c '"$1" 2>&1 | tee -a "$2" >&2' _ "$PROJECT_ROOT/deploys/${deploy}.sh" "$LOG_FILE"; then
    log INFO "--- $deploy: SUCCESS ---"
    SUCCESSES+=("$deploy")
  else
    log ERROR "--- $deploy: FAILED (exit $?) ---"
    FAILURES+=("$deploy")
  fi
done

# ── Summary ─────────────────────────────────────────────────────────
log INFO "Summary: ${#SUCCESSES[@]} succeeded, ${#FAILURES[@]} failed"

if [[ ${#SUCCESSES[@]} -gt 0 ]]; then
  log INFO "Succeeded: ${SUCCESSES[*]}"
fi

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  log ERROR "Failed: ${FAILURES[*]}"
  log_section_end "FINISHED WITH ERRORS"
  exit 1
fi

log_section_end "FINISHED SUCCESSFULLY"
exit 0
