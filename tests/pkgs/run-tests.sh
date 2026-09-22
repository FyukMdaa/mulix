#!/usr/bin/env bash
# Which `pkgs` do module fragments see at target time?
#
# The module system builds the real `pkgs` (nixpkgs.overlays, nixpkgs.config,
# hostPlatform applied) and exposes it as `config._module.args.pkgs`.  Fragments
# must get THAT, not mkMulix's own `pkgs` argument (a plain legacyPackages set):
# otherwise overlay-provided attributes vanish ("attribute 'nix-init' missing").
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=tests/lib.sh
. "$ROOT_DIR/tests/lib.sh"

PRE='
  let
    lib = (import <nixpkgs> {}).lib;
    baseM = import ./lib { inherit lib; };
    inlineModulePath = i: /. + (builtins.unsafeDiscardStringContext
      (builtins.toFile "mulix-test-module-${toString i}.nix"
        "{ __mulixTestModules, ... }: builtins.elemAt __mulixTestModules ${toString i}"));
    mkM = args:
      let
        hasModules = args ? modules;
        defs = if hasModules then args.modules else [];
        generated =
          if !hasModules then []
          else if builtins.isPath defs then [ defs ]
          else if builtins.isList defs then lib.imap0 (i: _: inlineModulePath i) defs
          else [];
        rawPaths = args.paths or [];
        normalizedPaths = map (p: if builtins.isPath p then p else /. + (toString p)) rawPaths;
        cleaned = builtins.removeAttrs args [ "modules" "paths" "specialArgs" ];
        mergedSpecialArgs =
          (args.specialArgs or {})
          // (if hasModules && builtins.isList defs then { __mulixTestModules = defs; } else {});
      in
        baseM.mkMulix (cleaned // {
          paths = normalizedPaths ++ generated;
          specialArgs = mergedSpecialArgs;
        });
    # Test-only adapter: production mkMulix intentionally has no inline `modules` API.
    m = baseM // { mkMulix = mkM; };
    T = lib.types;
    fx = ./tests/fixtures/overlay-pkgs;

    # A miniature nixpkgs.  `pkgs.lix` is a plain derivation-like attrset WITHOUT
    # `nix-init`; only the overlay turns it into a package set.
    base = final: { devenv = "devenv"; lix = { name = "lix-drv"; }; };
    mkPkgs = overlays: lib.fix (lib.extends (lib.composeManyExtensions overlays)
      (final: base final // { extend = f: mkPkgs (overlays ++ [ f ]); }));

    # What NixOS does: nixpkgs.overlays -> config.nixpkgs.pkgs -> _module.args.pkgs
    nixpkgsStub = { config, ... }: {
      options.nixpkgs.overlays = lib.mkOption { type = T.listOf T.raw; default = [ ]; };
      config._module.args.pkgs = mkPkgs config.nixpkgs.overlays;
    };
    outOpt = { options.out = lib.mkOption { type = T.attrsOf T.raw; default = { }; }; };

    mk = args: mkM ({
      host = "h"; conditionNames = { };
      paths = [ (fx + "/hosts") (fx + "/modules") (fx + "/overlays") ];
      configNames.pkgNames = { type = T.listOf T.str; merge = "ordered"; default = [ ]; };
      pkgs = mkPkgs [ ];      # what `configurations` passes: legacyPackages, no overlays
    } // args);
    r = mk { };

    # NixOS-like evaluation: the module system supplies the real pkgs
    nixosLike = r: (lib.evalModules {
      modules = (r.targetModuleList "os") ++ [ r.overlayModule nixpkgsStub outOpt ];
    }).config.out;
  in
'

expect_success "1. an attrset fragment using top-level pkgs sees overlay-applied pkgs (the reported case)" "$PRE"'
  (nixosLike r).tools == [ "devenv" "nix-init-from-overlay" ]
'

expect_success "2. a fragment FUNCTION asking for pkgs sees overlay-applied pkgs" "$PRE"'
  (nixosLike r).fromFunction == "nix-init-from-overlay"
'

expect_success "3. an always.* fragment function sees overlay-applied pkgs" "$PRE"'
  (nixosLike r).fromAlways == "nix-init-from-overlay"
'

expect_success "4. a send FUNCTION sees overlay-applied pkgs" "$PRE"'
  (nixosLike r).pkgNames == [ "nix-init-from-overlay" ]
'

expect_success "5. the overlays were discovered and applied to the module system pkgs" "$PRE"'
  builtins.attrNames r.overlaysByName == [ "lix" ]
  && (lib.evalModules { modules = [ r.overlayModule nixpkgsStub
       ({ pkgs, ... }: { options.p = lib.mkOption { type = T.raw; }; config.p = pkgs.lix.nix-init; }) ]; }).config.p
       == "nix-init-from-overlay"
'

expect_failure "6. without a module-system pkgs the mkMulix pkgs argument is used (unchanged fallback)" "$PRE"'
  (lib.evalModules { modules = (r.targetModuleList "os") ++ [ outOpt ]; }).config.out.tools
' "nix-init"

expect_success "6b. ... and it is what a fallback fragment sees" "$PRE"'
  let r2 = mk { pkgs = mkPkgs [ (f: p: { lix = { nix-init = "from-arg"; }; }) ]; };
  in (lib.evalModules { modules = (r2.targetModuleList "os") ++ [ outOpt ]; }).config.out.tools
       == [ "devenv" "from-arg" ]
'

expect_success "7. specialArgs = { pkgs = ...; } is the strongest source" "$PRE"'
  let special = mkPkgs [ (f: p: { lix = { nix-init = "from-specialArgs"; }; }) ];
  in (lib.evalModules {
       specialArgs = { pkgs = special; };
       modules = (r.targetModuleList "os") ++ [ r.overlayModule nixpkgsStub outOpt ];
     }).config.out.tools == [ "devenv" "from-specialArgs" ]
'

expect_success "8. pkgs stays lazy: a module that never uses it does not force it" "$PRE"'
  let r3 = mkM {
        host = "h"; conditionNames = { }; pkgs = null;
        hostDefs.h = m.host { name = "h"; };
        modules = [ (m.module { name = "plain"; options.enable = m.mulibApi.bool.true; os.out.v = 1; }) ];
      };
  in (lib.evalModules { modules = (r3.targetModuleList "os") ++ [ outOpt
       { config._module.args.pkgs = throw "pkgs must not be forced"; } ]; }).config.out.v == 1
'

expect_success "9. a host fragment function gets the module-system pkgs too" "$PRE"'
  let r4 = mkM {
        host = "h"; conditionNames = { }; pkgs = mkPkgs [ ];
        hostDefs.h = m.host { name = "h"; os = { pkgs, ... }: { out.hostFrag = pkgs.lix.nix-init; }; };
        overlays = [ (m.overlay { name = "lix"; overlay = f: p: { lix = { nix-init = "from-overlay"; }; }; }) ];
      };
  in (nixosLike r4).hostFrag == "from-overlay"
'

# ---------------------------------------------------------------------------
# `configurations` end to end (a miniature nixosSystem = evalModules)
# ---------------------------------------------------------------------------
CFG='
  let
    nixosSystem = { modules, specialArgs ? { }, system ? null }: lib.evalModules {
      inherit specialArgs;
      modules = modules ++ [ nixpkgsStub outOpt ];
    };
    inputs = { nixpkgs = { legacyPackages.x86_64-linux = mkPkgs [ ]; lib.nixosSystem = nixosSystem; }; };
    mm = import ./lib { inherit lib inputs; };
    cfgs = mm.configurations {
      paths = [ (fx + "/hosts") (fx + "/modules") (fx + "/overlays") ];
      conditionNames = { };
      configNames.pkgNames = { type = T.listOf T.str; merge = "ordered"; default = [ ]; };
    };
  in
'
expect_success "10. configurations: the built NixOS system sees overlay-applied pkgs" "$PRE$CFG"'
  cfgs.hostNames == [ "h" ]
  && builtins.attrNames cfgs.nixosConfigurations == [ "h" ]
  && cfgs.nixosConfigurations.h.config.out.tools == [ "devenv" "nix-init-from-overlay" ]
'

finish "PKGS TESTS"
