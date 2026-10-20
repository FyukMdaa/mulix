# Public entrypoint for `lib/hosts/`.
#
# `lib/hosts.nix` is a one-line wrapper that imports this file,
# preserving the public import path that `tests/api-contract` and
# `lib/diagnostics.nix` rely on.
#
# This file imports the five concerns (constants / validate / compose /
# view / sources) and re-exports the union of their public surfaces.
# The exported attribute set is identical to what the original
# monolithic `hosts.nix` exported at lines 82-587.
{lib}: let
  constants = import ./constants.nix {inherit lib;};
  validate = import ./validate.nix {inherit lib;};
  compose = import ./compose.nix {inherit lib;};
  view = import ./view.nix {inherit lib;};
  sources = import ./sources.nix {inherit lib;};
in {
  # ---- constants / field classification ----
  inherit (constants)
    allowedHostFields
    singleFields
    listFields
    configFields
    ;

  # ---- validation ----
  inherit (validate)
    checkStringList
    checkUniqueStringList
    validateConditionNames
    validateHost
    mkHost
    ;

  # ---- fragment collection and merging ----
  inherit (compose)
    fragmentsFromHostDefs
    conflictError
    singleValue
    listContributions
    mergeFragments
    composeFragments
    composeHostDefs
    ;

  # ---- condition view ----
  inherit (view)
    validateHostAgainst
    validateComposedHosts
    validateHosts
    mkComposedView
    mkHostsView
    ;

  # ---- source attribution + graph edges ----
  inherit (sources)
    formatSources
    sourceEdges
    ;
}
