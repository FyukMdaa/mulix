#!/usr/bin/env bash
# Host composition, directory discovery, bound configName aliases, overlays.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=tests/lib.sh
. "$ROOT_DIR/tests/lib.sh"

PRE='
  let
    lib = (import <nixpkgs> {}).lib;
    T = lib.types;
    baseM = import ./lib { inherit lib; };
    # Turn a test-only inline module into a discovered .nix file without
    # losing the original function module dependency metadata.  The wrapper
    # itself accepts __mulixTestModules, but setFunctionArgs makes
    # builtins.functionArgs see the original module arguments.  The wrapper
    # then forwards the complete module-system argument set to the original.
    inlineModulePath = defs: i: let
      d = builtins.elemAt defs i;
      functionArgs = if lib.isFunction d then lib.functionArgs d else {};
      argSpec = if functionArgs == {}
        then "{}"
        else "{ " + lib.concatStringsSep "; "
          (map (name: "${name} = ${if builtins.getAttr name functionArgs then "true" else "false"}")
            (builtins.attrNames functionArgs)) + "; }";
      body = "let lib = (import <nixpkgs> {}).lib; wrapper = args@{ __mulixTestModules, ... }: let d = builtins.elemAt args.__mulixTestModules ${toString i}; in if lib.isFunction d then d args else d; in lib.setFunctionArgs wrapper ${argSpec}";
    in /. + (builtins.unsafeDiscardStringContext
      (builtins.toFile "mulix-test-module-${toString i}.nix" body));
    mkM = args:
      let
        hasModules = args ? modules;
        defs = if hasModules then args.modules else [];
        generated =
          if !hasModules then []
          else if builtins.isPath defs then [ defs ]
          else if builtins.isList defs then lib.imap0 (i: _: inlineModulePath defs i) defs
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
    cn = {
      type = [ "laptop" "desktop" ];
      feat = [ "gui" "niri" "amd" "gaming" "hyprland" "preservation" "secureboot" "tpm2" ];
      role = [ "desktop" "gaming" ];
    };
    H = attrs: m.host ({ name = "alpha"; } // attrs);
    mkH = frags: mkM { hostDefs.alpha = frags; host = "alpha"; conditionNames = cn; };
    fx = ./tests/fixtures;
    inspiron = mkM {
      host = "Inspiron14-5445"; conditionNames = cn;
      configNames.hostconf = { bind = "mulix.modules"; };
      paths = [ (fx + "/inspiron/hosts") (fx + "/inspiron/modules") (fx + "/inspiron/overlays") ];
    };
    evalT = r: target: (lib.evalModules {
      modules = (r.targetModuleList target) ++ [ {
        options.out = lib.mkOption { type = T.lazyAttrsOf T.raw; default = {}; };
        config._module.args.pkgs = { marker = "PKGS"; };
      } ];
    }).config.out;
  in
'

# ===========================================================================
# Host merge semantics
# ===========================================================================

expect_success "1. same type in two fragments is accepted" "$PRE"'
  (mkH [ (H { type = "laptop"; }) (H { type = "laptop"; }) ]).host.type.laptop
'

expect_failure "2. type conflict is an error" "$PRE"'
  builtins.deepSeq (mkH [ (H { type = "laptop"; }) (H { type = "desktop"; }) ]).host true
' "mulix: host type conflict"

expect_failure "2b. type conflict names the host" "$PRE"'
  builtins.deepSeq (mkH [ (H { type = "laptop"; }) (H { type = "desktop"; }) ]).host true
' "host: alpha"

expect_failure "2c. type conflict shows both values" "$PRE"'
  builtins.deepSeq (mkH [ (H { type = "laptop"; }) (H { type = "desktop"; }) ]).host true
' 'value: "desktop"'

expect_failure "2d. type conflict shows the source of each value" "$PRE"'
  builtins.deepSeq (mkH [ (H { type = "laptop"; }) (H { type = "desktop"; }) ]).host true
' "source: hostDefs.alpha[1]"

expect_failure "2e. malformed hostDefs entries get a mulix host-shape error" "$PRE"'
  builtins.deepSeq (mkM { host = "h"; conditionNames = cn; hostDefs.h = null; }).host true
' "mulix: invalid host shape"

expect_success "3. same system in two fragments is accepted" "$PRE"'
  (mkH [ (H { system = "x86_64-linux"; }) (H { system = "x86_64-linux"; }) ]).host.system == "x86_64-linux"
'

expect_failure "3b. system conflict is an error" "$PRE"'
  builtins.deepSeq (mkH [ (H { system = "x86_64-linux"; }) (H { system = "aarch64-linux"; }) ]).host true
' "mulix: host system conflict"

expect_success "4. feat is merged across fragments" "$PRE"'
  (mkH [ (H { feat = [ "gui" "niri" ]; }) (H { feat = [ "amd" "gaming" ]; }) ]).host.features
    == [ "gui" "niri" "amd" "gaming" ]
'

expect_success "5. duplicate feat is kept once (first appearance wins the position)" "$PRE"'
  (mkH [ (H { feat = [ "gui" ]; }) (H { feat = [ "gui" "niri" ]; }) ]).host.features == [ "gui" "niri" ]
'

expect_success "5b. the feat view reflects the merged list" "$PRE"'
  let h = (mkH [ (H { feat = [ "gui" ]; }) (H { feat = [ "niri" ]; }) ]).host;
  in h.feat.gui && h.feat.niri && !h.feat.amd
'

expect_success "6. role is merged across fragments" "$PRE"'
  (mkH [ (H { role = [ "desktop" ]; }) (H { role = [ "gaming" ]; }) ]).host.roles == [ "desktop" "gaming" ]
'

expect_success "6b. features / roles remain accepted as aliases" "$PRE"'
  let a = (mkH [ (H { features = [ "gui" ]; }) (H { feat = [ "niri" ]; roles = [ "gaming" ]; }) ]).host;
      b = (mkH [ (H { feat = [ "gui" ]; }) (H { feat = [ "niri" ]; role = [ "gaming" ]; }) ]).host;
  in a.features == b.features && a.roles == b.roles && a.feat == b.feat && a.role == b.role
'

expect_failure "7. host.is cannot be defined by hand" "$PRE"'
  H { is.desktop = true; }
' "mulix: host.is is reserved for generated state"

expect_failure "7b. the error names the host" "$PRE"'
  H { is.desktop = true; }
' "host: alpha"

expect_failure "7c. conditionNames.is is reserved too" "$PRE"'
  builtins.deepSeq (mkM { hostDefs.alpha = H { }; host = "alpha"; conditionNames = { is = [ "laptop" ]; }; }).host true
' "conditionNames.is is reserved for generated state"

expect_success "7d. is is generated from system, type, role and feat" "$PRE"'
  let is = (mkH [ (H { system = "x86_64-linux"; type = "laptop"; role = [ "gaming" ]; feat = [ "niri" ]; }) ]).host.is;
  in is.linux && is.x86_64 && !is.darwin && is.laptop && is.gaming && is.niri && !is.gui
'

expect_success "7e. feat may reuse a generated system flag name" "$PRE"'
  let h = (mkH [ (H { system = "x86_64-linux"; feat = [ "linux" ]; }) ]).host;
  in h.is.linux && h.feat.linux
' 

expect_failure "7f. unknown host field is a typo error with a suggestion" "$PRE"'
  H { featt = [ "gui" ]; }
' "did you mean"

expect_failure "7g. hostDefs key must equal the host name" "$PRE"'
  builtins.deepSeq (mkM { hostDefs.beta = H { }; host = "beta"; conditionNames = cn; }).host true
' "host identity mismatch"

expect_failure "7h. undeclared feature is still rejected" "$PRE"'
  builtins.deepSeq (mkH [ (H { feat = [ "not-declared" ]; }) ]).host true
' "undeclared feat condition"

# ===========================================================================
# Source tracking / diagnostics
# ===========================================================================

expect_failure "8. conflict from files shows both source files" "$PRE"'
  builtins.deepSeq (mkM { host = "alpha"; conditionNames = cn; paths = [ (fx + "/conflict/hosts") ]; }).host true
' "source: hosts/alpha/workstation.nix"

expect_failure "8b. ... and the other one" "$PRE"'
  builtins.deepSeq (mkM { host = "alpha"; conditionNames = cn; paths = [ (fx + "/conflict/hosts") ]; }).host true
' "source: hosts/alpha/default.nix"

expect_success "8c. sources of feat are tracked per fragment" "$PRE"'
  builtins.elem { value = "amd"; source = "hosts/Inspiron14-5445/hardware.nix"; } inspiron.hostSources.feat
'

expect_success "8d. the fragment list is in a stable order (default.nix first)" "$PRE"'
  map (f: f.source) inspiron.hostSources.fragments == [
    "hosts/Inspiron14-5445/default.nix" "hosts/Inspiron14-5445/disko.nix"
    "hosts/Inspiron14-5445/hardware.nix" "hosts/Inspiron14-5445/initrd.nix"
    "hosts/Inspiron14-5445/preservation.nix" "hosts/Inspiron14-5445/secureboot.nix"
    "hosts/Inspiron14-5445/tpm2.nix" ]
'

expect_success "8e. diagnostics report the composition of a multi-fragment host" "$PRE"'
  builtins.any (r: r.rule == "host-composition")
    (m.diagnosticsLib.run { modules = inspiron.modules; registry = {}; hosts = inspiron.hosts; hostFragments = inspiron.hostFragments; }).reports
'

expect_success "8f. the composition report lists the source files" "$PRE"'
  lib.hasInfix "hosts/Inspiron14-5445/tpm2.nix"
    (builtins.head (builtins.filter (r: r.rule == "host-composition")
      (m.diagnosticsLib.run { modules = inspiron.modules; registry = {}; hosts = inspiron.hosts; hostFragments = inspiron.hostFragments; }).reports)).message
'

expect_success "8g. a fragment in the wrong host directory is a WARNING, not an error" "$PRE"'
  let r = mkM { host = "alpha"; conditionNames = cn; paths = [ (fx + "/mismatch/hosts") ]; };
      reps = (m.diagnosticsLib.run { modules = r.modules; registry = {}; hosts = r.hosts; hostFragments = r.hostFragments; }).reports;
  in builtins.attrNames r.hosts == [ "alpha" "beta" ]
     && builtins.any (x: x.rule == "host-directory-mismatch" && x.severity == "warning") reps
'

expect_success "8i. default.nix is the base fragment: it comes first even when a sibling sorts before it" "$PRE"'
  let r = mkM { host = "alpha"; conditionNames = cn; paths = [ (fx + "/order/hosts") ]; };
  in map (f: f.source) r.hostSources.fragments == [ "hosts/alpha/default.nix" "hosts/alpha/aaa.nix" "hosts/alpha/zzz.nix" ]
     && r.host.features == [ "niri" "gui" "amd" ]
'

expect_success "8h. source edges can be rendered as a graph" "$PRE"'
  lib.hasInfix "hosts/Inspiron14-5445/tpm2.nix"
    (m.graphLib.toMermaid { edges = m.hostsLib.sourceEdges inspiron.hosts; })
'

# ===========================================================================
# Directory discovery
# ===========================================================================

expect_success "9. paths = [ hosts modules overlays ] discovers the whole configuration" "$PRE"'
  builtins.attrNames inspiron.hosts == [ "Inspiron14-5445" ]
  && map (x: x.name) inspiron.modules == [ "constants" "git" "graphics" ]
  && builtins.attrNames inspiron.overlaysByName == [ "emacs" "floorp" ]
'

expect_success "10. hosts/test/{default,hardware}.nix are both loaded as fragments of one host" "$PRE"'
  let r = mkM { host = "test"; conditionNames = cn; paths = [ (fx + "/simple/hosts") ]; };
  in builtins.length r.hostSources.fragments == 2
     && r.host.features == [ "amd" ]
     && r.host.type.desktop
     && (evalT r "os") == { fromDefault = 1; fromHardware = 1; }
'

expect_success "10b. host identity comes from mulib.host name, not the directory" "$PRE"'
  builtins.attrNames (mkM { host = "alpha"; conditionNames = cn; paths = [ (fx + "/mismatch/hosts") ]; }).hosts == [ "alpha" "beta" ]
'

expect_failure "10c. an unknown host lists the known ones" "$PRE"'
  builtins.deepSeq (mkM { host = "nope"; conditionNames = cn; paths = [ (fx + "/simple/hosts") ]; }).host true
' "known hosts: test"

expect_success "10d. a single .nix file may be given in paths" "$PRE"'
  (mkM { host = "test"; conditionNames = cn; paths = [ (fx + "/simple/hosts/test/default.nix") ]; }).host.name == "test"
'

# A directory that is built at run time: dropping a file in is enough.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/modules" "$tmp/hosts"
cat > "$tmp/hosts/h.nix" <<'EOF'
{ mulib, ... }: mulib.host { name = "h"; system = "x86_64-linux"; }
EOF
cat > "$tmp/modules/foo.nix" <<'EOF'
{ mulib, ... }: mulib.module { name = "foo"; }
EOF
expect_success "11. modules/foo.nix is recognized" "$PRE"'
  map (x: x.name) (mkM { host = "h"; conditionNames = cn; paths = [ (/. + "'"$tmp"'/hosts") (/. + "'"$tmp"'/modules") ]; }).modules == [ "foo" ]
'
cat > "$tmp/modules/bar.nix" <<'EOF'
{ mulib, ... }: mulib.module { name = "bar"; }
EOF
expect_success "11b. adding modules/bar.nix is enough for it to be recognized" "$PRE"'
  map (x: x.name) (mkM { host = "h"; conditionNames = cn; paths = [ (/. + "'"$tmp"'/hosts") (/. + "'"$tmp"'/modules") ]; }).modules == [ "bar" "foo" ]
'
cat > "$tmp/modules/helper.nix" <<'EOF'
{ lib = 1; }
EOF
expect_success "11c. a helper file in a discovered directory is ignored" "$PRE"'
  map (x: x.name) (mkM { host = "h"; conditionNames = cn; paths = [ (/. + "'"$tmp"'/hosts") (/. + "'"$tmp"'/modules") ]; }).modules == [ "bar" "foo" ]
' 
rm "$tmp/modules/helper.nix"

# ===========================================================================
# Host configuration fragments (os / home / darwin / shared)
# ===========================================================================

expect_success "12h. host os fragments from every file are applied (Inspiron14-5445)" "$PRE"'
  evalT inspiron "os" == {
    disko = "/dev/nvme0n1"; graphics = true; hostname = "inspiron";
    initrd = "PKGS-Inspiron14-5445"; microcode = "amd"; preservation = true;
    secureboot = true; sharedFromTpm2 = true; tpm2 = true; }
'

expect_success "12i. a function fragment gets pkgs from the module system and host from mulix" "$PRE"'
  (evalT inspiron "os").initrd == "PKGS-Inspiron14-5445"
'

expect_success "12l. a host fragment can read the explicitly bound module-options configName" "$PRE"'
  let r = mkM {
    conditionNames = cn; host = "alpha";
    configNames.hostconf = { bind = "mulix.modules"; };
    hostDefs.alpha = H { os = { hostconf, ... }: { out.user = hostconf.constants.username; }; };
    modules = [ (m.module { name = "constants"; options.enable = m.mulibApi.bool.true; options.username = m.mulibApi.str "alice"; }) ];
  }; in (evalT r "os").user == "alice"
' 

expect_success "12m. a host fragment can receive a configName as an argument" "$PRE"'
  let r = mkM {
    conditionNames = cn; host = "alpha";
    configNames.openPorts = { type = T.listOf T.str; merge = "ordered"; default = []; };
    hostDefs.alpha = H { os = { openPorts, ... }: { out.ports = openPorts; }; };
    modules = [ (m.module { name = "ssh"; options.enable = m.mulibApi.bool.true; send.openPorts = [ "22/tcp" ]; }) ];
  }; in (evalT r "os").ports == [ "22/tcp" ]
'

expect_success "12j. shared applies to every target" "$PRE"'
  (evalT inspiron "home").sharedFromTpm2 && (evalT inspiron "os").sharedFromTpm2
'

expect_success "12k. os fragments do not leak into the home target" "$PRE"'
  !((evalT inspiron "home") ? tpm2)
'

# ===========================================================================
# configName bindings
# ===========================================================================

expect_success "12. an explicitly bound configName exposes config.mulix.modules" "$PRE"'
  (evalT inspiron "home").gitUser == "alice"
'

expect_failure "13. an unregistered configName is not injected implicitly" "$PRE"'
  builtins.deepSeq (mkM {
    host = "h"; conditionNames = cn;
    modules = [ ({ hostconf, mulib, ... }: mulib.module { name = "a"; }) ];
  }).modules true
' "unknown configName in receiver arguments"

expect_success "12b. the bound configName sees the actual module-system values" "$PRE"'
  let ev = lib.evalModules { modules = (inspiron.targetModuleList "home") ++ [ {
      options.out = lib.mkOption { type = T.lazyAttrsOf T.raw; default = {}; };
      config.mulix.modules.constants.username = "bob"; } ]; };
  in ev.config.out.gitUser == "bob"
'

expect_failure "14. a bound configName cannot be consumed during collection" "$PRE"'
  builtins.deepSeq
    (mkM {
      host = "h"; conditionNames = cn;
      configNames.hostconf = { bind = "mulix.modules"; };
      modules = [
        ({ hostconf, mulib, ... }:
          builtins.seq hostconf.foo
            (mulib.module { name = "a"; options.x = hostconf.foo; }))
      ];
    }).modules
    true
' "is bound to config.mulix.modules"

expect_success "14b. bound configName and ordinary configName coexist" "$PRE"'
  let r = mkM {
    host = "alpha"; conditionNames = cn;
    configNames = {
      hostconf = { bind = "mulix.modules"; };
      openPorts = { type = T.listOf T.str; merge = "ordered"; default = []; };
    };
    hostDefs.alpha = H { os = { hostconf, openPorts, ... }: {
      out.user = hostconf.constants.username;
      out.ports = openPorts;
    }; };
    modules = [
      (m.module { name = "constants"; options.enable = m.mulibApi.bool.true; options.username = m.mulibApi.str "alice"; })
      (m.module { name = "ssh"; options.enable = m.mulibApi.bool.true; send.openPorts = [ "22/tcp" ]; })
    ];
  };
  in (evalT r "os") == { user = "alice"; ports = [ "22/tcp" ]; }
'

expect_success "14c. send can target a bound configName" "$PRE"'
  let r = mkM {
    host = "alpha"; conditionNames = cn;
    configNames = {
      hostconf = { bind = "mulix.modules"; };
      source = { type = T.attrs; merge = "single"; default = {}; };
    };
    hostDefs.alpha = H { os = { hostconf, ... }: {
      out.user = hostconf.published;
      out.username = hostconf.constants.username;
    }; };
    modules = [
      (m.module { name = "constants"; options.enable = m.mulibApi.bool.true; options.username = m.mulibApi.str "alice"; })
      (m.module { name = "source"; options.enable = m.mulibApi.bool.true; send.source = { username = "alice"; }; })
      (m.module {
        name = "publisher";
        options.enable = m.mulibApi.bool.true;
        send.hostconf = { source, ... }: { published = source.username; };
      })
    ];
  };
  in (evalT r "os") == { user = "alice"; username = "alice"; }
'

expect_success "14d. force can override a bound configName" "$PRE"'
  let r = mkM {
    host = "alpha"; conditionNames = cn;
    configNames.hostconf = { bind = "mulix.modules"; };
    force.hostconf = { constants = { username = "bob"; }; };
    hostDefs.alpha = H { home = { hostconf, ... }: { out.user = hostconf.constants.username; }; };
    modules = [ (m.module { name = "constants"; options.enable = m.mulibApi.bool.true; options.username = m.mulibApi.str "alice"; }) ];
  };
  in (evalT r "home").user == "bob"
'

expect_success "15. bound configNames use the ordinary dependency graph" "$PRE"'
  let r = mkM {
    host = "h"; conditionNames = cn;
    configNames.hostconf = { bind = "mulix.modules"; };
    modules = [
      ({ hostconf, mulib, ... }: mulib.module { name = "receiver"; })
      ({ mulib, ... }: mulib.module { name = "sender"; send.hostconf = { x = 1; }; })
    ];
  };
  in builtins.elem { from = "sender"; to = "receiver"; via = "hostconf"; } r.dependencyGraph.edges
'

expect_failure "15b. cycles through bound configNames are detected by the normal dependency graph" "$PRE"'
  builtins.deepSeq (mkM {
    host = "h"; conditionNames = cn;
    configNames = {
      hostconf = { bind = "mulix.modules"; };
      other = { type = T.attrs; merge = "single"; default = {}; };
    };
    modules = [
      ({ other, mulib, ... }: mulib.module { name = "A"; send.hostconf = { x = other.x; }; })
      ({ hostconf, mulib, ... }: mulib.module { name = "B"; send.other = { x = hostconf.x; }; })
    ];
  }).dependencyGraph true
' "mulix: dependency cycle detected"

expect_failure "15c. a binding owns the target type" "$PRE"'
  builtins.deepSeq (mkM {
    host = "h"; conditionNames = cn;
    configNames.hostconf = { bind = "mulix.modules"; type = T.attrs; };
  }).host true
' "bind = \"mulix.modules\" owns the type"

expect_failure "15d. a binding owns the default" "$PRE"'
  builtins.deepSeq (mkM {
    host = "h"; conditionNames = cn;
    configNames.hostconf = { bind = "mulix.modules"; default = {}; };
  }).host true
' "bind = \"mulix.modules\" owns the default"

expect_success "16. an arbitrary configName is allowed when explicitly bound" "$PRE"'
  let r = mkM {
    host = "alpha"; conditionNames = cn;
    configNames.myconfig = { bind = "mulix.modules"; };
    hostDefs.alpha = H { home = { myconfig, ... }: { out.user = myconfig.constants.username; }; };
    modules = [ (m.module { name = "constants"; options.username = m.mulibApi.str "alice"; }) ];
  };
  in (evalT r "home").user == "alice"
'

expect_success "16b. arbitrary user-chosen bound names are supported" "$PRE"'
  let r = mkM {
    host = "h"; conditionNames = cn;
    configNames.hostconf = { bind = "mulix.modules"; };
    modules = [ (m.module { name = "constants"; options.username = m.mulibApi.str "alice"; }) ];
  };
  in builtins.elem "hostconf" (builtins.attrNames r.configGraph)
'

# ===========================================================================
# Overlays
# ===========================================================================

expect_success "19. overlays are discovered from a directory and their enable is evaluated" "$PRE"'
  builtins.attrNames inspiron.overlaysByName == [ "emacs" "floorp" ]
'

expect_success "19b. the resolved overlays compose as nixpkgs overlays" "$PRE"'
  let apply = lib.foldl (prev: ov: prev // ov { } prev) { } inspiron.overlays; in
  apply.floorp == "floorp-overlay" && apply.emacs == "emacs-overlay" && !(apply ? fm)
'

expect_success "19c. overlayModule sets nixpkgs.overlays" "$PRE"'
  builtins.length inspiron.overlayModule.nixpkgs.overlays == 2
'

expect_failure "19d. duplicate overlay names are rejected" "$PRE"'
  builtins.deepSeq (mkM { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; }; overlays = [
    (m.overlay { name = "x"; overlay = f: p: { }; }) (m.overlay { name = "x"; overlay = f: p: { }; }) ]; }).overlays true
' "duplicate overlay name(s): x"

expect_failure "19e. an overlay must be a function" "$PRE"'
  m.overlay { name = "x"; overlay = { }; }
' "must be a function"

expect_failure "19f. a raw attrset is not an overlay" "$PRE"'
  builtins.deepSeq (mkM { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; };
    overlays = [ { name = "x"; overlay = f: p: { }; } ]; }).overlays true
