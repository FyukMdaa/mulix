#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=tests/lib.sh
. "$ROOT_DIR/tests/lib.sh"

# Shared prelude for the cases below that build a mkMulix result.
PRE='
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    T = lib.types;
    hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
    build = { modules, configNames ? {} }: m.mkMulix {
      inherit hostDefs modules configNames; host = "h"; conditionNames = {};
    };
    reg = merge: type: { inherit type merge; };
  in
'

expect_success "mulib.module descriptor" '
  let lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
  in (m.module { name = "example"; })
'

expect_failure "raw module rejected by normalize" '
  let lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
  in m.normalizeLib.normalizeModule {
    mod = { name = "example"; };
    isFunction = false;
    declaredArgs = [];
  }
' "expected a mulib.module descriptor"

expect_success "wrapped module accepted by normalize" '
  let lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
  in m.normalizeLib.normalizeModule {
    mod = m.module { name = "example"; };
    isFunction = false;
    declaredArgs = [];
  }
'

expect_failure "raw host rejected" '
  let lib = (import <nixpkgs> {}).lib; h = import ./lib/hosts.nix { inherit lib; };
  in h.validateHosts { example = { name = "example"; system = "x86_64-linux"; }; } {}
' "expected a mulib.host descriptor"

expect_success "wrapped host accepted" '
  let lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
  in m.host { name = "example"; system = "x86_64-linux"; }
'

expect_success "host.is.darwin exists for Linux-only fleet" '
  let lib = (import <nixpkgs> {}).lib; h = import ./lib/hosts.nix { inherit lib; };
      host = h.mkHost { name = "example"; system = "x86_64-linux"; };
      view = h.mkHostsView { hosts = { example = host; }; conditionNames = {}; hostName = "example"; };
  in view.is.darwin == false
'

expect_failure "nested registry type is validated" '
  let lib = (import <nixpkgs> {}).lib; g = import ./lib/config-graph.nix { inherit lib; };
  in builtins.deepSeq (g.validateRegistry {
    example = {
      type = lib.types.attrsOf (lib.types.listOf lib.types.int);
      merge = "namespaced";
      default = { nested = [ "not-an-int" ]; };
    };
  }) true
' "not of type"

expect_failure "deeply nested registry type is validated" '
  let lib = (import <nixpkgs> {}).lib; g = import ./lib/config-graph.nix { inherit lib; };
  in builtins.deepSeq (g.validateRegistry {
    example = {
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf lib.types.int));
      merge = "namespaced";
      default = { outer = { inner = [ 1 "not-an-int" ]; }; };
    };
  }) true
' "not of type"

expect_failure "empty enable list is rejected" '
  let
    lib = (import <nixpkgs> {}).lib;
    m = import ./lib { inherit lib; };
  in builtins.deepSeq ((m.targetLib.optionsFragment {
    mod = m.normalizeLib.normalizeModule {
      mod = m.module {
        name = "empty-enable";
        options = { enable = []; };
      };
      isFunction = false;
      declaredArgs = [];
    };
    specialArgsBase = {};
    configGraphForConfig = _: {};
  }) {
    config = {};
    lib = lib;
  }) true
' "empty condition list"

expect_success "mkMulix end-to-end static send" '
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    result = m.mkMulix {
      hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
      host = "h";
      conditionNames = {};
      configNames = { foo = { type = lib.types.attrs; merge = "single"; }; };
      modules = [
        (m.module { name = "sender"; send.foo = { value = 42; }; })
      ];
    };
  in result.configGraph.foo.value == 42
'

expect_success "mkMulix preserves standard specialArgs" '
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    result = m.mkMulix {
      hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
      host = "h";
      conditionNames = {};
      specialArgs = { modulesPath = "/modules"; };
      configNames = { foo = { type = lib.types.str; merge = "single"; default = "ok"; }; };
      modules = [
        (m.module { name = "uses-modules-path"; options = { modulesPath, ... }: { enable = modulesPath == "/modules"; }; })
      ];
    };
  in result.modules != []
