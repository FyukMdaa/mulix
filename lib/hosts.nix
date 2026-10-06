# Backwards-compatible wrapper around `./hosts/default.nix`.
#
# The original monolithic `hosts.nix` (588 lines) has been split into
# the `lib/hosts/` directory:
#   - `constants.nix`  - field classification + small pure helpers
#                        (parseSystem, systemFlags, typeNamesOf,
#                        generatedIsNames, unionAcross, mkBoolUniverse,
#                        fragmentLabel, quote, checkSendShape)
#   - `validate.nix`   - checkStringList, checkUniqueStringList,
#                        validateConditionNames, validateHost, mkHost
#   - `compose.nix`    - fragmentsFromHostDefs, conflictError,
#                        singleValue, listContributions, mergeFragments,
#                        composeFragments, composeHostDefs
#   - `view.nix`       - validateHostAgainst, validateComposedHosts,
#                        validateHosts, mkComposedView, mkHostsView
#   - `sources.nix`    - formatSources, sourceEdges
#   - `default.nix`    - imports the five concerns and re-exports the
#                        public surface
#
# This wrapper exists because:
#   - `tests/api-contract/run-tests.sh` imports `./lib/hosts.nix`
#     directly (to test `mkHost`, `mkComposedView`, etc.).
#   - `lib/diagnostics.nix` imports it for `formatSources`.
#   - Any external consumer may have done the same.
#
# The wrapper keeps the public import path stable; users that prefer the
# new layout can import `./hosts/default.nix` directly.
{lib}:
import ./hosts/default.nix {inherit lib;}
