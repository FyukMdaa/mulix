# Reference (naive, O(N^2)) implementations of the single/namespaced ownership
# logic, kept verbatim from before the indexed rewrite.  They exist ONLY to
# check that the optimized code in lib/config-graph.nix behaves identically.
{ lib, cg }:
let
  inherit (cg) pathsOverlap collectLeafWrites;
  defaultOverridePriority = 100;
  ref =
{
  # Was: `conflicts` inside resolveSingle.
  findSingleConflicts = withPaths:
    lib.concatLists
    (lib.imap0
      (i: c:
        let
          prior = lib.sublist 0 i withPaths;
          firstConflict = lib.findFirst
            (other:
              other.module != c.module
              && lib.any
                (p: lib.any (q: pathsOverlap p q) other.paths)
                c.paths)
            null
            prior;
        in
          if firstConflict == null
          then []
          else [{ writer = c; other = firstConflict; }])
      withPaths);

  # Was: `foldl' recursiveUpdate` used for the final merge in resolveSingle and
  # for rebuilding a contribution from its leaf writes.
  recursiveUpdateFold = values: lib.foldl' lib.recursiveUpdate {} values;

  # Was: mergeNamespaced (pairwise, lazy at each key).
  mergeNamespaced = path: a: b:
    if builtins.isAttrs a && builtins.isAttrs b
    then let
      keys = lib.unique (builtins.attrNames a ++ builtins.attrNames b);
    in
      builtins.listToAttrs (map
        (k: {
          name = k;
          value =
            if a ? ${k} && b ? ${k}
            then ref.mergeNamespaced (path ++ [k]) a.${k} b.${k}
            else if a ? ${k}
            then a.${k}
            else b.${k};
        })
        keys)
    else throw "clash";

  mergeNamespacedFold = values: lib.foldl' (acc: v: ref.mergeNamespaced [] acc v) {} values;

  # Outcome of forcing a value: { ok = value; } or { err = true; }.
  outcome = v: let r = builtins.tryEval (builtins.deepSeq v v); in
    if r.success then { ok = r.value; } else { err = true; };

  # Was: resolveSingle (naive conflicts + fold), as an outcome.
  resolveSingleOutcome = contributions: let
    sorted = lib.sort (a: b: a.index < b.index) contributions;
    bad = builtins.filter (c: !builtins.isAttrs c.value) sorted;
    withPaths = map (c: c // { paths = cg.collectPathsIn "reference" [] c.value; }) sorted;
  in
    if bad != [] then { err = true; }
    else if ref.findSingleConflicts withPaths != [] then { err = true; }
    else ref.outcome (ref.recursiveUpdateFold (map (c: c.value) sorted));

  # Was: pathWriters + conflicts inside resolveNamespaced (a fold that copies the
  # accumulator with `//` for every leaf path).
  findNamespacedConflicts = sorted: let
    pathWriters = builtins.foldl'
      (acc: c:
        builtins.foldl'
          (acc2: p:
            let k = cg.pathKey p;
            in acc2 // { ${k} = (acc2.${k} or []) ++ [ { module = c.module; source = c.source or null; path = p; } ]; })
          acc
          (cg.collectPathsIn "reference" [] c.value))
      {}
      sorted;
  in lib.filterAttrs (_: ws: lib.length (lib.unique (map (w: w.module) ws)) > 1) pathWriters;

  # Was: resolveNamespaced (foldl' + // pathWriters, pairwise merge), as an outcome.
  resolveNamespacedOutcome = contributions: let
    sorted = lib.sort (a: b: a.index < b.index) contributions;
    pathWriters = builtins.foldl'
      (acc: c:
        builtins.foldl'
          (acc2: p:
            let k = cg.pathKey p;
            in acc2 // { ${k} = (acc2.${k} or []) ++ [ { module = c.module; path = p; } ]; })
          acc
          (cg.collectPathsIn "reference" [] c.value))
      {}
      sorted;
    conflicts = lib.filterAttrs (_: ws: lib.length (lib.unique (map (w: w.module) ws)) > 1) pathWriters;
  in
    if conflicts != {} then { err = true; }
    else ref.outcome (ref.mergeNamespacedFold (map (c: c.value) sorted));

  # Was: applyNestedLeafOverrides.
  applyNestedLeafOverrides = configName: contributions: let
    numbered = lib.imap0 (cid: contribution: contribution // {_mulixContributionId = cid;}) contributions;

    writes = lib.concatMap
      (contribution:
        map
          (write: write // {
            contributionId = contribution._mulixContributionId;
            module = contribution.module;
          })
          (collectLeafWrites "reference" [] contribution.value defaultOverridePriority))
      (builtins.filter (c: builtins.isAttrs c.value) numbered);

    # Intentional behaviour change (v6): an empty attrset (an `inert` write)
    # defines nothing and therefore never dominates another module's write.
    # (Decided from the value itself, not from the library's own `inert` flag,
    #  so a wrongly-set flag in the library cannot hide behind this reference.)
    isEmptyAttrs = w: builtins.isAttrs w.value && w.value == {};
    dominates = write:
      lib.any
        (other:
          !(isEmptyAttrs other)
          && other.contributionId != write.contributionId
          && other.module != write.module
          && pathsOverlap write.path other.path
          && other.priority < write.priority)
        writes;

    survivingWrites = builtins.filter (write: !dominates write) writes;

    rebuild = contribution: let
      selected = builtins.filter
        (write: write.contributionId == contribution._mulixContributionId)
        survivingWrites;
    in
      if !builtins.isAttrs contribution.value
      then builtins.removeAttrs contribution ["_mulixContributionId"]
      else if selected == []
      then null
      else
        (builtins.removeAttrs contribution ["_mulixContributionId"])
        // {
          value = lib.foldl'
            (acc: write:
              lib.recursiveUpdate acc (lib.setAttrByPath write.path write.value))
            {}
            selected;
        };
  in
    builtins.filter (c: c != null) (map rebuild numbered);
};
in ref