'

expect_success "send supports mkIf and mkMerge" '
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    result = m.mkMulix {
      hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
      host = "h";
      conditionNames = {};
      configNames = { foo = { type = lib.types.attrs; merge = "single"; }; };
      modules = [
        (m.module {
          name = "sender";
          send.foo = lib.mkMerge [ { a = 1; } (lib.mkIf true { b = 2; }) ];
        })
      ];
    };
  in result.configGraph.foo == { a = 1; b = 2; }
'

expect_success "single allows disjoint sibling paths" '
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    result = m.mkMulix {
      hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
      host = "h";
      conditionNames = {};
      configNames = { foo = { type = lib.types.attrs; merge = "single"; }; };
      modules = [
        (m.module { name = "a"; send.foo = { shared = { left = 1; }; }; })
        (m.module { name = "b"; send.foo = { shared = { right = 2; }; }; })
      ];
    };
  in result.configGraph.foo.shared == { left = 1; right = 2; }
'

expect_failure "single rejects overlapping paths" '
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    result = m.mkMulix {
      hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
      host = "h";
      conditionNames = {};
      configNames = { foo = { type = lib.types.attrs; merge = "single"; }; };
      modules = [
        (m.module { name = "a"; send.foo = { shared = { value = 1; }; }; })
        (m.module { name = "b"; send.foo = { shared = { value = 2; }; }; })
      ];
    };
  in result.configGraph.foo
' "ownership conflict"

expect_success "send supports mkForce priority" '
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    result = m.mkMulix {
      hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
      host = "h";
      conditionNames = {};
      configNames = { foo = { type = lib.types.attrs; merge = "single"; }; };
      modules = [
        (m.module { name = "normal"; send.foo = { value = 1; }; })
        (m.module { name = "forced"; send.foo = { value = lib.mkForce 2; }; })
      ];
    };
  in result.configGraph.foo.value == 2
'

expect_success "send supports root mkForce priority" '
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    result = m.mkMulix {
      hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
      host = "h";
      conditionNames = {};
      configNames = { foo = { type = lib.types.attrs; merge = "single"; }; };
      modules = [
        (m.module { name = "normal"; send.foo = { value = 1; other = 3; }; })
        (m.module { name = "forced"; send.foo = lib.mkForce { value = 2; }; })
      ];
    };
  in result.configGraph.foo == { value = 2; }
'

expect_success "send supports mkBefore and mkAfter ordering" '
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    result = m.mkMulix {
      hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
      host = "h";
      conditionNames = {};
      configNames = { foo = { type = lib.types.listOf lib.types.int; merge = "ordered"; }; };
      modules = [
        (m.module { name = "after"; send.foo = lib.mkAfter [ 2 ]; })
        (m.module { name = "before"; send.foo = lib.mkBefore [ 1 ]; })
      ];
    };
  in result.configGraph.foo == [ 1 2 ]
'

expect_success "mkMulix end-to-end dependency graph" '
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    result = m.mkMulix {
      hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
      host = "h";
      conditionNames = {};
      configNames = { foo = { type = lib.types.str; merge = "single"; default = "ok"; }; };
      modules = [
        (m.module { name = "sender"; send.foo = "ok"; })
        (m.module { name = "receiver"; options = { foo, ... }: { enable = foo == "ok"; }; })
      ];
    };
  in builtins.elem "sender" (map (e: e.from) result.dependencyGraph.edges)
'

expect_failure "mkMulix end-to-end dependency cycle" '
  let
    lib = (import <nixpkgs> {}).lib; m = import ./lib { inherit lib; };
    result = m.mkMulix {
      hostDefs = { h = m.host { name = "h"; system = "x86_64-linux"; }; };
      host = "h";
      conditionNames = {};
      configNames = {
        x = { type = lib.types.str; merge = "single"; default = "x"; };
        y = { type = lib.types.str; merge = "single"; default = "y"; };
      };
      modules = [
        (m.module { name = "A"; options = { y, ... }: { enable = y == "y"; }; send.x = "x"; })
        (m.module { name = "B"; options = { x, ... }: { enable = x == "x"; }; send.y = "y"; })
      ];
    };
  in result.dependencyGraph
