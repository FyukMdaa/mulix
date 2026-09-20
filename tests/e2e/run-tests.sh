#!/usr/bin/env bash
# End-to-end: mkMulix -> targetModuleList -> lib.evalModules.
# Unlike the api-contract suite (which inspects mkMulix results), these cases
# evaluate the generated NixOS-style modules, i.e. what a target really sees.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=tests/lib.sh
. "$ROOT_DIR/tests/lib.sh"

PRE='
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    T = lib.types;
    en = { enable = lib.mkOption { type = T.bool; default = true; }; };
    reg = merge: type: { inherit type merge; };
    # `outType`: lazyAttrsOf lets a fragment read `config.out.x` while defining
    # `out.y`; attrsOf drops keys whose only definition is `mkIf false`.
    mkRun = outType: { modules, configNames ? {}, force ? {}, target ? "os" }:
      let
        r = m.mkMulix {
          hostDefs.h = m.host { name = "h"; system = "x86_64-linux"; };
          host = "h"; conditionNames = {};
          inherit modules configNames force;
        };
        ev = lib.evalModules {
          modules = (r.targetModuleList target) ++ [
            { options.out = lib.mkOption { type = outType; default = {}; }; }
          ];
        };
      in { inherit r; out = ev.config.out; };
    run = mkRun (T.lazyAttrsOf T.raw);
    runA = mkRun (T.attrsOf T.raw);
  in
'

expect_success "enable / always / function fragments" "$PRE"'
  (run { modules = [
    (m.module { name = "a"; options = en; os.out.a = 1; })
    (m.module { name = "b"; os.out.b = 2; })
    (m.module { name = "c"; always.os.out.c = 3; })
    (m.module { name = "d"; options = en; os = { config, ... }: { out.d = config.out.a + 10; }; })
  ]; }).out == { a = 1; c = 3; d = 11; }
'

expect_success "configName received at module top level and in a fragment" "$PRE"'
  (run {
    configNames.wm = { type = T.attrs; merge = "single"; default = { bar = "none"; }; };
    modules = [
      (m.module { name = "niri"; options = en; send.wm = { bar = "waybar"; }; })
      ({ wm, mulib, ... }: mulib.module { name = "top"; options = en; os.out.top = wm.bar; })
      (m.module { name = "frag"; options = en; os = { wm, ... }: { out.frag = wm.bar; }; })
    ];
  }).out == { top = "waybar"; frag = "waybar"; }
'

expect_success "options may be a function" "$PRE"'
  (run { modules = [
    (m.module { name = "o"; options = { mkOption, ... }: { enable = mkOption { type = T.bool; default = true; }; }; os.out.o = 1; })
  ]; }).out == { o = 1; }
'

