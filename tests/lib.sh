# Shared helpers for the shell test suites.  Source this file; do not run it.
#
#   expect_success NAME EXPR
#       EXPR must evaluate WITHOUT error and to something other than `false`.
#       (Merely "did not throw" is not enough: a bare `x == y` that evaluates
#       to `false` is a failed assertion, not a pass.)
#   expect_failure NAME EXPR SUBSTRING
#       EXPR must fail, and the error output must contain SUBSTRING, so an
#       unrelated failure (syntax error, missing argument, ...) is not a pass.
#
# Every case runs even after a failure; `finish` prints the summary and exits
# non-zero if anything failed.

FAILS=0

_fail() {
  echo "FAIL: $1"
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2" | grep -vE '^\s*$' | tail -n 8 | sed 's/^/    /'
  fi
  FAILS=$((FAILS + 1))
}

expect_success() {
  local name="$1" expr="$2" out err
  err=$(mktemp)
  if ! out=$(nix eval --impure --json --expr "$expr" 2>"$err"); then
    _fail "$name (evaluation error)" "$(cat "$err")"
  elif [ "$out" = "false" ]; then
    _fail "$name (expression evaluated to false)"
  else
    echo "PASS: $name"
  fi
  rm -f "$err"
}

expect_failure() {
  local name="$1" expr="$2" expected="$3" output
  if output=$(nix eval --impure --show-trace --json --expr "$expr" 2>&1); then
    _fail "$name (unexpected success)"
  elif ! grep -Fq -- "$expected" <<<"$output"; then
    _fail "$name (wrong failure cause; expected: $expected)" "$output"
  else
    echo "PASS: $name"
  fi
}

finish() {
  local suite="$1"
  echo
  if [ "$FAILS" -gt 0 ]; then
    echo "$suite FAILED: $FAILS case(s)"
    exit 1
  fi
  echo "$suite PASSED"
}
