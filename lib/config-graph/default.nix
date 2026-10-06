# Public entrypoint for `lib/config-graph/`.
#
# `lib/config-graph.nix` is a one-line wrapper that imports this file,
# preserving the public import path that `tests/api-contract` and
# `tests/property` rely on.
#
# This file imports the three concerns (registry / overlap / merge) and
# re-exports the union of their public surfaces. The exported attribute
# set is identical to what the original monolithic `config-graph.nix`
# exported at lines 857-862.
{lib}: let
  registry = import ./registry.nix {inherit lib;};
  overlap = import ./overlap.nix {inherit lib;};
  merge = import ./merge.nix {inherit lib;};
in {
  # ---- registry validation ----
  # `mergeStrategies` lives in `registry.nix` because it is the
  # authoritative constant list consulted by `validateRegistryEntry`.
  inherit (registry)
    validateRegistry
    validateRegistryWithReserved
    validateRegistryEntry
    mergeStrategies
    ;

  # ---- path overlap / send value traversal ----
  # These are exported as part of the public surface so the differential
  # tests in `tests/property` can compare the optimised implementation
  # against the naive reference one.
  inherit (overlap)
    collectPaths
    pathsOverlap
    applyNestedLeafOverrides
    collectLeafWrites
    collectPathsIn
    pathKey
    recursiveUpdateMany
    ;

  # ---- merge strategies + resolution ----
  # `findSingleConflicts`, `mergeNamespacedMany`, and
  # `findNamespacedConflicts` are exported alongside the public
  # `resolve*` entry points because the property tests exercise them
  # directly.
  inherit (merge)
    findSingleConflicts
    mergeNamespacedMany
    findNamespacedConflicts
    resolveSingle
    resolveNamespaced
    resolveOrdered
    resolveAll
    ;
}