expect_success "send function sees opt; disabled sender is excluded at target time" "$PRE"'
  (run {
    configNames.c = reg "ordered" (T.listOf T.str);
    modules = [
      (m.module { name = "s1"; options = en // { w = lib.mkOption { type = T.str; default = "on"; }; }; send.c = { opt, ... }: [ opt.w ]; })
      (m.module { name = "s2"; options.enable = lib.mkOption { type = T.bool; default = false; }; send.c = [ "off" ]; })
      (m.module { name = "r"; options = en; os = { c, ... }: { out.c = c; }; })
    ];
  }).out.c == [ "on" ]
'

expect_success "always.send from a disabled module IS visible at target time" "$PRE"'
  (run {
    configNames.c = reg "ordered" (T.listOf T.str);
    modules = [
      (m.module { name = "s"; options.enable = lib.mkOption { type = T.bool; default = false; }; always.send.c = [ "always" ]; })
      (m.module { name = "r"; options = en; os = { c, ... }: { out.c = c; }; })
    ];
  }).out.c == [ "always" ]
'

expect_success "send -> send chain" "$PRE"'
  (run {
    configNames = { a = reg "ordered" (T.listOf T.str); b = reg "ordered" (T.listOf T.str); };
    modules = [
      (m.module { name = "sa"; options = en; send.a = [ "x" ]; })
      (m.module { name = "sb"; options = en; send.b = { a, ... }: map (v: v + "!") a; })
      (m.module { name = "r"; options = en; os = { b, ... }: { out.b = b; }; })
    ];
  }).out.b == [ "x!" ]
'

expect_success "target-time: mkBefore / mkAfter / mkOrder" "$PRE"'
  (run {
    configNames.l = reg "ordered" (T.listOf T.int);
    modules = [
      (m.module { name = "a"; options = en; send.l = lib.mkAfter [ 3 ]; })
      (m.module { name = "b"; options = en; send.l = [ 2 ]; })
      (m.module { name = "c"; options = en; send.l = lib.mkBefore [ 1 ]; })
      (m.module { name = "d"; options = en; send.l = lib.mkOrder 2000 [ 4 ]; })
      (m.module { name = "r"; options = en; os = { l, ... }: { out.l = l; }; })
    ];
  }).out.l == [ 1 2 3 4 ]
'

expect_success "target-time: nested mkDefault loses to a normal definition" "$PRE"'
  (run {
    configNames.c = reg "single" T.attrs;
    modules = [
      (m.module { name = "a"; options = en; send.c = { v = lib.mkDefault 1; }; })
      (m.module { name = "b"; options = en; send.c = { v = 2; }; })
      (m.module { name = "r"; options = en; os = { c, ... }: { out.c = c; }; })
    ];
  }).out.c == { v = 2; }
'

expect_failure "deep registry type check rejects wrong element types" "$PRE"'
  (run {
    configNames.l = reg "ordered" (T.listOf T.str);
    modules = [
      (m.module { name = "s"; options = en; send.l = [ 1 2 3 ]; })
      (m.module { name = "r"; options = en; os = { l, ... }: { out.l = l; }; })
    ];
  }).out.l
' "is not of type"

expect_success "force can pin a value to null" "$PRE"'
  (run {
    configNames.f = { type = T.nullOr T.bool; merge = "single"; default = true; };
    force.f = null;
    modules = [ (m.module { name = "r"; options = en; os = { f, ... }: { out.f = f; }; }) ];
  }).out.f == null
'

expect_success "host.is.darwin exists (false) on a Linux-only fleet" "$PRE"'
  (run { modules = [
    ({ host, mulib, ... }: mulib.module {
      name = "h"; options.enable = [ host.is.linux ]; os.out.d = host.is.darwin;
    })
  ]; }).out == { d = false; }
'

expect_success "enable condition list: AND at top level, OR in nested lists" "$PRE"'
  (run { modules = [
    ({ host, mulib, ... }: mulib.module { name = "yes"; options.enable = [ host.is.linux [ host.is.darwin host.is.x86_64 ] ]; os.out.yes = true; })
    ({ host, mulib, ... }: mulib.module { name = "no"; options.enable = [ host.is.linux host.is.darwin ]; os.out.no = true; })
  ]; }).out == { yes = true; }
'

expect_success "home target selects home fragments only" "$PRE"'
  (run { target = "home"; modules = [
    (m.module { name = "x"; options = en; home.out.h = 1; os.out.o = 2; })
  ]; }).out == { h = 1; }
'

expect_failure "invalid target is rejected" "$PRE"'
  (run { target = "wat"; modules = []; }).out
' "invalid target"

expect_failure "unknown fragment argument is rejected as an unknown configName" "$PRE"'
  (run { modules = [ (m.module { name = "p"; options = en; os = { definitelyNotAConfigName, ... }: { out.p = 1; }; }) ]; }).out
' "unknown configName in receiver arguments"

expect_success "exported configGraph (static) vs target view (enable-filtered)" "$PRE"'
  let x = run {
    configNames.c = { type = T.listOf T.str; merge = "ordered"; default = [ ]; };
    modules = [
      (m.module { name = "s"; options.enable = lib.mkOption { type = T.bool; default = false; }; send.c = [ "from-disabled" ]; })
      (m.module { name = "r"; options = en; os = { c, ... }: { out.c = c; }; })
    ];
  };
  in x.r.configGraph.c == [ "from-disabled" ] && x.out.c == [ ]
'

expect_success "target-time: a conditionally empty send does not suppress another module's mkDefault" "$PRE"'
  (run {
    configNames.c = reg "single" T.attrs;
    modules = [
      (m.module { name = "maybe"; options = en; send.c = lib.optionalAttrs false { x = 1; }; })
      (m.module { name = "b"; options = en; send.c = { v = lib.mkDefault 1; }; })
      (m.module { name = "r"; options = en; os = { c, ... }: { out.c = c; }; })
    ];
  }).out.c == { v = 1; }
'

# ---------------------------------------------------------------------------
# `ifDisabled` evaluation.  Decision: NOT added.  The three use cases below are
# all expressed by `always.<target>` + `opt` + mkIf, with no new syntax; they
# are pinned here so the idiom stays supported.
# ---------------------------------------------------------------------------

expect_success "ifDisabled #1 GPU fallback: enabled -> GPU config, disabled -> framebuffer" "$PRE"'
  let gpu = enable: m.module {
        name = "gpu";
        options.enable = lib.mkOption { type = T.bool; default = enable; };
        os.out.gpu = "driver";
        always.os = { opt, ... }: { out.display = lib.mkIf (!opt.enable) "framebuffer"; };
      };
      on = (runA { modules = [ (gpu true) ]; }).out;
      off = (runA { modules = [ (gpu false) ]; }).out;
  in on == { gpu = "driver"; } && off == { display = "framebuffer"; }
'

expect_success "ifDisabled #2 GUI / CLI: one always fragment picks the branch" "$PRE"'
  let ui = enable: m.module {
        name = "ui";
        options.enable = lib.mkOption { type = T.bool; default = enable; };
        os.out.tools = "gui-tools";
        always.os = { opt, ... }: { out.mode = if opt.enable then "gui" else "cli"; };
      };
  in (runA { modules = [ (ui true) ]; }).out == { tools = "gui-tools"; mode = "gui"; }
     && (runA { modules = [ (ui false) ]; }).out == { mode = "cli"; }
'


expect_success "ifDisabled #3 service fallback: another module reads the state via myconfig" "$PRE"'
  let mods = enable: [
        (m.module { name = "primary"; options.enable = lib.mkOption { type = T.bool; default = enable; }; os.out.service = "primary"; })
        (m.module {
          name = "fallback";
          options.enable = m.mulibApi.bool.true;
          os = { myconfig, ... }: { out.fallback = lib.mkIf (!myconfig.primary.enable) "alternative"; };
        })
      ];
  in (runA { modules = mods true; }).out == { service = "primary"; }
     && (runA { modules = mods false; }).out == { fallback = "alternative"; }
'

# Directory collection, including a symlinked module file.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/real" "$tmp/mods"
cat > "$tmp/mods/10-a.nix" <<'EOF'
{ mulib, host, ... }: mulib.module {
  name = "a";
  options.enable = mulib.mkOption { type = mulib.types.bool; default = true; };
  os.out.a = host.system;
}
EOF
cat > "$tmp/real/ext.nix" <<'EOF'
{ mulib, ... }: mulib.module {
  name = "linked";
  options.enable = mulib.mkOption { type = mulib.types.bool; default = true; };
  os.out.linked = 1;
}
EOF
ln -s ../real/ext.nix "$tmp/mods/20-linked.nix"

expect_success "directory modules, including a symlinked file" "$PRE"'
  (run { modules = /. + "'"$tmp/mods"'"; }).out == { a = "x86_64-linux"; linked = 1; }
'

finish "E2E TESTS"