' "dependency cycle detected"


# ---------------------------------------------------------------------------
# send properties: ordering and priorities
# ---------------------------------------------------------------------------

expect_success "mkBefore / mkAfter / mkOrder order across four modules" "$PRE"'
  (build {
    configNames.foo = reg "ordered" (T.listOf T.int);
    modules = [
      (m.module { name = "a"; send.foo = lib.mkAfter [ 3 ]; })
      (m.module { name = "b"; send.foo = [ 2 ]; })
      (m.module { name = "c"; send.foo = lib.mkBefore [ 1 ]; })
      (m.module { name = "d"; send.foo = lib.mkOrder 2000 [ 4 ]; })
    ];
  }).configGraph.foo == [ 1 2 3 4 ]
'

expect_success "equal-order senders keep module order" "$PRE"'
  (build {
    configNames.foo = reg "ordered" (T.listOf T.int);
    modules = [
      (m.module { name = "x"; send.foo = [ 1 ]; })
      (m.module { name = "y"; send.foo = [ 2 ]; })
      (m.module { name = "z"; send.foo = [ 3 ]; })
    ];
  }).configGraph.foo == [ 1 2 3 ]
'

expect_success "nested mkDefault loses to a normal definition" "$PRE"'
  (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "a"; send.foo = { v = lib.mkDefault 1; }; })
      (m.module { name = "b"; send.foo = { v = 2; }; })
    ];
  }).configGraph.foo == { v = 2; }
'

expect_success "nested mkDefault alone is kept" "$PRE"'
  (build {
    configNames.foo = reg "single" T.attrs;
    modules = [ (m.module { name = "a"; send.foo = { v = lib.mkDefault 1; }; }) ];
  }).configGraph.foo == { v = 1; }
'

expect_success "nested mkOverride 10 beats mkForce" "$PRE"'
  (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "a"; send.foo = { v = lib.mkOverride 10 1; }; })
      (m.module { name = "b"; send.foo = { v = lib.mkForce 2; }; })
    ];
  }).configGraph.foo == { v = 1; }
'

expect_failure "two nested mkDefault on one leaf conflict" "$PRE"'
  builtins.deepSeq (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "a"; send.foo = { v = lib.mkDefault 1; }; })
      (m.module { name = "b"; send.foo = { v = lib.mkDefault 2; }; })
    ];
  }).configGraph.foo true
' "ownership conflict"

# ---------------------------------------------------------------------------
# single: conflict reporting must itself work
# ---------------------------------------------------------------------------

expect_failure "single conflict names the overlapping path" "$PRE"'
  builtins.deepSeq (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "a"; send.foo = { shared.value = 1; }; })
      (m.module { name = "b"; send.foo = { shared.value = 2; }; })
    ];
  }).configGraph.foo true
' "shared.value"

expect_failure "single prefix overlap (foo vs foo.bar) is an ownership conflict" "$PRE"'
  builtins.deepSeq (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "a"; send.foo = { x = 1; }; })
      (m.module { name = "b"; send.foo = { x.y = 2; }; })
    ];
  }).configGraph.foo true
' "ownership conflict"

expect_failure "single conflict lists both writers" "$PRE"'
  builtins.deepSeq (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "writer-one"; send.foo = { x = 1; }; })
      (m.module { name = "writer-two"; send.foo = { x.y = 2; }; })
    ];
  }).configGraph.foo true
' "writer-two"

# ---------------------------------------------------------------------------
# send values: cycles must be a mulix error, opaque values must be leaves
# ---------------------------------------------------------------------------

