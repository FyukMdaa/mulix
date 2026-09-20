#!/usr/bin/env bash
# Host composition, directory discovery, `myconfig` (module state), overlays.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=tests/lib.sh
. "$ROOT_DIR/tests/lib.sh"

PRE='
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; }; T = lib.types;
    cn = {
      type = [ "laptop" "desktop" ];
      feat = [ "gui" "niri" "amd" "gaming" "hyprland" "preservation" "secureboot" "tpm2" ];
      role = [ "desktop" "gaming" ];
    };
    H = attrs: m.host ({ name = "alpha"; } // attrs);
    mkH = frags: m.mkMulix { hostDefs.alpha = frags; host = "alpha"; conditionNames = cn; };
    fx = ./tests/fixtures;
    inspiron = m.mkMulix {
      host = "Inspiron14-5445"; conditionNames = cn;
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
  builtins.deepSeq (m.mkMulix { hostDefs.alpha = H { }; host = "alpha"; conditionNames = { is = [ "laptop" ]; }; }).host true
' "conditionNames.is is reserved for generated state"

expect_success "7d. is is generated from system, type, role and feat" "$PRE"'
  let is = (mkH [ (H { system = "x86_64-linux"; type = "laptop"; role = [ "gaming" ]; feat = [ "niri" ]; }) ]).host.is;
  in is.linux && is.x86_64 && !is.darwin && is.laptop && is.gaming && is.niri && !is.gui
'

expect_failure "7e. a feature named like a system flag is rejected" "$PRE"'
  builtins.deepSeq (m.mkMulix {
    hostDefs.alpha = H { system = "x86_64-linux"; feat = [ "linux" ]; }; host = "alpha";
    conditionNames = { feat = [ "linux" ]; };
  }).host true
' "system-derived host.is flags"

expect_failure "7f. unknown host field is a typo error with a suggestion" "$PRE"'
  H { featt = [ "gui" ]; }
' "did you mean"

expect_failure "7g. hostDefs key must equal the host name" "$PRE"'
  builtins.deepSeq (m.mkMulix { hostDefs.beta = H { }; host = "beta"; conditionNames = cn; }).host true
' "host identity mismatch"

expect_failure "7h. undeclared feature is still rejected" "$PRE"'
  builtins.deepSeq (mkH [ (H { feat = [ "not-declared" ]; }) ]).host true
' "undeclared feat condition"

# ===========================================================================
# Source tracking / diagnostics
# ===========================================================================

expect_failure "8. conflict from files shows both source files" "$PRE"'
  builtins.deepSeq (m.mkMulix { host = "alpha"; conditionNames = cn; paths = [ (fx + "/conflict/hosts") ]; }).host true
' "source: hosts/alpha/workstation.nix"

expect_failure "8b. ... and the other one" "$PRE"'
  builtins.deepSeq (m.mkMulix { host = "alpha"; conditionNames = cn; paths = [ (fx + "/conflict/hosts") ]; }).host true
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
  let r = m.mkMulix { host = "alpha"; conditionNames = cn; paths = [ (fx + "/mismatch/hosts") ]; };
      reps = (m.diagnosticsLib.run { modules = r.modules; registry = {}; hosts = r.hosts; hostFragments = r.hostFragments; }).reports;
  in builtins.attrNames r.hosts == [ "alpha" "beta" ]
     && builtins.any (x: x.rule == "host-directory-mismatch" && x.severity == "warning") reps
'

expect_success "8i. default.nix is the base fragment: it comes first even when a sibling sorts before it" "$PRE"'
  let r = m.mkMulix { host = "alpha"; conditionNames = cn; paths = [ (fx + "/order/hosts") ]; };
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
  let r = m.mkMulix { host = "test"; conditionNames = cn; paths = [ (fx + "/simple/hosts") ]; };
  in builtins.length r.hostSources.fragments == 2
     && r.host.features == [ "amd" ]
     && r.host.type.desktop
     && (evalT r "os") == { fromDefault = 1; fromHardware = 1; }
'

expect_success "10b. host identity comes from mulib.host name, not the directory" "$PRE"'
  builtins.attrNames (m.mkMulix { host = "alpha"; conditionNames = cn; paths = [ (fx + "/mismatch/hosts") ]; }).hosts == [ "alpha" "beta" ]
'

expect_failure "10c. an unknown host lists the known ones" "$PRE"'
  builtins.deepSeq (m.mkMulix { host = "nope"; conditionNames = cn; paths = [ (fx + "/simple/hosts") ]; }).host true
' "known hosts: test"

expect_success "10d. a single .nix file may be given in paths" "$PRE"'
  (m.mkMulix { host = "test"; conditionNames = cn; paths = [ (fx + "/simple/hosts/test/default.nix") ]; }).host.name == "test"
'

expect_success "10e. `modules = ./dir` keeps working next to `paths`" "$PRE"'
  map (x: x.name) (m.mkMulix {
    host = "test"; conditionNames = cn;
    paths = [ (fx + "/simple/hosts") ];
    modules = fx + "/inspiron/modules";
  }).modules == [ "constants" "git" "graphics" ]
'

expect_success "10f. legacy modules and discovered modules are both present, in that order" "$PRE"'
  map (x: x.name) (m.mkMulix {
    host = "test"; conditionNames = cn;
    paths = [ (fx + "/simple/modules") (fx + "/simple/hosts") ];
    modules = [ (m.module { name = "explicit"; }) ];
  }).modules == [ "explicit" "foo" ]
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
  map (x: x.name) (m.mkMulix { host = "h"; conditionNames = cn; paths = [ (/. + "'"$tmp"'/hosts") (/. + "'"$tmp"'/modules") ]; }).modules == [ "foo" ]
'
cat > "$tmp/modules/bar.nix" <<'EOF'
{ mulib, ... }: mulib.module { name = "bar"; }
EOF
expect_success "11b. adding modules/bar.nix is enough for it to be recognized" "$PRE"'
  map (x: x.name) (m.mkMulix { host = "h"; conditionNames = cn; paths = [ (/. + "'"$tmp"'/hosts") (/. + "'"$tmp"'/modules") ]; }).modules == [ "bar" "foo" ]
'
cat > "$tmp/modules/helper.nix" <<'EOF'
{ lib = 1; }
EOF
expect_failure "11c. a helper file in a discovered directory is reported, not ignored" "$PRE"'
  builtins.deepSeq (m.mkMulix { host = "h"; conditionNames = cn; paths = [ (/. + "'"$tmp"'/hosts") (/. + "'"$tmp"'/modules") ]; }).modules true
' "unrecognized file in paths"
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

expect_success "12l. a host fragment can read module state through myconfig" "$PRE"'
  let r = m.mkMulix {
    conditionNames = cn; host = "alpha";
    hostDefs.alpha = H { os = { myconfig, ... }: { out.user = myconfig.constants.username; }; };
    modules = [ (m.module { name = "constants"; options.enable = m.mulibApi.bool.true; options.username = m.mulibApi.str "alice"; }) ];
  }; in (evalT r "os").user == "alice"
'

expect_success "12m. a host fragment can receive a configName as an argument" "$PRE"'
  let r = m.mkMulix {
    conditionNames = cn; host = "alpha";
    configNames.openPorts = { type = T.listOf T.str; merge = "ordered"; default = []; };
    hostDefs.alpha = H { os = { openPorts, ... }: { out.ports = openPorts; }; };
    modules = [ (m.module { name = "ssh"; options.enable = m.mulibApi.bool.true; send.openPorts = [ "22/tcp" ]; }) ];
  }; in (evalT r "os").ports == [ "22/tcp" ]
'

expect_success "12j. `shared` applies to every target" "$PRE"'
  (evalT inspiron "home").sharedFromTpm2 && (evalT inspiron "os").sharedFromTpm2
'

expect_success "12k. os fragments do not leak into the home target" "$PRE"'
  !((evalT inspiron "home") ? tpm2)
'

# ===========================================================================
# myconfig = config.mulix.modules
# ===========================================================================

expect_success "12. a module reads another module state through myconfig" "$PRE"'
  (evalT inspiron "home").gitUser == "alice"
'

expect_success "13. no configName registration is needed for it" "$PRE"'
  inspiron.dependencyGraph.edges != [] && (m.mkMulix { host = "Inspiron14-5445"; conditionNames = cn; configNames = {};
    paths = [ (fx + "/inspiron/hosts") (fx + "/inspiron/modules") ]; }).modules != []
'

expect_success "12b. myconfig IS config.mulix.modules (a value set there is what is read)" "$PRE"'
  let ev = lib.evalModules { modules = (inspiron.targetModuleList "home") ++ [ {
      options.out = lib.mkOption { type = T.lazyAttrsOf T.raw; default = {}; };
      config.mulix.modules.constants.username = "bob"; } ]; };
  in ev.config.out.gitUser == "bob"
'

expect_failure "14. reading a module that does not exist is an explicit error" "$PRE"'
  (evalT (m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; }; modules = [
    (m.module { name = "a"; options.enable = m.mulibApi.bool.true; os = { myconfig, ... }: { out.x = myconfig.notExist.foo; }; }) ]; }) "os").x
