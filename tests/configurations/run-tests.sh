#!/usr/bin/env bash
# `configurations` fleet helper: keys of the generated attrsets.
# Home Manager / nixosSystem are stubbed, so only mulix's own wiring is checked.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=tests/lib.sh
. "$ROOT_DIR/tests/lib.sh"

PRE='
  let
    lib = (import <nixpkgs> {}).lib;
    m = import ./lib { inherit lib; };
    H = name: m.host { inherit name; system = "x86_64-linux"; };
    fleet = hosts: extra: m.configurations ({
      hostDefs = lib.genAttrs hosts H;
      conditionNames = {};
      pkgsFor = _: null;
      homeManagerConfiguration = args: args;   # stub: never evaluated
    } // extra);
    homeKeys = hosts: extra: builtins.attrNames (fleet hosts extra).homeConfigurations;
  in
'

expect_success "no user: one entry per host, keyed by host name" "$PRE"'
  homeKeys [ "a" "b" ] {} == [ "a" "b" ]
'

expect_success "user + single host: key stays the bare user name (compat)" "$PRE"'
  homeKeys [ "a" ] { homeManager.user = "alice"; } == [ "alice" ]
'

expect_success "user + several hosts: every host keeps its own entry (user@host)" "$PRE"'
  homeKeys [ "a" "b" ] { homeManager.user = "alice"; } == [ "alice@a" "alice@b" ]
'

expect_success "legacy homeManagerUser behaves like homeManager.user" "$PRE"'
  homeKeys [ "a" "b" ] { homeManagerUser = "alice"; } == [ "alice@a" "alice@b" ]
'

expect_success "no host is silently dropped from homeConfigurations" "$PRE"'
  builtins.length (homeKeys [ "a" "b" "c" ] { homeManager.user = "alice"; }) == 3
'

finish "CONFIGURATIONS TESTS"