expect_failure "self-referential send value is rejected (single)" "$PRE"'
  let selfRef = let x = { a = 1; self = x; }; in x; in
  builtins.deepSeq (build {
    configNames.foo = reg "single" T.attrs;
    modules = [ (m.module { name = "a"; send.foo = { v = selfRef; }; }) ];
  }).configGraph.foo true
' "nested too deeply"

expect_failure "self-referential send value is rejected (namespaced)" "$PRE"'
  let selfRef = let x = { a = 1; self = x; }; in x; in
  builtins.deepSeq (build {
    configNames.foo = reg "namespaced" T.attrs;
    modules = [ (m.module { name = "a"; send.foo = { v = selfRef; }; }) ];
  }).configGraph.foo true
' "nested too deeply"

expect_failure "self-referential value under mkForce is rejected" "$PRE"'
  let selfRef = let x = { a = 1; self = x; }; in x; in
  builtins.deepSeq (build {
    configNames.foo = reg "single" T.attrs;
    modules = [ (m.module { name = "a"; send.foo = { v = lib.mkForce selfRef; }; }) ];
  }).configGraph.foo true
' "nested too deeply"

expect_failure "recursion error names the configName and module" "$PRE"'
  let selfRef = let x = { a = 1; self = x; }; in x; in
  builtins.deepSeq (build {
    configNames.foo = reg "single" T.attrs;
    modules = [ (m.module { name = "culprit"; send.foo = { v = selfRef; }; }) ];
  }).configGraph.foo true
' "module 'culprit'"

expect_success "legitimately deep data (60 levels) is accepted" "$PRE"'
  let deep = n: if n == 0 then { leaf = 1; } else { x = deep (n - 1); }; in
  (build {
    configNames.foo = reg "namespaced" T.attrs;
    modules = [ (m.module { name = "a"; send.foo = deep 60; }) ];
  }).configGraph.foo ? x
'

expect_success "derivation-like values are opaque leaves (even if self-referential)" "$PRE"'
  let drv = { type = "derivation"; name = "pkg"; self = drv; }; in
  (build {
    configNames.foo = reg "single" T.attrs;
    modules = [ (m.module { name = "a"; send.foo = { package = drv; }; }) ];
  }).configGraph.foo.package.name == "pkg"
'

expect_success "typed attrsets (option-type / option) are opaque leaves" "$PRE"'
  (build {
    configNames.foo = reg "namespaced" T.attrs;
    modules = [ (m.module { name = "a"; send.foo = { t = T.str; o = lib.mkOption { type = T.int; }; }; }) ];
  }).configGraph.foo.t._type == "option-type"
'

expect_success "ordered strategy does not walk into (self-referential) elements" "$PRE"'
  let selfRef = let x = { a = 1; self = x; }; in x; in
  builtins.length (build {
    configNames.foo = reg "ordered" (T.listOf T.raw);
    modules = [ (m.module { name = "a"; send.foo = [ selfRef ]; }) ];
  }).configGraph.foo == 1
'

# ---------------------------------------------------------------------------
# dependency errors
# ---------------------------------------------------------------------------

expect_failure "a module that sends and receives the same configName is rejected" "$PRE"'
  (build {
    configNames.foo = reg "ordered" (T.listOf T.int);
    modules = [
      ({ foo, mulib, ... }: mulib.module { name = "self"; send.foo = [ 1 ]; })
    ];
  }).dependencyGraph
' "depends on itself"

expect_failure "self-dependency error names module and configName" "$PRE"'
  (build {
    configNames.foo = reg "ordered" (T.listOf T.int);
    modules = [
      ({ foo, mulib, ... }: mulib.module { name = "self"; send.foo = [ 1 ]; })
    ];
  }).dependencyGraph
' "self --foo--> self"

expect_failure "duplicate module names are rejected" "$PRE"'
  (build { modules = [ (m.module { name = "dup"; }) (m.module { name = "dup"; }) ]; }).modules
' "duplicate module name(s): dup"

