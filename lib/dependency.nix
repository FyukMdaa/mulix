{lib}: let
  inherit (builtins) elem;

  # modules: normalize.nix の normalizeModule 結果のリスト
  #   各要素は { name; receiverArgs; send; ... } を持つ

  sendersOf = modules: configName:
    map (m: m.name)
    (builtins.filter (m: (builtins.hasAttr configName (m.send or {}) || builtins.hasAttr configName (m.always.send or {}))) modules);

  # receiver は「configName を function 引数として要求している module」。
  # options / target fragment の function args も receiver declaration として
  # 扱う。opaque (config 経由) の依存は認識しない。
  receiversOf = modules: configName:
    map (m: m.name)
    (builtins.filter (m: elem configName (m.receiverArgs or m.declaredArgs or [])) modules);

  /*
  buildGraph: modules から configName-registry のキー一覧を使って
  edge 集合 (sender -> configName -> receiver) を構築する。

  戻り値: { edges = [{ from; to; via; }]; }
    from/to は module 名。via は経由した configName。
    「niri → wmconfig → waybar」 は
      { from = "niri"; to = "waybar"; via = "wmconfig"; } として
    1本の module-to-module edge に圧縮する。
  */
  buildGraph = {
    modules,
    configNames,
  }: let
    edges =
      lib.concatMap
      (configName: let
        senders = sendersOf modules configName;
        receivers = receiversOf modules configName;
      in
        lib.concatMap
        (from:
          map (to: {
            inherit from to;
            via = configName;
          })
          receivers)
        senders)
      configNames;
  in {inherit edges;};

  /*
  detectCycles: graph.edges (module 名の有向グラフ) に対して
  深さ優先探索でサイクルを検出する。

  declared dependency graph に対してのみ動作する。
  任意の Nix evaluation expression 中の循環は対象外。

  実装: succ map を事前構築し、DFS に visiting/completed state を持たせる。
  これにより共有される DAG の部分グラフを再探索せず、探索自体を
  O(V + E) に抑える (path/via のコピー分を除く)。
  */
  detectCyclesDfs = {edges}: let
    nodes = lib.unique (lib.concatMap (e: [e.from e.to]) edges);

    succMap =
      builtins.foldl'
      (acc: e:
        acc
        // {
          ${e.from} =
            (acc.${e.from} or [])
            ++ [
              {
                to = e.to;
                via = e.via;
              }
            ];
        })
      {}
      edges;

    succOf = n: succMap.${n} or [];

    # state: 0=unvisited, 1=currently visiting, 2=completed.
    # Completed nodes are never traversed again, avoiding the exponential
    # path explosion of the previous path-only DFS on DAGs with fan-in.
    visit = state: start: let
      walk = st: path: vias: node:
        let
          nodeState = st.${node} or 0;
        in
          if nodeState == 1 then
            let
              idx = lib.lists.findFirstIndex (x: x == node) null path;
              len = builtins.length path - idx;
              cyclePath = (lib.sublist idx len path) ++ [node];
              viaPath = lib.sublist idx len vias;
            in {
              state = st;
              found = true;
              cycle = cyclePath;
              vias = viaPath;
            }
          else if nodeState == 2 then
            { state = st; found = false; cycle = []; vias = []; }
          else
            let
              stEntering = st // { ${node} = 1; };
              step = acc: succ:
                if acc.found then acc
                else
                  let
                    child = walk
                      acc.state
                      (path ++ [node])
                      (vias ++ [succ.via])
                      succ.to;
                  in child;
              walked = lib.foldl' step
                { state = stEntering; found = false; cycle = []; vias = []; }
                (succOf node);
              stDone = if walked.found then walked.state else walked.state // { ${node} = 2; };
            in
              walked // { state = stDone; };
    in
      if state.found
      then state
      else walk state [] [] start;

    result =
      lib.foldl'
      (state: start: visit state start)
      { found = false; cycle = []; vias = []; state = {}; }
      nodes;
  in
    builtins.removeAttrs result ["state"];

  # Fast acyclicity test: repeatedly drop every edge whose source has no
  # incoming edge (a node with in-degree 0 can never be on a cycle).  If the
  # edge list empties, the graph is acyclic; if a round removes nothing while
  # edges remain, every remaining edge lies on or leads into a cycle.
  #
  # One round is O(E) and the number of rounds is the length of the longest
  # dependency chain, so realistic (shallow) module graphs are O(E) overall.
  # (The DFS below copies its visited-state map at every step, which is O(V^2).)
  isAcyclic = edges: let
    round = es: let
      hasIncoming = builtins.listToAttrs (map (e: {name = e.to; value = true;}) es);
      remaining = builtins.filter (e: builtins.hasAttr e.from hasIncoming) es;
    in
      if remaining == []
      then true
      else if builtins.length remaining == builtins.length es
      then false
      else round remaining;
  in
    round edges;

  # Same result as detectCyclesDfs.  The cheap test above decides whether there
  # is a cycle at all; only when there is one is the DFS run (unchanged), so the
  # reported cycle -- including which node it starts from -- is exactly what the
  # DFS has always reported, while the common no-cycle case never pays for it.
  detectCycles = {edges}:
    if isAcyclic edges
    then { found = false; cycle = []; vias = []; }
    else detectCyclesDfs { inherit edges; };

  formatCycleError = {
    cycle,
    vias,
    ...
  }: let
    # cycle = [ A B C A ], vias = [ x y z ] (edge cycle[i] -> cycle[i+1]
    # が configName vias[i] を経由する)
    hop = i: "${builtins.elemAt cycle i} --${builtins.elemAt vias i}-->";
    hops =
      lib.concatStringsSep " "
      (lib.imap0 (i: _: hop i) vias)
      + " ${builtins.head cycle}";
    # A -> A: the same module name is both ends of the edge, i.e. the module
    # sends and receives the same configName.  This is an error by design.
    isSelfDependency =
      builtins.length cycle == 2
      && builtins.elemAt cycle 0 == builtins.elemAt cycle 1;
    selfDetail = ''
      module '${builtins.head cycle}' depends on itself: it both sends and receives configName '${builtins.head vias}'.
      The same module name appears more than once in the cycle, which is not allowed.
      help: receive the configName in a different module (module names must be unique),
      help: or remove the receiving argument from this module.
    '';
    headline = "mulix: dependency cycle detected";
  in ''
    ${headline}
    ${hops}
    ${if isSelfDependency then selfDetail else ""}(declared dependency graph cycle detection)
  '';

  # 便利関数: buildGraph + detectCycles をまとめて実行し、
  # サイクルがあれば throw する。
  checkNoCycles = {
    modules,
    configNames,
  }: let
    graph = buildGraph {inherit modules configNames;};
    result = detectCycles graph;
  in
    if result.found
    then throw (formatCycleError result)
    else graph;
in {
  inherit
    sendersOf
    receiversOf
    buildGraph
    detectCycles
    detectCyclesDfs
    formatCycleError
    checkNoCycles
    ;
}
