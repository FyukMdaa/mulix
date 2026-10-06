# Backwards-compatible wrapper around `./config-graph/default.nix`.
#
# The original monolithic `config-graph.nix` (864 lines) has been split
# into three concerns under `lib/config-graph/`:
#   - `registry.nix`   - registry entry validation
#   - `overlap.nix`    - path overlap index, send value traversal
#   - `merge.nix`      - single / namespaced / ordered merge strategies
#                        and the `resolveAll` entrypoint
#   - `default.nix`    - imports the three and re-exports the public surface
#
# This wrapper exists because:
#   - `tests/api-contract/run-tests.sh` imports `./lib/config-graph.nix`
#     directly (to test `validateRegistry`, `resolveAll`, etc.).
#   - `tests/property/differential.nix` imports it for differential
#     testing of `findSingleConflicts`, `applyNestedLeafOverrides`,
#     `recursiveUpdateMany`, `mergeNamespacedMany`,
#     `findNamespacedConflicts`.
#   - Any external consumer may have done the same.
#
# The wrapper keeps the public import path stable; users that prefer the
# new layout can import `./config-graph/default.nix` directly.
{lib}:
import ./config-graph/default.nix {inherit lib;}