expect_failure "a genuine two-module cycle keeps the plain cycle message" "$PRE"'
  (build {
    configNames = { x = reg "ordered" (T.listOf T.int); y = reg "ordered" (T.listOf T.int); };
    modules = [
      ({ y, mulib, ... }: mulib.module { name = "A"; send.x = [ 1 ]; })
      ({ x, mulib, ... }: mulib.module { name = "B"; send.y = [ 2 ]; })
    ];
  }).dependencyGraph
' "A --x--> B --y--> A"

# ---------------------------------------------------------------------------
# documented static contracts (decided behaviour; these tests pin it)
# ---------------------------------------------------------------------------

expect_success "exported configGraph is static: it includes DISABLED modules' sends" "$PRE"'
  (build {
    configNames.foo = reg "ordered" (T.listOf T.str);
    modules = [
      (m.module {
        name = "off";
        options.enable = lib.mkOption { type = T.bool; default = false; };
        send.foo = [ "from-disabled" ];
      })
    ];
  }).configGraph.foo == [ "from-disabled" ]
'

expect_failure "registry defaults are validated eagerly (static contract)" "$PRE"'
  builtins.deepSeq (build {
    configNames.foo = { type = T.attrs; merge = "single"; default = { ok = 1; lazy = throw "boom-default"; }; };
    modules = [];
  }).host true
' "boom-default"

expect_success "registry type validates but does not convert (no submodule defaults injected)" "$PRE"'
  (build {
    configNames.foo = {
      type = T.submodule { options.a = lib.mkOption { type = T.int; default = 1; }; };
      merge = "single";
    };
    modules = [ (m.module { name = "a"; send.foo = { }; }) ];
  }).configGraph.foo == { }
'

# ---------------------------------------------------------------------------
# empty attrsets define nothing (they keep their place but override nothing)
# ---------------------------------------------------------------------------

expect_success "an empty send does not suppress another module's mkDefault" "$PRE"'
  (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "a"; send.foo = { }; })
      (m.module { name = "b"; send.foo = { v = lib.mkDefault 1; }; })
    ];
  }).configGraph.foo == { v = 1; }
'

expect_success "a conditionally empty send (optionalAttrs false) does not suppress mkDefault" "$PRE"'
  (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "a"; send.foo = lib.optionalAttrs false { x = 1; }; })
      (m.module { name = "b"; send.foo = { v = lib.mkDefault 1; }; })
    ];
  }).configGraph.foo == { v = 1; }
'

expect_success "the same holds for namespaced" "$PRE"'
  (build {
    configNames.foo = reg "namespaced" T.attrs;
    modules = [
      (m.module { name = "a"; send.foo = { }; })
      (m.module { name = "b"; send.foo = { v = lib.mkDefault 1; }; })
    ];
  }).configGraph.foo == { v = 1; }
'

expect_success "a nested empty attrset does not suppress a mkDefault below it" "$PRE"'
  (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "a"; send.foo = { x = { }; }; })
      (m.module { name = "b"; send.foo = { x.v = lib.mkDefault 1; }; })
    ];
  }).configGraph.foo == { x = { v = 1; }; }
'

expect_success "an empty attrset on its own is preserved" "$PRE"'
  (build {
    configNames.foo = reg "single" T.attrs;
    modules = [ (m.module { name = "a"; send.foo = { x = { }; }; }) ];
  }).configGraph.foo == { x = { }; }
'

expect_success "mkForce still overrides an empty attrset (module order: empty first)" "$PRE"'
  (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "a"; send.foo = { x = { }; }; })
      (m.module { name = "b"; send.foo = { x = lib.mkForce 5; }; })
    ];
  }).configGraph.foo == { x = 5; }
'

expect_success "mkForce still overrides an empty attrset (module order: mkForce first)" "$PRE"'
  (build {
    configNames.foo = reg "single" T.attrs;
    modules = [
      (m.module { name = "b"; send.foo = { x = lib.mkForce 5; }; })
      (m.module { name = "a"; send.foo = { x = { }; }; })
    ];
  }).configGraph.foo == { x = 5; }
'

finish "API CONTRACT TESTS"
