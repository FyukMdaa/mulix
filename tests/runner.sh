#!/usr/bin/env bash
# Run every `tests/*/run-tests.sh` suite in deterministic order.
#
# Usage:
#   ./tests/runner.sh                # run all suites, stop on first failure
#   ./tests/runner.sh --continue     # run all suites even if one fails
#   ./tests/runner.sh --suite e2e    # run a single suite by name
#   ./tests/runner.sh --list         # list available suites
#
# Exit code is non-zero iff any suite failed.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Suites are executed in this fixed order so that the cheapest, most
# diagnostic-rich suites run first: api-contract failures are usually the
# easiest to interpret and should block the longer e2e / property runs.
DEFAULT_SUITES=(
  api-contract
  e2e
  host
  error-ux
  pkgs
  perf
  property
)

mode="stop"
suite_filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    --continue|-c) mode="continue" ;;
    --suite|-s) shift; suite_filter="${1:-}" ;;
    --list|-l)
      printf '%s\n' "${DEFAULT_SUITES[@]}"
      exit 0
      ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "tests/runner.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "${suite_filter}" ]; then
  suites=("${DEFAULT_SUITES[@]}")
else
  # Validate the requested suite exists.
  if ! printf '%s\n' "${DEFAULT_SUITES[@]}" | grep -qx "$suite_filter"; then
    echo "tests/runner.sh: unknown suite '$suite_filter'" >&2
    echo "available suites: ${DEFAULT_SUITES[*]}" >&2
    exit 2
  fi
  suites=("$suite_filter")
fi

overall=0
failed_suites=()
for suite in "${suites[@]}"; do
  script="tests/$suite/run-tests.sh"
  if [ ! -x "$script" ] && [ ! -f "$script" ]; then
    echo "tests/runner.sh: missing $script" >&2
    overall=1
    continue
  fi
  echo
  echo "================================================================"
  echo "  RUNNING  $suite"
  echo "================================================================"
  if bash "$script"; then
    echo "  ✓ $suite passed"
  else
    echo "  ✗ $suite failed"
    failed_suites+=("$suite")
    overall=1
    if [ "$mode" = "stop" ]; then
      break
    fi
  fi
done

echo
if [ $overall -eq 0 ]; then
  echo "All requested suites passed."
else
  echo "Failed suites: ${failed_suites[*]}"
fi
exit $overall
