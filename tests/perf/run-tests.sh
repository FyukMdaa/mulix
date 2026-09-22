#!/usr/bin/env bash
# Scaling guards.  Wall-clock time is machine dependent, so these count Nix
# function calls (deterministic): doubling the number of modules must roughly
# double the work.  Linear code measures ~2.0; anything quadratic measures ~4.
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=tests/lib.sh
. "$ROOT_DIR/tests/lib.sh"

SMALL=300
LARGE=600
MAX_RATIO_X10=25   # ratio must be < 2.5

# calls STRATEGY N : Nix function-call count for mkMulix + target evaluation
# with N modules all sending to one configName.
calls() {
  local label="$1" n="$2" strategy type default send read stats
  strategy="$label"
  case "$strategy" in
    ordered)
      type='T.listOf T.int'; default='[ ]'; send='[ i ]'; read='builtins.length c' ;;
    ordered-fn)
      # function-valued send that actually reads `opt`
      strategy=ordered
      type='T.listOf T.int'; default='[ ]'
      send='{ opt, ... }: [ (if opt.enable then i else 0) ]'; read='builtins.length c' ;;
    *)
      type='T.attrs'; default='{ }'
      send='{ "k${toString i}" = { a = i; b = i; }; }'
      read='builtins.length (builtins.attrNames c)' ;;
  esac
  # Materialize N sender modules + 1 receiver module as real files in a real
  # directory, and let `paths` discovery find them the normal way.
  #
  # This used to generate each module as a `builtins.toFile` store path and
  # feed those paths straight to `collectPaths` (bypassing `listNixFiles`'s
  # directory walk entirely). That relied on the store path being readable
  # via a plain filesystem stat immediately after `toFile` was forced. It
  # isn't: a `toFile` store path is only guaranteed to exist on disk once
  # something has actually *realised* it, which plain `nix-instantiate
  # --eval` never does, so `entryType`'s `readDir`/`readFileType` (and even
  # `import`/`readFile`) can hit ENOENT on a path that Nix itself just
  # computed. Real files sidestep that, and are a closer match for what
  # `collectPaths`/`listNixFiles` actually handles in production: a
  # directory of on-disk `.nix` files.
  #
  # Filenames are zero-padded so lexicographic sort (what `listNixFiles`
  # uses) agrees with the intended 0..N module order — required for the
  # `ordered`/`ordered-fn` strategies to see the modules in the right order
  # once N passes 9.
  local moddir width i
  moddir=$(mktemp -d)
  width=${#n}
  i=0
  while [ "$i" -lt "$n" ]; do
    printf 'let lib = (import <nixpkgs> {}).lib; wrapper = args@{ __mulixTestModules, ... }: let d = builtins.elemAt args.__mulixTestModules %d; in if lib.isFunction d then d args else d; in lib.setFunctionArgs wrapper { }' \
      "$i" > "$moddir/mod$(printf "%0${width}d" "$i").nix"
    i=$((i + 1))
  done
  # The receiver ({ c, mulib, ... }: ...) is a function, unlike the senders
  # (plain mulib.module attrsets), so its wrapper must advertise the same
  # `functionArgs` shape mulix's static receiver-arg check expects.
  printf 'let lib = (import <nixpkgs> {}).lib; wrapper = args@{ __mulixTestModules, ... }: let d = builtins.elemAt args.__mulixTestModules %d; in if lib.isFunction d then d args else d; in lib.setFunctionArgs wrapper { c = false; mulib = false; }' \
    "$n" > "$moddir/mod$(printf "%0${width}d" "$n").nix"

  stats=$(mktemp)
  local expr
  expr=$(cat <<EOF
let
  lib = (import <nixpkgs> {}).lib;
  m = import ./lib { inherit lib; };
  T = lib.types;
  N = $n;
  en = { enable = lib.mkOption { type = T.bool; default = true; }; };
  senders = map (i: m.module { name = "s\${toString i}"; options = en; send.c = $send; }) (lib.range 1 N);
  receiver = { c, mulib, ... }: mulib.module { name = "r"; options = en; os.out.n = $read; };
  r = m.mkMulix {
    hostDefs.h = m.host { name = "h"; system = "x86_64-linux"; };
    host = "h"; conditionNames = {};
    configNames.c = { type = $type; merge = "$strategy"; default = $default; };
    paths = [ (/. + "$moddir") ];
    specialArgs.__mulixTestModules = senders ++ [ receiver ];
  };
in (lib.evalModules {
  modules = (r.targetModuleList "os") ++ [
    { options.out = lib.mkOption { type = T.lazyAttrsOf T.raw; default = {}; }; }
  ];
}).config.out.n
EOF
  )
  local errfile
  errfile=$(mktemp)
  if ! NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$stats" nix-instantiate --eval --strict --expr "$expr" >/dev/null 2>"$errfile"; then
    echo "perf evaluation failed:" >&2
    cat "$errfile" >&2
    rm -f "$stats" "$errfile"
    rm -rf "$moddir"
    return 1
  fi
  if [ -s "$stats" ]; then
    grep -oE '"nrFunctionCalls": ?[0-9]+' "$stats" | grep -oE '[0-9]+$'
  fi
  rm -f "$stats" "$errfile"
  rm -rf "$moddir"
}

for strategy in single namespaced ordered ordered-fn; do
  a=$(calls "$strategy" "$SMALL"); b=$(calls "$strategy" "$LARGE")
  if [ -z "$a" ] || [ -z "$b" ]; then
    _fail "$strategy: could not read Nix evaluation statistics"
  elif [ $((b * 10)) -lt $((a * MAX_RATIO_X10)) ]; then
    echo "PASS: $strategy scales linearly ($SMALL -> $LARGE modules: $a -> $b calls, x$(( b * 100 / a ))/100)"
  else
    _fail "$strategy scales super-linearly ($SMALL -> $LARGE modules: $a -> $b calls, x$(( b * 100 / a ))/100; limit x2.5)"
  fi
done

finish "PERF TESTS"
