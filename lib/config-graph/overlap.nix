# Path overlap index and send value traversal.
#
# This file owns the parts of `lib/config-graph.nix` that:
#   - walk a send value into leaf writes (`collectLeafWrites`,
#     `applyNestedLeafOverrides`, `recursiveUpdateMany`);
#   - answer "who owns this path?" via `buildOverlapIndex` /
#     `overlapMinOther`;
#   - format error messages (`formatPath`, `formatWriter`).
#
# Self-contained: depends only on `lib` and `builtins`.
#
# The merge-strategy code in `merge.nix` imports these helpers and
# `inherit`s them into its own `let` scope, so the function bodies in
# `merge.nix` are unchanged from the original monolithic file.
{lib}: let
  inherit (builtins) isAttrs isList elem;
  collectPathsIn = ctx: prefix: value:
    if isAttrs value && !(isOpaqueValue value)
    then
      builtins.seq (checkSendDepth ctx prefix)
      (lib.concatLists
        (lib.mapAttrsToList
          (k: v: collectPathsIn ctx (prefix ++ [k]) v)
          value))
    else [prefix];

  # Public form (no diagnostic context).
  collectPaths = collectPathsIn "send value";

  isPrefixOf = a: b:
    builtins.length a
    <= builtins.length b
    && lib.sublist 0 (builtins.length a) b == a;

  pathsOverlap = a: b: isPrefixOf a b || isPrefixOf b a;

  # path を一意な文字列キーにする。attr 名に "." が含まれる場合でも
  # 衝突しないよう toJSON でエンコードする。
  pathKey = p: builtins.toJSON p;

  # Keys of every *proper* prefix of `p` ([] up to length-1).
  properPrefixKeys = p:
    map (n: pathKey (lib.take n p)) (lib.range 0 (builtins.length p - 1));

  # ---- overlap index ----
  #
  # Answers, in O(path length) instead of O(number of entries):
  #   "among entries of a DIFFERENT module whose path overlaps this path,
  #    which has the smallest `rank`?"
  # where two paths overlap iff one is a prefix of the other (or they are equal).
  #
  # entries: [{ path; module; rank; ... }]
  #
  # Every overlap is one of: same path (exact), an ancestor of the query
  # (exact entry at a proper prefix), or a descendant of the query (an entry
  # that has the query as a proper prefix -- the `below` map).  For each key we
  # keep the minimum-rank entry (`best`) and the minimum-rank entry from a
  # different module than `best` (`other`), which is all that is needed to
  # answer "minimum rank among modules other than M" for any M.
  #
  # (builtins.listToAttrs keeps the first entry for a duplicated name, so a
  #  rank-sorted list yields the minimum per key.)
  buildOverlapIndex = entries: let
    sorted = builtins.sort (a: b: a.rank < b.rank) entries;
    summarize = keyed: let
      best = builtins.listToAttrs keyed;
      other =
        builtins.listToAttrs
        (builtins.filter (kv: kv.value.module != best.${kv.name}.module) keyed);
    in {inherit best other;};
  in {
    exact = summarize (map (e: {
        name = pathKey e.path;
        value = e;
      })
      sorted);
    below =
      summarize
      (lib.concatMap
        (e:
          map (k: {
            name = k;
            value = e;
          }) (properPrefixKeys e.path))
        sorted);
  };

  # Left-to-right `lib.recursiveUpdate` over a list, in ONE pass.
  #
  # `foldl' recursiveUpdate` copies its accumulator at every step (Nix has no
  # persistent maps), which is O(N^2) for N values.  Per key, the fold combines
  # v1..vk as: a value replaces what came before unless BOTH are attrsets, in
  # which case they merge recursively.  Hence only the trailing run of
  # attrsets (after the last non-attrset) matters; that run is merged by
  # grouping all entries by key once and recursing per key.
  #
  # Keys that occur only once are returned untouched (and stay lazy).
  recursiveUpdateMany = values: let
    n = builtins.length values;
    lastNonAttr =
      lib.foldl'
      (acc: i:
        if isAttrs (builtins.elemAt values i)
        then acc
        else i)
      (-1)
      (lib.range 0 (n - 1));
    run = lib.drop (lastNonAttr + 1) values;
    entries = lib.concatMap (v:
      lib.mapAttrsToList (k: x: {
        name = k;
        value = x;
      })
      v)
    run;
    grouped = builtins.groupBy (e: e.name) entries;
  in
    if n == 0
    then {}
    else if lastNonAttr == n - 1
    then builtins.elemAt values (n - 1)
    else if builtins.length run == 1
    then builtins.head run
    else
      builtins.mapAttrs
      (_: es:
        if builtins.length es == 1
        then (builtins.head es).value
        else recursiveUpdateMany (map (e: e.value) es))
      grouped;

  overlapMinOther = index: path: module: let
    pick = summary: k: let
      f = summary.best.${k} or null;
    in
      if f == null
      then null
      else if f.module != module
      then f
      else summary.other.${k} or null;
    candidates =
      [(pick index.exact (pathKey path)) (pick index.below (pathKey path))]
      ++ map (k: pick index.exact k) (properPrefixKeys path);
  in
    lib.foldl'
    (acc: c:
      if c == null
      then acc
      else if acc == null || c.rank < acc.rank
      then c
      else acc)
    null
    candidates;

  formatPath = p:
    if p == []
    then "(root)"
    else builtins.concatStringsSep "." p;

  # ---- send value traversal policy ----
  #
  # single / namespaced reason about ownership per leaf path, so they walk a
  # send value as a plain data tree.  Two things must hold for that walk:
  #
  #  1. Some attrsets are not data trees and are treated as opaque leaves:
  #     derivations, functors and module-system typed attrsets (option,
  #     option-type, ...).  mkIf/mkMerge/mkOverride/mkOrder are *properties*
  #     and are interpreted, never treated as data.
  #  2. The walk must terminate.  A self-referential value (`x = { self = x; }`)
  #     has infinitely many leaf paths and cannot be owned; it is reported as a
  #     mulix error instead of overflowing the stack.
  maxSendDepth = 64;

  propertyTypes = ["override" "if" "merge" "order"];

  isOpaqueValue = v:
    isAttrs v
    && (lib.isDerivation v
      || v ? __functor
      || ((v._type or null) != null && !(elem v._type propertyTypes)));

  checkSendDepth = ctx: prefix:
    if builtins.length prefix > maxSendDepth
    then
      throw ''
        mulix: send value is nested too deeply (more than ${toString maxSendDepth} levels)
        where: ${ctx}
        path: ${formatPath (lib.take 6 prefix)}.… (truncated)
        This is almost certainly a self-referential value (a value containing itself);
        single / namespaced own values per leaf path and cannot walk a cycle.
        help: send plain data, or a derivation / typed value (both are treated as leaves)
        help: the ordered strategy does not walk into list elements
      ''
    else true;

  formatWriter = w: "${w.module}${
    if (w.source or null) == null
    then ""
    else " [source: ${w.source}]"
  }";

  # `mkOverride` normally appears at the definition boundary, where
  # lib.modules.filterOverrides can process it.  send values can also contain
  # an override at an arbitrary leaf, e.g. `{ value = lib.mkForce 2; }`.
  # Treat those nested properties as per-leaf definitions before applying
  # mulix's merge strategy.  This mirrors the important property of Nix's
  # module system: an override attached to `foo.bar` affects that path, not
  # unrelated sibling paths.
  # `defaultOverridePriority` is part of the Nix module implementation, but
  # older nixpkgs releases may not export it under `lib.modules`.  Its
  # canonical default is 100; keep a compatibility fallback so the graph
  # library does not become version-fragile merely by evaluating a send.
  defaultOverridePriority = lib.modules.defaultOverridePriority or 100;

  collectLeafWrites = ctx: prefix: value: inheritedPriority: let
    propertyType =
      if isAttrs value
      then value._type or null
      else null;
  in
    if propertyType == "override"
    # An override replaces the priority for everything below it.  (It must
    # not be `min`-ed with the inherited priority: the inherited default is
    # 100, which would turn mkDefault (1000) into a normal definition.)
    then collectLeafWrites ctx prefix value.content value.priority
    else if propertyType == "if"
    then
      if value.condition
      then collectLeafWrites ctx prefix value.content inheritedPriority
      else []
    else if propertyType == "merge"
    then lib.concatMap (v: collectLeafWrites ctx prefix v inheritedPriority) value.contents
    else if propertyType == "order"
    then collectLeafWrites ctx prefix value.content inheritedPriority
    else if isAttrs value && !(isOpaqueValue value)
    then let
      entries =
        builtins.seq (checkSendDepth ctx prefix)
        (lib.mapAttrsToList
          (k: v: collectLeafWrites ctx (prefix ++ [k]) v inheritedPriority)
          value);
    in
      if entries == []
      # An empty attrset defines nothing: it is kept in the result (so
      # `foo = {}` stays `foo = {}`) but it owns no path -- collectPathsIn
      # gives it none -- and therefore must not override other modules'
      # values either.  `inert` marks such a write.
      then [
        {
          path = prefix;
          inherit value;
          priority = inheritedPriority;
          inert = true;
        }
      ]
      else lib.concatLists entries
    else [
      {
        path = prefix;
        inherit value;
        priority = inheritedPriority;
      }
    ];

  applyNestedLeafOverrides = configName: contributions: let
    numbered = lib.imap0 (cid: contribution: contribution // {_mulixContributionId = cid;}) contributions;

    writes =
      lib.concatMap
      (contribution:
        map
        (write:
          write
          // {
            contributionId = contribution._mulixContributionId;
            module = contribution.module;
          })
        (collectLeafWrites "configName '${configName}' (module '${contribution.module}')" [] contribution.value defaultOverridePriority))
      (builtins.filter (c: isAttrs c.value) numbered);

    # A write is dominated when a write of a different module, on an
    # overlapping path, has a strictly smaller priority number.
    # Inert writes (empty attrsets) never dominate anything, so they are not in
    # the index; they can still be dominated by a stronger write below.
    priorityIndex =
      buildOverlapIndex
      (map (w: w // {rank = w.priority;})
        (builtins.filter (w: !(w.inert or false)) writes));

    dominates = write: let
      lowest = overlapMinOther priorityIndex write.path write.module;
    in
      lowest != null && lowest.priority < write.priority;

    survivingWrites = builtins.filter (write: !dominates write) writes;

    survivingByContribution =
      builtins.groupBy (write: toString write.contributionId) survivingWrites;

    rebuild = contribution: let
      selected = survivingByContribution.${toString contribution._mulixContributionId} or [];
    in
      if !isAttrs contribution.value
      then builtins.removeAttrs contribution ["_mulixContributionId"]
      else if selected == []
      then null
      else
        (builtins.removeAttrs contribution ["_mulixContributionId"])
        // {
          value =
            recursiveUpdateMany
            (map (write: lib.setAttrByPath write.path write.value) selected);
        };
  in
    builtins.filter (c: c != null) (map rebuild numbered);

  # ---- single strategy ----

  /*
  path-level exclusive ownership。

  writer ごとの leaf path を比較し、異なる module の path が同一または
  prefix 関係にある場合だけ conflict とする。

  したがって A が foo.a、B が foo.b を書くケースは許可される一方、
  A が foo、B が foo.a を書くケースは conflict になる。
  */
  # For every contribution (in order) that overlaps a path already written by
  # an EARLIER contribution of a different module, report the first such
  # earlier contribution: [{ writer; other; }].
  #

in rec {
  inherit
    collectPathsIn
    collectPaths
    isPrefixOf
    pathsOverlap
    pathKey
    properPrefixKeys
    buildOverlapIndex
    recursiveUpdateMany
    overlapMinOther
    formatPath
    maxSendDepth
    propertyTypes
    isOpaqueValue
    checkSendDepth
    formatWriter
    defaultOverridePriority
    collectLeafWrites
    applyNestedLeafOverrides
    ;
}
