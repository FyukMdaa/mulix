# mulix - public library entrypoint.
#
# This file is the wiring layer for `lib/`. It imports every sub-library,
# bootstraps the `mulibApi` attrset (with `mkMulix` resolved through lazy
# `let` bindings), and re-exports the public surface that `flake.nix`
# exposes as `mulix.lib`.
#
# Why is this a separate file from `mk-mulix.nix`?
#   - `lib/default.nix` used to be 1183 lines and mixed three concerns:
#     the wiring layer, the `mkMulix` collection pipeline, and the
#     `configurations` fleet helper. Splitting each concern into its own
#     file makes the project easier to navigate over the long term.
#   - The wiring layer is intentionally short (under 100 lines): every
#     reader should be able to hold the dependency graph in their head.
#
# Why are `mulibApi` and `mkMulix` defined in `let` rather than `rec`?
#   They are mutually recursive: `mulibApi` references `mkMulix` (so a
#     module author can write `mulib.mkMulix { ... }`), and `mkMulix`
#   references `mulibApi` (so it can inject `mulib` into module
#   functions via `mulibForHost = mulibApi`). In Nix, `let` bindings
#   are mutually recursive via laziness, so the cycle resolves cleanly:
#   forcing `mkMulix` evaluates the function value without entering its
#   body, and `mulibApi` is only forced once `mkMulix`'s body needs it
#   (long after the outer `mkMulix` binding has been resolved).
#
# Public API contract:
#   The names exported by this file (`hostsLib`, `collectorLib`,
#   `normalizeLib`, ..., `module`, `host`, `overlay`, `mulibApi`,
#   `mkMulix`, `configurations`, `runDiagnostics`, `mulixReservedArgs`)
#   are part of mulix's public API surface. Tests and external
#   consumers import this file directly. Renaming or removing any of
#   them is a breaking change and must be recorded in CHANGELOG.md.
{
  lib,
  pkgs ? null,
  inputs ? {},
}: let
  # ---- sub-library imports ----------------------------------------------
  # Each sub-library is a single-purpose module imported with `{ inherit
  # lib; }` (or its specific dependencies). Adding a new sub-library?
  # Import it here and add it to the `rec` block at the bottom.
  mulixReservedArgs =
    (import ./reserved-args.nix {inherit lib;}).mulixReservedArgs;

  hostsLib = import ./hosts.nix {inherit lib;};
  collectorLib = import ./collector.nix {inherit lib;};
  normalizeLib = import ./normalize.nix {inherit lib;};
  configGraphLib = import ./config-graph.nix {inherit lib;};
  dependencyLib = import ./dependency.nix {inherit lib;};
  targetLib = import ./target.nix {inherit lib;};
  overlaysLib = import ./overlays.nix {inherit lib;};

  # `diagnostics.nix` no longer requires `reservedArgs`: it falls back to
  # the canonical `reserved-args.nix` import when the argument is omitted.
  # Keeping the call site here parameter-free makes the wiring obvious.
  diagnosticsLib = import ./diagnostics.nix {inherit lib;};
  errorsLib = import ./errors.nix {inherit lib;};
  graphLib = import ./graph.nix {inherit lib;};
  optionShorthands = import ./option-shorthands.nix {inherit lib;};

  # ---- mkMulix ----------------------------------------------------------
  # The big collection / normalisation / dependency-check pipeline. It is
  # a function that takes the runtime context (the sub-libraries and
  # `mulibApi`) and returns the public `mkMulix` function. The reference
  # to `mulibApi` inside the body resolves lazily because `let` bindings
  # in Nix are mutually recursive.
  mkMulix =
    (import ./mk-mulix.nix {
      inherit
        lib
        inputs
        mulibApi
        mulixReservedArgs
        hostsLib
        collectorLib
        normalizeLib
        configGraphLib
        dependencyLib
        targetLib
        overlaysLib
        diagnosticsLib
        errorsLib
        ;
    }).mkMulix;

  # ---- mulibApi ---------------------------------------------------------
  # The `mulib` attrset every module function receives. `api` is the
  # let-binding that holds the constructors + `mulibApi`; we extract
  # each member individually so the public `rec` block can re-export
  # them by name.
  api = import ./api.nix {
    inherit lib hostsLib optionShorthands overlaysLib diagnosticsLib graphLib;
    inherit mkMulix;
  };
  inherit (api) module host overlay mulibApi;

  # ---- configurations --------------------------------------------------
  # The fleet helper that wraps `mkMulix` per host and feeds the result
  # into `nixosSystem` / `darwinSystem` / `homeManagerConfiguration`.
  # Lives in its own file because it is a cohesive 300-line block whose
  # only external dependencies are `lib`, `mulibApi`, `mkMulix`, and the
  # collector / normalizer helpers.
  configurations =
    (import ./configurations.nix {
      inherit lib pkgs inputs mulibApi mkMulix normalizeLib collectorLib;
    }).configurations;

  # Convenience alias kept from the original API: `runDiagnostics` is a
  # top-level entry point next to `mkMulix` / `configurations`.
  runDiagnostics = diagnosticsLib.run;
in rec {
  # ---- sub-library re-exports ------------------------------------------
  # These names are part of mulix's public API: tests import them
  # directly (`tests/api-contract/run-tests.sh` imports `lib/hosts.nix`
  # and `lib/config-graph.nix`), and external consumers may rely on them
  # too. Renaming any of them is a breaking change.
  inherit
    hostsLib
    collectorLib
    normalizeLib
    configGraphLib
    dependencyLib
    targetLib
    optionShorthands
    overlaysLib
    ;
  inherit diagnosticsLib graphLib;
  inherit mulixReservedArgs;

  # ---- public API ------------------------------------------------------
  # `mulibApi` and the three constructors are the user-facing surface
  # inside `*.nix` module files. `mkMulix` and `configurations` are the
  # user-facing surface for `flake.nix` wiring.
  inherit module host overlay mulibApi;
  inherit mkMulix configurations;
  inherit runDiagnostics;
}
