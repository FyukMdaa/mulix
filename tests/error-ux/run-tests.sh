#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

failures=0

run_case() {
    local title="$1"
    local fixture="$2"
    local expected="$3"
    local output status

    echo "===== $title ====="

    output=$(nix eval --impure --show-trace --expr "
      let
        lib = (import <nixpkgs> {}).lib;
        m = import ./lib { inherit lib; };
        result = m.normalizeLib.normalizeModule {
          mod = m.module (import ./tests/error-ux/fixtures/$fixture);
          isFunction = false;
          declaredArgs = [];
          source = \"tests/error-ux/fixtures/$fixture\";
        };
      in
        builtins.deepSeq result true
    " 2>&1)
    status=$?

    printf '%s\n' "$output"
    echo "exit=$status"

    if (( status == 0 )); then
        echo "FAIL: $title unexpectedly succeeded"
        failures=$((failures + 1))
    elif ! grep -Fq -- "$expected" <<<"$output"; then
        echo "FAIL: $title did not contain expected diagnostic: $expected"
        failures=$((failures + 1))
    else
        echo "PASS: $title"
    fi
    echo
}

run_case \
  "unknown field + suggestion" \
  "unknown-field.nix" \
  "help: did you mean \`options\`?"

run_case \
  "unknown field + no suggestion" \
  "unknown-field-no-match.nix" \
  "help: remove the field, or use one of the allowed fields above."

# Also ensure a distant typo does not produce a suggestion.
run_case \
  "always unknown field" \
  "always-unknown-field.nix" \
  "unknown field: 'recieve'"

run_case \
  "invalid os" \
  "invalid-os.nix" \
  "target fragment must be an attrset (or function)"

run_case \
  "invalid send" \
  "invalid-send.nix" \
  "'send' must be an attrset mapping configName -> contribution"

run_case \
  "missing name" \
  "missing-name.nix" \
  "required field 'name' is missing"

echo "===== direct didYouMean checks ====="

close_output=$(nix eval --impure --show-trace --expr '
  let
    lib = (import <nixpkgs> {}).lib;
    errors = import ./lib/errors.nix { inherit lib; };
  in
    errors.didYouMean "ab" [ "ax" "ay" "az" "zz" ]
' 2>&1)
close_status=$?
printf '%s\n' "--- close candidates / max 3 ---" "$close_output"
echo "exit=$close_status"
if (( close_status != 0 )) || ! grep -Fq -- '`ax`, `ay`, `az`' <<<"$close_output"; then
    echo "FAIL: close-candidate didYouMean check"
    failures=$((failures + 1))
else
    echo "PASS: close-candidate didYouMean check"
fi
echo

none_output=$(nix eval --impure --show-trace --expr '
  let
    lib = (import <nixpkgs> {}).lib;
    errors = import ./lib/errors.nix { inherit lib; };
  in
    errors.didYouMean "completely-different" [ "options" "always" "os" "home" ]
' 2>&1)
none_status=$?
printf '%s\n' "--- no plausible candidate ---" "$none_output"
echo "exit=$none_status"
if (( none_status != 0 )) || ! grep -Fq -- '""' <<<"$none_output"; then
    echo "FAIL: no-candidate didYouMean check"
    failures=$((failures + 1))
else
    echo "PASS: no-candidate didYouMean check"
fi
echo

if (( failures > 0 )); then
    echo "ERROR UX TESTS FAILED: $failures assertion(s)"
    exit 1
fi

echo "ERROR UX TESTS PASSED"
