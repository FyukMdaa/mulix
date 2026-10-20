# The `mulib` API surface.
#
# This file owns the three public constructors (`mulib.module`,
# `mulib.host`, `mulib.overlay`) and the assembled `mulibApi` attrset
# that gets injected into every module function via `callArgsBase`.
#
# It does NOT own `mkMulix` or `configurations`; those live in
# `lib/mk-mulix.nix` and `lib/configurations.nix` respectively.
# `lib/default.nix` wires them all together and is the public entrypoint.
#
# Dependency injection:
#   `lib/default.nix` imports this file and supplies the sub-libraries and
#   `mkMulix` itself. The mutual recursion between `mulibApi` (which
#   references `mkMulix` as `mulib.mkMulix`) and `mkMulix` (which
#   references `mulibApi` as `mulibForHost`) is resolved at the
#   `default.nix` wiring layer via lazy `let` bindings; this file only
#   assembles the attrset.
{
  lib,
  # The sub-libraries, passed in by `default.nix` so the import graph
  # stays a tree (no diamond imports).
  hostsLib,
  optionShorthands,
  overlaysLib,
  diagnosticsLib,
  graphLib,
  # `mkMulix` is supplied lazily by `default.nix`. The attribute value
  # in `mulibApi.mkMulix` is a deferred reference that resolves once the
  # `default.nix` `let` scope has finished bootstrapping.
  mkMulix,
}:
rec {
  /*
  `mulib.module` - the public constructor for a module descriptor.

  A module is either an attrset (rarely useful - usually you want a
  function so the module can receive `mulib` / `host` / configNames)
  or a function returning such an attrset. The marker `_mulixKind`
  distinguishes module / host / overlay descriptors during collection.

  The descriptor is validated later by `lib/normalize.nix` once it has
  been called with the correct argument set; this constructor only
  stamps the marker so the collector can classify the result.
  */
  module = definition:
    if builtins.isAttrs definition
    then definition // {_mulixKind = "module";}
    else throw "mulix: mulib.module expects a module attrset, got ${builtins.typeOf definition}";

  /*
  `mulib.host` - the public constructor for a host descriptor. Delegates
  to `hostsLib.mkHost` for shape validation (system/type/feat/role/
  send/os/home/darwin must be well-formed) and stamping.
  */
  host = definition:
    if builtins.isAttrs definition
    then hostsLib.mkHost definition
    else throw "mulix: mulib.host expects a host attrset, got ${builtins.typeOf definition}";

  /*
  `mulib.overlay` - the public constructor for an overlay descriptor.
  Delegates to `overlaysLib.mkOverlay` so `name` / `overlay` / `enable`
  are validated at construction time.
  */
  overlay = definition:
    if builtins.isAttrs definition
    then overlaysLib.mkOverlay definition
    else throw "mulix: mulib.overlay expects an attrset, got ${builtins.typeOf definition}";

  /*
  `mulibApi` - the attrset every module function receives as `mulib`.

  This is the canonical, single source of what the mulix module
  namespace looks like. `callArgsBase` in `lib/default.nix` injects
  this attrset under the `mulib` key, and the host-side discovery
  path in `lib/configurations.nix` re-uses the same attrset.

  Members:
    - `module` / `host` / `overlay`            - the constructors above
    - `mkMulix`                                - full pipeline entrypoint
    - `runDiagnostics`                         - `diagnosticsLib.run`
    - `graphLib`                               - DOT/Mermaid helpers
    - `types`                                  - `lib.types` (alias)
    - `type`                                   - shorthand namespace (`mulib.type.bool`, ...)
    - `mkOption`, `mkEnableOption`, `mkIf`, ... - `lib` re-exports
    - `bool`, `str`, `int`, ...                 - option-shorthand helpers
  */
  mulibApi = {
    inherit module host overlay;
    inherit mkMulix;
    runDiagnostics = diagnosticsLib.run;
    graphLib = graphLib;
    types = lib.types;
    type = optionShorthands.type;
    inherit (lib) mkOption mkEnableOption mkIf mkMerge mkDefault mkForce
      mkOverride mkOrder mkBefore mkAfter;
    inherit (optionShorthands) bool str int float lines enum oneOf attrs attrsOf path package listOf nullOr either select;
  };
}