' "notExist"

expect_failure "14b. an explicit reads naming a missing module is rejected with a suggestion" "$PRE"'
  builtins.deepSeq (m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; }; modules = [
    (m.module { name = "constants"; })
    (m.module { name = "git"; reads = [ "constnts" ]; }) ]; }).modules true
' "reads an unknown module"

cat > "$tmp/modules/typo.nix" <<'EOF'
{ mulib, ... }:
mulib.module {
  name = "typo";
  os = { myconfig, ... }: { out.x = myconfig.constant.username; };
}
EOF
cat > "$tmp/modules/constants.nix" <<'EOF'
{ mulib, ... }: mulib.module { name = "constants"; options.username = mulib.str "u"; }
EOF
expect_success "14c. an inferred read of a missing module is reported by diagnostics (with a suggestion)" "$PRE"'
  let r = m.mkMulix { host = "h"; conditionNames = cn; paths = [ (/. + "'"$tmp"'/hosts") (/. + "'"$tmp"'/modules") ]; };
      reps = (m.diagnosticsLib.run { modules = r.modules; registry = {}; }).reports;
      bad = builtins.filter (x: x.rule == "myconfig-unknown-module") reps;
  in builtins.length bad == 1 && lib.hasInfix "constant" (builtins.head bad).message && lib.hasInfix "did you mean" (builtins.head bad).message