' "expected a mulib.overlay descriptor"

# ===========================================================================
# Option shorthands, feature conditions
# ===========================================================================

expect_success "20. all common option shorthands build the expected options" "$PRE"'
  let a = m.mulibApi;
      ev = lib.evalModules { modules = [ { options = {
        s = a.str "text";
        i = a.int 3;
        f = a.float 1.5;
        l = a.lines "x\ny";
        at = a.attrs { k = 1; };
        p = a.path ./lib;
        n = a.nullOr a.type.int null;
        e = a.enum [ "a" "b" ] "b";
        o = a.oneOf [ a.type.str a.type.int ] "x";
        ao = a.attrsOf a.type.str { k = "v"; };
        el = a.either a.type.str a.type.int 7;
      }; } ]; };
  in ev.config.s == "text" && ev.config.i == 3 && ev.config.f == 1.5
     && ev.config.l == "x\ny" && ev.config.at == { k = 1; } && ev.config.n == null
     && ev.config.e == "b" && ev.config.o == "x" && ev.config.ao == { k = "v"; } && ev.config.el == 7
'

expect_success "20a. null means no default for default-bearing shorthand helpers" "$PRE"'
  let a = m.mulibApi;
      ev = lib.evalModules { modules = [ { options = { e = a.enum [ "a" "b" ] null; s = a.str null; }; } ]; };
  in !(ev.options.e ? default) && !(ev.options.s ? default)
