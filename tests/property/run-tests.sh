#!/usr/bin/env bash
# Differential (property) tests: the optimized ownership / merge / cycle code
# must behave exactly like the naive reference implementations kept in
# tests/property/reference.nix, on deterministic pseudo-random inputs.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=tests/lib.sh
. "$ROOT_DIR/tests/lib.sh"

DIFF='(import ./tests/property/differential.nix { lib = (import <nixpkgs> {}).lib; cases = 1500; })'
CYCLES='(import ./tests/property/cycles.nix { lib = (import <nixpkgs> {}).lib; cases = 3000; })'

expect_success "single: conflict detection matches the naive pairwise reference" \
  "let r = $DIFF; in r.conflictMismatches == 0"

expect_success "single: nested priority resolution (applyNestedLeafOverrides) matches the reference" \
  "let r = $DIFF; in r.nestedMismatches == 0"

expect_success "single: end-to-end resolution (success/failure and value) matches the reference" \
  "let r = $DIFF; in r.resolveSingleMismatches == 0"

expect_success "namespaced: end-to-end resolution matches the reference" \
  "let r = $DIFF; in r.resolveNamespacedMismatches == 0"

expect_success "namespaced: conflict report (paths and writer order) matches the reference" \
  "let r = $DIFF; in r.namespacedConflictMismatches == 0"

expect_success "recursiveUpdateMany equals foldl' recursiveUpdate" \
  "let r = $DIFF; in r.recursiveUpdateMismatches == 0"

expect_success "mergeNamespacedMany equals the pairwise mergeNamespaced fold" \
  "let r = $DIFF; in r.mergeNamespacedMismatches == 0"

expect_success "cycle detection is unchanged by the acyclicity pre-check" \
  "let r = $CYCLES; in r.mismatches == 0"

# A comparison that never sees both outcomes proves nothing: require that the
# generators produce successes, failures, cyclic and acyclic graphs.
expect_success "generators exercise both outcomes (otherwise the comparisons are vacuous)" "
  let d = $DIFF; c = $CYCLES; in
     d.casesWithConflicts > 300 && d.casesWithoutConflicts > 300
  && d.singleOk > 200 && d.singleOk < d.cases - 200
  && d.namespacedOk > 200 && d.namespacedOk < d.cases - 200
  && d.mergeNamespacedOk > 100 && d.namespacedCasesWithConflicts > 200
  && c.cyclic > 500 && c.acyclic > 500
"

finish "PROPERTY TESTS"
