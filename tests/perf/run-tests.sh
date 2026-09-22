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
      type='T.listOf T.int'; default='[ ]'; send=''; read='builtins.length c' ;;
    ordered-fn)
      strategy=ordered
      type='T.listOf T.int'; default='[ ]'; send=''; read='builtins.length c' ;;
    *)
      type='T.attrs'; default='{ }'; send='';
      read='builtins.length (builtins.attrNames c)' ;;
  esac

  # `paths` is a filesystem discovery API, so benchmark it with real files.
  # Do not use builtins.toFile here: the generated file must remain an actual
  # filesystem entry for collector.listNixFiles/readFileType while the Nix
  # expression is being evaluated.
  local module_dir receiver_file i module_body
  module_dir=$(mktemp -d "$ROOT_DIR/tests/perf/.generated.XXXXXX")
  trap 'rm -rf "$module_dir"' RETURN

  for ((i = 1; i <= n; i++)); do
    case "$strategy" in
      ordered)
        module_body=$(cat <<EOF
{ lib, mulib, ... }:
mulib.module {
  name = "s${i}";
  options = { enable = lib.mkOption { type = lib.types.bool; default = true; }; };
  send.c = [ ${i} ];
}
EOF
)
        ;;
      ordered-fn)
        module_body=$(cat <<EOF
{ lib, mulib, ... }:
mulib.module {
  name = "s${i}";
  options = { enable = lib.mkOption { type = lib.types.bool; default = true; }; };
  send.c = { opt, ... }: [ (if opt.enable then ${i} else 0) ];
}
EOF
)
        ;;
      *)
        module_body=$(cat <<EOF
{ lib, mulib, ... }:
mulib.module {
  name = "s${i}";
  options = { enable = lib.mkOption { type = lib.types.bool; default = true; }; };
  send.c = { "k${i}" = { a = ${i}; b = ${i}; }; };
}
EOF
)
        ;;
    esac
    printf '%s\n' "$module_body" > "$module_dir/module-${i}.nix"
  done

  receiver_file="$module_dir/receiver.nix"
  cat > "$receiver_file" <<EOF
{ c, lib, mulib, ... }:
mulib.module {
  name = "r";
  options = { enable = lib.mkOption { type = lib.types.bool; default = true; }; };
  os.out.n = ${read};
}
EOF

  stats=$(mktemp)
  local expr
  expr=$(cat <<EOF
let
  lib = (import <nixpkgs> {}).lib;
  m = import ./lib { inherit lib; };
  T = lib.types;
  r = m.mkMulix {
    hostDefs.h = m.host { name = "h"; system = "x86_64-linux"; };
    host = "h";
    conditionNames = {};
    configNames.c = { type = ${type}; merge = "${strategy}"; default = ${default}; };
    paths = [ ${module_dir} ];
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
    return 1
  fi
  if [ -s "$stats" ]; then
    grep -oE '"nrFunctionCalls": ?[0-9]+' "$stats" | grep -oE '[0-9]+$'
  fi
  rm -f "$stats" "$errfile"
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
