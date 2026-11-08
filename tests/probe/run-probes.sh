#!/usr/bin/env bash
# Probes for behaviours that a static code review suspects but could not run.
# NOT part of tests/runner.sh: these print what actually happens instead of
# asserting, so a human can decide whether each one is a bug.
#
#   ./tests/probe/run-probes.sh
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PRE='
  let
    lib = (import <nixpkgs> {}).lib;
    pkgs = import <nixpkgs> {};
    baseM = import ./lib { inherit lib; };
    T = lib.types;
    inlineModulePath = defs: i: let
      d = builtins.elemAt defs i;
      fa = if lib.isFunction d then lib.functionArgs d else {};
      spec = if fa == {} then "{}" else "{ " + lib.concatStringsSep "; "
        (map (n: "${n} = ${if builtins.getAttr n fa then "true" else "false"}") (builtins.attrNames fa)) + "; }";
      body = "let lib = (import <nixpkgs> {}).lib; w = args@{ __mulixTestModules, ... }: let d = builtins.elemAt args.__mulixTestModules ${toString i}; in if lib.isFunction d then d args else d; in lib.setFunctionArgs w ${spec}";
    in /. + (builtins.unsafeDiscardStringContext (builtins.toFile "probe-mod-${toString i}.nix" body));
    mkM = args: let defs = args.modules or []; in
      baseM.mkMulix ((builtins.removeAttrs args [ "modules" ]) // {
        paths = lib.imap0 (i: _: inlineModulePath defs i) defs;
        specialArgs = { __mulixTestModules = defs; };
      });
    m = baseM // { mkMulix = mkM; };
    run = { modules, configNames ? {}, target ? "os" }: let
      r = mkM {
        hostDefs.h = m.host { name = "h"; system = "x86_64-linux"; };
        host = "h"; conditionNames = {};
        inherit modules configNames;
      };
    in (lib.evalModules { modules = (r.targetModuleList target) ++ [
         { options.out = lib.mkOption { type = T.lazyAttrsOf T.raw; default = {}; }; } ]; }).config.out;
  in
'

probe() {
  local name="$1" expr="$2" out
  echo "=== $name"
  if out=$(nix eval --impure --json --expr "$PRE $expr" 2>&1); then
    echo "  RESULT: ok -> $(printf '%s' "$out" | head -c 300)"
  else
    echo "  RESULT: error"
    printf '%s\n' "$out" | grep -v '^\s*$' | grep -E "error:|mulix:|option|imports" | head -n 4 | sed 's/^/    /'
  fi
  echo
}

# P1: can a module's `os` fragment use `imports`?  (suspected: no, it is
#     wrapped as `config = mkIf enable frag`).
probe "P1a: os = { imports = [...]; } (conditional fragment)" '
  run { modules = [ (m.module { name = "a";
    options.enable = lib.mkOption { type = T.bool; default = true; };
    os = { imports = [ { out.x = 1; } ]; }; }) ]; }
'
# P1b: the suggested workaround.
probe "P1b: always.os with its own mkIf (workaround)" '
  run { modules = [ (m.module { name = "a";
    options.enable = lib.mkOption { type = T.bool; default = true; };
    always.os = { imports = [ { out.x = 1; } ]; }; }) ]; }
'

# P2: does the eager `deepSeq` in validateType choke on a package-typed value?
probe "P2: configName of type listOf package, ordered, one derivation" '
  let r = run {
    configNames.pk = { type = T.listOf T.package; merge = "ordered"; default = []; };
    modules = [
      (m.module { name = "s"; options.enable = lib.mkOption { type = T.bool; default = true; };
                  send.pk = [ pkgs.hello ]; })
      (m.module { name = "r"; options.enable = lib.mkOption { type = T.bool; default = true; };
                  os = { pk, ... }: { out.n = builtins.length pk; }; })
    ]; };
  in r.n
'


# P2 bisect: where does the stack overflow come from?
probe "P2a: deepSeq on a package alone" 'builtins.deepSeq pkgs.hello true'
probe "P2b: control, listOf str through the same path" '
  (run {
    configNames.pk = { type = T.listOf T.str; merge = "ordered"; default = []; };
    modules = [
      (m.module { name = "s"; options.enable = lib.mkOption { type = T.bool; default = true; }; send.pk = [ "x" ]; })
      (m.module { name = "r"; options.enable = lib.mkOption { type = T.bool; default = true; };
                  os = { pk, ... }: { out.n = builtins.length pk; }; })
    ]; }).n'
probe "P2c: listOf raw holding a package (check is trivial, deepSeq still reaches it)" '
  (run {
    configNames.pk = { type = T.listOf T.raw; merge = "ordered"; default = []; };
    modules = [
      (m.module { name = "s"; options.enable = lib.mkOption { type = T.bool; default = true; }; send.pk = [ pkgs.hello ]; })
      (m.module { name = "r"; options.enable = lib.mkOption { type = T.bool; default = true; };
                  os = { pk, ... }: { out.n = builtins.length pk; }; })
    ]; }).n'

# P3: does an `enable` default derived from a configName see a DISABLED
#     module'"'"'s send? (static view)  expected by the reading: yes -> true.
probe "P3: enable derived from configName is affected by a disabled sender" '
  run {
    configNames.wm = { type = T.attrs; merge = "single"; default = { bar = "none"; }; };
    modules = [
      (m.module { name = "off"; options.enable = lib.mkOption { type = T.bool; default = false; };
                  send.wm = { bar = "waybar"; }; })
      ({ wm, mulib, ... }: mulib.module { name = "bar";
        options.enable = lib.mkOption { type = T.bool; default = wm.bar == "waybar"; };
        os.out.bar = "enabled"; })
    ];
  }
'

# P4: cost of the double mkMulix per host.  Function calls for 1 vs 8 hosts;
#     a ratio far above 8 would indicate super-linear fleet cost.
stat() {
  local n="$1" f
  f=$(mktemp)
  NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$f" nix eval --impure --json --expr "
    $PRE
    let c = baseM.configurations {
      hostDefs = lib.genAttrs (map (i: \"h\${toString i}\") (lib.range 1 $n))
        (name: m.host { inherit name; system = \"x86_64-linux\"; });
      conditionNames = {}; pkgsFor = _: null;
    }; in builtins.deepSeq (lib.mapAttrs (_: r: r.host.system) c.raw) true" >/dev/null 2>&1
  grep -o '"nrFunctionCalls": *[0-9]*' "$f" | grep -o '[0-9]*$'
  rm -f "$f"
}
echo "=== P4: fleet scaling (nrFunctionCalls)"
c1=$(stat 1); c8=$(stat 8)
echo "  1 host : ${c1:-n/a}"
echo "  8 hosts: ${c8:-n/a}"
if [ -n "${c1:-}" ] && [ -n "${c8:-}" ] && [ "$c1" -gt 0 ]; then
  echo "  ratio  : $(( c8 * 10 / c1 ))/10  (linear = 8.0; much larger = super-linear)"
fi
