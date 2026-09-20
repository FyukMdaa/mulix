# Differential test for the cycle detector: the fast acyclicity pre-check must
# never change what detectCycles reports.  Random small digraphs over 6 nodes
# (dense enough to contain cycles, self-loops, shared sub-DAGs, disconnected parts).
{ lib, cases ? 3000 }:
let
  d = import ../../lib/dependency.nix { inherit lib; };
  modn = a: n: a - (a / n) * n;
  mix = x: modn (x * 1103515245 + 12345) 2147483648;
  rnd = id: bound: modn (mix (mix (mix (modn (modn id 2147483647 * 2654435761 + 97) 2147483648))) / 65536) bound;

  nodeName = i: "n${toString i}";
  genEdges = caseId: let
    count = rnd (caseId * 3 + 1) 9;             # 0..8 edges
  in builtins.genList
    (i: {
      from = nodeName (rnd (caseId * 101 + i * 7 + 1) 6);
      to = nodeName (rnd (caseId * 101 + i * 7 + 2) 6);
      via = "v${toString (rnd (caseId * 101 + i * 7 + 3) 3)}";
    })
    count;

  range = lib.range 1 cases;
  mismatch = c: let es = genEdges c; in d.detectCycles { edges = es; } != d.detectCyclesDfs { edges = es; };
  count = pred: builtins.length (builtins.filter pred range);
in {
  inherit cases;
  mismatches = count mismatch;
  # Sanity: both kinds of graph must occur.
  cyclic = count (c: (d.detectCyclesDfs { edges = genEdges c; }).found);
  acyclic = count (c: !(d.detectCyclesDfs { edges = genEdges c; }).found);
}