'


expect_success "20b. existing shorthands are unchanged" "$PRE"'
  let a = m.mulibApi; ev = lib.evalModules { modules = [ { options = {
    t = a.bool.true; f = a.bool.false; s = a.str "s"; i = a.int 3; e = a.enum [ "a" "b" ] "b"; }; } ]; };
  in ev.config.t && !ev.config.f && ev.config.s == "s" && ev.config.i == 3 && ev.config.e == "b"
'

expect_success "21. gui AND (niri OR hyprland) is evaluated as documented" "$PRE"'
  builtins.elem "graphics" (map (x: x.name) inspiron.modules)
  && (evalT inspiron "os").graphics
'

expect_success "21b. ... and is false when gui is missing" "$PRE"'
  let r = mkM { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; feat = [ "niri" ]; };
    modules = [ ({ host, mulib, ... }: mulib.module { name = "graphics";
      options.enable = [ host.feat.gui [ host.feat.niri host.feat.hyprland ] ]; os = { out.graphics = true; }; }) ]; };
  in !((evalT r "os") ? graphics)
'

expect_success "22. no <feature>Featured alias exists: host.feat.* is the API" "$PRE"'
  !(inspiron.host ? niriFeatured) && inspiron.host.feat.niri
'

finish "HOST TESTS"
