# mulix-reserved module-function argument names.
#
# This is the canonical, single-source-of-truth list. Both `lib/default.nix`
# (where it is part of the module-function-namespace contract) and
# `lib/diagnostics.nix` (where it backs the `configName-reserved-arg-collision`
# rule) read from here, so the two never drift out of sync.
#
# Why a separate file?
#   1. It removes the parameter-passing smell where `default.nix` had to
#      hand `reservedArgs` to `diagnostics.nix`. Now both call sites
#      import this file directly.
#   2. It is the first place a contributor looks when they need to add a
#      new mulix built-in argument name.
#
# Adding a new reserved arg:
#   - Append it here.
#   - Update `docs/ja/reference.org` if it is a public argument.
#   - Update `lib/api.nix` `mulibApi` if it should be reachable via `mulib`.
{
  lib,
}: let
  /*
  Canonical module-function namespace reserved by mulix.

  These names are *not* configNames. A module-function argument that
  appears in this list is supplied by mulix itself (`mulib`, `host`,
  `pkgs`, ...) or by the NixOS / Home Manager module environment
  (`modulesPath`, `osConfig`, ...). Receiver-side diagnostics rejects
  configName declarations that collide with these names so that
  `module = { host, ... }: ...` always means the mulix-built-in `host`
  and not a user-declared configName.

  The list is ordered: first the names mulix itself injects through
  `callArgsBase`, then the names the NixOS / Home Manager module system
  may supply via `specialArgs` or `_module.args`.
  */
  mulixReservedArgs = [
    # ---- mulix-injected (callArgsBase in lib/default.nix) ----
    "mulib"
    "host"
    "pkgs"
    "lib"
    "inputs"
    "config"
    "options"
    "opt"
    "types"
    "mkOption"
    "mkEnableOption"
    "mkIf"
    "mkMerge"
    "mkDefault"
    "mkForce"
    "mkOverride"
    "mkOrder"
    "mkBefore"
    "mkAfter"

    # ---- NixOS / Home Manager module environments ----
    # These arrive via `specialArgs` or `_module.args`. They are not
    # configName namespaces; declaring a configName with one of these
    # names would silently shadow a real NixOS argument.
    "modulesPath"
    "osConfig"
  ];
in {
  inherit mulixReservedArgs;

  # Convenience: every name above, plus every key in `specialArgs`, is
  # part of the reserved namespace at mkMulix time. Exported so callers
  # can compute `reservedArgNames` without duplicating the logic.
  reservedArgNames = extra:
    lib.unique (mulixReservedArgs ++ builtins.attrNames (extra or {}));
}
