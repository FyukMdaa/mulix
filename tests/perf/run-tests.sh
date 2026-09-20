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
  stats=$(mktemp)
  NIX_SHOW_STATS=1 NIX_SHOW_STATS_PATH="$stats" nix-instantiate --eval --strict --expr "
    let
      lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; }; T = lib.types;
      N = $n;
      en = { enable = lib.mkOption { type = T.bool; default = true; }; };
      senders = map (i: m.module { name = \"s\${toString i}\"; options = en; send.c = $send; }) (lib.range 1 N);
      receiver = { c, mulib, ... }: mulib.module { name = \"r\"; options = en; os.out.n = $read; };
      r = m.mkMulix {
        hostDefs.h = m.host { name = \"h\"; system = \"x86_64-linux\"; };
        host = \"h\"; conditionNames = {};
        configNames.c = { type = $type; merge = \"$strategy\"; default = $default; };
        modules = senders ++ [ receiver ];
      };
    in (lib.evalModules {
         modules = (r.targetModuleList \"os\") ++ [
           { options.out = lib.mkOption { type = T.lazyAttrsOf T.raw; default = {}; }; }
         ];
       }).config.out.n
  " >/dev/null 2>&1
  grep -oE '"nrFunctionCalls": ?[0-9]+' "$stats" | grep -oE '[0-9]+$'
  rm -f "$stats"
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