'
rm "$tmp/modules/typo.nix" "$tmp/modules/constants.nix"

expect_failure "15. an option type error in module state is detected as usual" "$PRE"'
  (lib.evalModules { modules = (inspiron.targetModuleList "home") ++ [ {
      options.out = lib.mkOption { type = T.lazyAttrsOf T.raw; default = {}; };
      config.mulix.modules.constants.username = 5; } ]; }).config.out.gitUser
' "is not of type"

expect_success "16. the dependency graph shows git reading constants" "$PRE"'
  builtins.elem { from = "constants"; to = "git"; via = "module-state"; kind = "module-state"; } inspiron.dependencyGraph.edges
'

expect_success "16b. module-state edges are drawn dashed (mermaid and dot)" "$PRE"'
  lib.hasInfix "-.->|module-state|" (m.graphLib.toMermaid { edges = inspiron.dependencyGraph.edges; })
  && lib.hasInfix "style=dashed" (m.graphLib.toDot { edges = inspiron.dependencyGraph.edges; })
'

expect_success "16c. a module reading its own state is not a dependency" "$PRE"'
  (m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; }; modules = [
    (m.module { name = "a"; reads = [ "a" ]; }) ]; }).dependencyGraph.edges == []
'

cat > "$tmp/modules/a.nix" <<'EOF'
{ mulib, ... }:
mulib.module { name = "A"; home = { myconfig, ... }: { out.a = myconfig.B.x; }; }
EOF
cat > "$tmp/modules/b.nix" <<'EOF'
{ mulib, ... }:
mulib.module { name = "B"; home = { myconfig, ... }: { out.b = myconfig.A.y; }; }
EOF
expect_failure "17. a module-state cycle between files is detected" "$PRE"'
  builtins.deepSeq (m.mkMulix { host = "h"; conditionNames = cn; paths = [ (/. + "'"$tmp"'/hosts") (/. + "'"$tmp"'/modules") ]; }).dependencyGraph true
' "mulix: module-state dependency cycle detected"

expect_failure "17b. ... and the message names the modules and the edge kind" "$PRE"'
  builtins.deepSeq (m.mkMulix { host = "h"; conditionNames = cn; paths = [ (/. + "'"$tmp"'/hosts") (/. + "'"$tmp"'/modules") ]; }).dependencyGraph true
' "--module-state-->"
rm "$tmp/modules/a.nix" "$tmp/modules/b.nix"

expect_failure "17c. an explicit-reads cycle is detected too" "$PRE"'
  builtins.deepSeq (m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; }; modules = [
    (m.module { name = "A"; reads = [ "B" ]; }) (m.module { name = "B"; reads = [ "A" ]; }) ]; }).dependencyGraph true
