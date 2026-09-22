# Differential test: optimized implementations vs. the naive reference on
# deterministic pseudo-random inputs.  Evaluates to an attrset of mismatch
# counts (all must be 0) plus how many cases were exercised.
{
  lib,
  cases ? 1500,
}: let
  cg = import ../../lib/config-graph.nix {inherit lib;};
  ref = import ./reference.nix {inherit lib cg;};

  # ---- deterministic PRNG: rnd id bound -> [0, bound) ----
  # (Nix ints are 64-bit: every product below stays < 2^63 because the
  #  operand is reduced below 2^31 first.)
  modn = a: n: a - (a / n) * n;
  mix = x: modn (x * 1103515245 + 12345) 2147483648;
  rnd = id: bound: let
    h = mix (mix (mix (modn (modn id 2147483647 * 2654435761 + 97) 2147483648)));
  in
    modn (h / 65536) bound;

  keys = ["a" "b" "c"];

  # ---- value generator (for applyNestedLeafOverrides) ----
  genLeaf = id: let
    r = rnd id 14;
  in
    if r < 4
    then r * 10
    else if r == 4
    then lib.mkDefault 7
    else if r == 5
    then lib.mkForce 8
    else if r == 6
    then lib.mkOverride 10 9
    else if r == 7
    then lib.mkOverride 1000 6
    else if r == 8
    then lib.mkIf true 3
    else if r == 9
    then lib.mkIf false 4
    else if r == 10
    then {}
    else if r == 11
    then lib.mkMerge [1 2]
    else if r == 12
    then lib.mkOrder 500 5
    else 42;

  genAttrs = id: depth: let
    n = 1 + rnd id 3;
    picked = builtins.genList (i: builtins.elemAt keys (rnd (id * 7 + i) 3)) n;
    child = i: k: {
      name = k;
      value =
        if depth < 3 && rnd (id * 13 + i) 3 == 0
        then wrap (id * 31 + i) (genAttrs (id * 31 + i) (depth + 1))
        else genLeaf (id * 17 + i);
    };
  in
    builtins.listToAttrs (lib.imap0 child picked);

  wrap = id: v: let
    r = rnd id 8;
  in
    if r == 0
    then lib.mkForce v
    else if r == 1
    then lib.mkDefault v
    else if r == 2
    then lib.mkIf true v
    else v;

  genContribution = caseId: i: let
    id = caseId * 101 + i * 7 + 3;
    modIx = rnd (id + 1) 4;
  in {
    module = "m${toString modIx}";
    index = modIx;
    value = let
      r = rnd (id + 2) 25;
    in
      if r == 0
      then [1]
      else if r == 1 || r == 2
      then {} # a module that sends "nothing"
      else genAttrs id 0;
  };

  genContributions = caseId:
    builtins.genList (genContribution caseId) (2 + rnd (caseId * 3 + 1) 6);

  # ---- path generator (for findSingleConflicts) ----
  genPath = id: let
    len = rnd id 4;
  in
    if rnd (id + 5) 40 == 0
    then []
    else
      builtins.genList (i: builtins.elemAt keys (rnd (id * 5 + i) 3)) (
        if len == 0
        then 1
        else len
      );

  genPathContribution = caseId: i: let
    id = caseId * 211 + i * 11 + 1;
  in {
    module = "m${toString (rnd (id + 1) 4)}";
    index = i;
    paths = builtins.genList (j: genPath (id * 3 + j)) (rnd (id + 2) 4);
  };

  genPathContributions = caseId:
    builtins.genList (genPathContribution caseId) (2 + rnd (caseId * 5 + 2) 8);

  # ---- plain (already-normalized) trees for the merge functions ----
  # Leaves: ints, lists, empty attrsets; inner nodes: attrsets.  Because keys are
  # drawn from only three names, different values routinely meet at the same
  # key -- including attrset-vs-non-attrset, which is the interesting case.
  genPlainLeaf = id: let
    r = rnd id 6;
  in
    if r < 3
    then r
    else if r == 3
    then [r]
    else if r == 4
    then {}
    else 9;

  genPlain = id: depth: let
    n = 1 + rnd id 3;
    picked = builtins.genList (i: builtins.elemAt keys (rnd (id * 7 + i) 3)) n;
    child = i: k: {
      name = k;
      value =
        if depth < 3 && rnd (id * 13 + i) 2 == 0
        then genPlain (id * 31 + i) (depth + 1)
        else genPlainLeaf (id * 17 + i);
    };
  in
    builtins.listToAttrs (lib.imap0 child picked);

  genPlainList = caseId:
    builtins.genList
    (i:
      if rnd (caseId * 977 + i) 30 == 0
      then genPlainLeaf (caseId + i)
      else genPlain (caseId * 101 + i * 7 + 5) 0)
    (1 + rnd (caseId * 3 + 7) 6);

  genPlainContribution = caseId: i: let
    id = caseId * 313 + i * 17 + 9;
    modIx = rnd (id + 1) 4;
  in {
    module = "m${toString modIx}";
    index = modIx;
    value =
      if rnd (id + 2) 40 == 0
      then [1]
      else genPlain id 0;
  };

  genPlainContributions = caseId:
    builtins.genList (genPlainContribution caseId) (1 + rnd (caseId * 5 + 4) 6);

  outcomeNew = v: ref.outcome v;

  range = lib.range 1 cases;

  # ---- compare ----
  conflictSig = cs: map (c: [c.writer.index c.other.index c.writer.module c.other.module]) cs;

  conflictMismatch = caseId: let
    input = genPathContributions caseId;
    sorted = lib.sort (a: b: a.index < b.index) input;
  in
    conflictSig (cg.findSingleConflicts sorted) != conflictSig (ref.findSingleConflicts sorted);

  nestedMismatch = caseId: let
    input = lib.sort (a: b: a.index < b.index) (genContributions caseId);
  in
    cg.applyNestedLeafOverrides "c" input != ref.applyNestedLeafOverrides "c" input;

  # (`recursiveUpdate` itself requires attrset operands at the top level, which
  #  every real caller guarantees; nested values may be anything.)
  recursiveUpdateMismatch = caseId: let
    vs = builtins.filter builtins.isAttrs (genPlainList caseId);
  in
    cg.recursiveUpdateMany vs != ref.recursiveUpdateFold vs;

  mergeNamespacedMismatch = caseId: let
    vs = genPlainList caseId;
  in
    ref.outcome (cg.mergeNamespacedMany "c" [] vs) != ref.outcome (ref.mergeNamespacedFold vs);

  resolveSingleMismatch = caseId: let
    cs = genPlainContributions caseId;
  in
    ref.outcome (cg.resolveSingle "c" cs) != ref.resolveSingleOutcome cs;

  resolveNamespacedMismatch = caseId: let
    cs = genPlainContributions caseId;
  in
    ref.outcome (cg.resolveNamespaced "c" cs) != ref.resolveNamespacedOutcome cs;

  # Structure-level check of the namespaced conflict report (this is what the
  # error message is built from: which paths, and which writers in which order).
  namespacedConflictMismatch = caseId: let
    sorted = lib.sort (a: b: a.index < b.index) (genPlainContributions caseId);
  in
    cg.findNamespacedConflicts "c" sorted != ref.findNamespacedConflicts sorted;

  count = pred: builtins.length (builtins.filter pred range);
  hasConflicts = caseId: let
    sorted = lib.sort (a: b: a.index < b.index) (genPathContributions caseId);
  in
    cg.findSingleConflicts sorted != [];
in {
  inherit cases;
  conflictMismatches = count conflictMismatch;
  nestedMismatches = count nestedMismatch;
  recursiveUpdateMismatches = count recursiveUpdateMismatch;
  mergeNamespacedMismatches = count mergeNamespacedMismatch;
  resolveSingleMismatches = count resolveSingleMismatch;
  resolveNamespacedMismatches = count resolveNamespacedMismatch;
  namespacedConflictMismatches = count namespacedConflictMismatch;
  namespacedCasesWithConflicts = count (c: cg.findNamespacedConflicts "c" (lib.sort (a: b: a.index < b.index) (genPlainContributions c)) != {});
  # Sanity: both outcomes must occur for the end-to-end resolvers.
  singleOk = count (c: (ref.resolveSingleOutcome (genPlainContributions c)) ? ok);
  namespacedOk = count (c: (ref.resolveNamespacedOutcome (genPlainContributions c)) ? ok);
  mergeNamespacedOk = count (c: (ref.outcome (ref.mergeNamespacedFold (genPlainList c))) ? ok);
  # Sanity: the generators must actually produce both outcomes, otherwise the
  # comparison above proves nothing.
  casesWithConflicts = count hasConflicts;
  casesWithoutConflicts = cases - count hasConflicts;
}