' "module-state dependency cycle detected"

expect_failure "17d. one cycle check covers configName and module-state edges together" "$PRE"'
  builtins.deepSeq (m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; };
    configNames.foo = { type = T.listOf T.int; merge = "ordered"; default = []; };
    modules = [
      (m.module { name = "P"; send.foo = [ 1 ]; reads = [ "Q" ]; })
      ({ foo, mulib, ... }: mulib.module { name = "Q"; })
    ]; }).dependencyGraph true
' "dependency cycle detected"

expect_success "17e. `reads = []` switches inference off for that module" "$PRE"'
  (m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; }; modules = [
    (m.module { name = "A"; reads = [ ]; }) (m.module { name = "B"; reads = [ "A" ]; }) ]; }).dependencyGraph.edges
    == [ { from = "A"; to = "B"; via = "module-state"; kind = "module-state"; } ]
'

expect_success "18. myconfig and a configName coexist without interfering" "$PRE"'
  let r = m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; };
    configNames.openPorts = { type = T.listOf T.str; merge = "ordered"; default = []; };
    modules = [
      (m.module { name = "constants"; options.enable = m.mulibApi.bool.true; options.user = m.mulibApi.str "alice"; })
      (m.module { name = "ssh"; options.enable = m.mulibApi.bool.true; send.openPorts = [ "22/tcp" ]; })
      (m.module { name = "firewall"; options.enable = m.mulibApi.bool.true;
        os = { openPorts, myconfig, ... }: { out.ports = openPorts; out.user = myconfig.constants.user; }; })
    ]; };
  in (evalT r "os") == { ports = [ "22/tcp" ]; user = "alice"; }
'

expect_success "18b. myconfig is not a configName: it cannot be registered as one" "$PRE"'
  (builtins.tryEval (builtins.deepSeq (m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; };
    configNames.myconfig = { type = T.attrs; merge = "single"; default = {}; }; modules = []; }).host true)).success == false
'

expect_success "18c. myconfig is also available in send functions" "$PRE"'
  let r = m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; };
    configNames.who = { type = T.listOf T.str; merge = "ordered"; default = []; };
    modules = [
      (m.module { name = "constants"; options.enable = m.mulibApi.bool.true; options.user = m.mulibApi.str "alice"; })
      (m.module { name = "s"; options.enable = m.mulibApi.bool.true; send.who = { myconfig, ... }: [ myconfig.constants.user ]; })
      (m.module { name = "r"; options.enable = m.mulibApi.bool.true; os = { who, ... }: { out.who = who; }; })
    ]; };
  in (evalT r "os").who == [ "alice" ]
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
  builtins.deepSeq (m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; }; overlays = [
    (m.overlay { name = "x"; overlay = f: p: { }; }) (m.overlay { name = "x"; overlay = f: p: { }; }) ]; }).overlays true
' "duplicate overlay name(s): x"

expect_failure "19e. an overlay must be a function" "$PRE"'
  m.overlay { name = "x"; overlay = { }; }
' "must be a function"

expect_failure "19f. a raw attrset is not an overlay" "$PRE"'
  builtins.deepSeq (m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; };
    overlays = [ { name = "x"; overlay = f: p: { }; } ]; }).overlays true
' "expected a mulib.overlay descriptor"

# ===========================================================================
# Option shorthands, feature conditions
# ===========================================================================

expect_success "20. new shorthands build the expected options" "$PRE"'
  let a = m.mulibApi;
      ev = lib.evalModules { modules = [ { options = {
        l = a.listOf a.type.str [ "x" ]; at = a.attrs { k = 1; }; p = a.path ./lib; n = a.nullOr a.type.int null;
      }; } ]; };
  in ev.config.l == [ "x" ] && ev.config.at == { k = 1; } && ev.config.n == null
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
  let r = m.mkMulix { host = "h"; conditionNames = cn; hostDefs.h = m.host { name = "h"; feat = [ "niri" ]; };
    modules = [ ({ host, mulib, ... }: mulib.module { name = "graphics";
      options.enable = [ host.feat.gui [ host.feat.niri host.feat.hyprland ] ]; os = { out.graphics = true; }; }) ]; };
  in !((evalT r "os") ? graphics)
'

expect_success "22. no <feature>Featured alias exists: host.feat.* is the API" "$PRE"'
  !(inspiron.host ? niriFeatured) && inspiron.host.feat.niri
'

finish "HOST TESTS"
