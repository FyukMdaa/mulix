{lib}: let
  inherit (builtins) elem;
  overlap = import ./config-graph/overlap.nix {inherit lib;};
  inherit (overlap) sendStaticPaths;

  # modules: normalize.nix の normalizeModule 結果のリスト
  #   各要素は { name; receiverArgs; send; sendForce; ... } を持つ

  sendersOf = modules: configName:
    map (m: m.name)
    (builtins.filter
      (m:
        builtins.hasAttr configName (m.send or {})
        || builtins.hasAttr configName (m.sendForce or {})
        || builtins.hasAttr configName (m.always.send or {}))
      modules);

  # receiver は「configName を function 引数として要求している module」。
  # options / target fragment の function args も receiver declaration として
  # 扱う。opaque (config 経由) の依存は認識しない。
  receiversOf = modules: configName:
    map (m: m.name)
    (builtins.filter (m: elem configName (m.receiverArgs or m.declaredArgs or [])) modules);

  /*
  sendWriteInfoOf: module m の configName への書き込みの静的情報 (Phase 3)。
  sender でない場合 (configName に send しない) は null。
  sender の場合:
    { known = true;  paths = [ path ... ]; }   書き込みpathが静的に既知
    { known = false; reason = "..."; }          未知。reason はその理由

  unknown になるのは (reason で区別する):
    - 全体関数 send (contribution 全体が関数。書き込みpathは呼ぶまで未知)
    - 値の途中に module system の property wrapper (mkIf 等) がある
      (条件の評価を強制しないために構造を辿らない)
    - send値の構造を辿ると receiver 引数参照などで throw する
      (tryEval で保護。評価を強制しない)

  リーフ関数 (derived contribution, `send.<configName>.<path...> = fn`) は
  ネストキーで書き込みpathが宣言されるため既知pathとして扱う。
  */
  sendWriteInfoOf = m: configName: let
    topVals =
      lib.concatMap
      (set:
        lib.optional
        (builtins.hasAttr configName set)
        set.${configName})
      [(m.send or {}) (m.sendForce or {}) (m.always.send or {})];
    ctx = "configName '${configName}' (module '${m.name}')";
  in
    if topVals == []
    then null
    else if builtins.any lib.isFunction topVals
    then {
      known = false;
      reason = "the contribution is a whole-contribution function (send.<configName> = fn): its write paths are only known once it is applied";
    }
    else let
      # tryEval: walking a send value forces its structure, and a leaf may
      # reference the module's own configName argument (or anything else
      # that throws / recurses when forced this early).  Such a value cannot
      # be analysed, so fall back to "unknown writes", which preserves the
      # self-loop error for the receiving module and defers the real error
      # to evaluation.
      pathSets =
        map (v: builtins.tryEval (sendStaticPaths ctx [] v)) topVals;
    in
      # 未知の理由を区別して報告する (循環エラーの詳細ブロック用)。
      if builtins.any (p: !p.success) pathSets
      then {
        known = false;
        reason = "the send value cannot be analysed at declaration time: forcing its structure evaluates a receiver argument (or throws)";
      }
      else if builtins.any (p: p.value == null) pathSets
      then {
        known = false;
        reason = "the contribution contains a property wrapper (mkIf etc.): mulix does not traverse wrappers, to avoid forcing the condition";
      }
      else {
        known = true;
        paths = lib.unique (builtins.concatLists (map (p: p.value) pathSets));
      };

  /*
  sendInfoOf: 旧形式 (path リスト | null)。sendWriteInfoOf のラッパ。
  書き込みpathが既知ならそのリスト、未知 (または sender でない) なら null。
  */
  sendInfoOf = m: configName: let
    info = sendWriteInfoOf m configName;
  in
    if info == null
    then null
    else if info.known
    then info.paths
    else null;

  /*
  buildGraph: modules から configName-registry のキー一覧を使って
  edge 集合 (sender -> configName -> receiver) を構築する。

  戻り値: { edges = [{ from; to; via; writePaths; writeReason; }]; }
    from/to は module 名。via は経由した configName。
    「niri → wmconfig → waybar」 は
      { from = "niri"; to = "waybar"; via = "wmconfig"; } として
    1本の module-to-module edge に圧縮する。
    writePaths / writeReason は sender 側の書き込みpath情報 (Phase 3):
    既知なら writePaths = leaf path のリスト (writeReason = null)、
    未知なら writePaths = null (writeReason = 未知の理由文)。

  自己フィード (同一 module が同一 configName に send し、かつ受信する) は、
  その send の書き込みpathが静的に既知 (plain data または derived leaf
  function) であれば edge を張らない。静的な contribution は解決済み値を
  読まないため、自己受信しても再帰は起きない。書き込みpathが未知の
  (全体関数 send / property wrapper を含む値の) み自己エッジとして
  検出対象にする。
  */
  buildGraph = {
    modules,
    configNames,
  }: let
    edges =
      lib.concatMap
      (configName: let
        senderModules =
          builtins.filter
          (m:
            builtins.hasAttr configName (m.send or {})
            || builtins.hasAttr configName (m.sendForce or {})
            || builtins.hasAttr configName (m.always.send or {}))
          modules;
        senderInfo =
          map (m: {
            name = m.name;
            info = sendWriteInfoOf m configName;
          })
          senderModules;
        receivers = receiversOf modules configName;
      in
        lib.concatMap
        (s:
          let
            # sender 側の書き込みpath情報を edge に載せる (循環エラーの
            # 詳細ブロック用)。既知なら path リスト、未知なら reason。
            writeFields =
              if s.info.known
              then {
                writePaths = s.info.paths;
                writeReason = null;
              }
              else {
                writePaths = null;
                writeReason = s.info.reason;
              };
          in
            lib.concatMap
            (to:
              if s.name == to
              then
                lib.optional (!s.info.known)
                ({
                  from = s.name;
                  to = to;
                  via = configName;
                }
                // writeFields)
              else [
                ({
                  from = s.name;
                  inherit to;
                  via = configName;
                }
                // writeFields)
              ])
            receivers)
        senderInfo)
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

    # edge の詳細 (書き込みpath情報) も succ に載せて巡回する。
    # property test など from/to/via しか持たない edge にも耐える
    # (`or null`)。
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
                writePaths = e.writePaths or null;
                writeReason = e.writeReason or null;
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
      walk = st: path: vias: details: node: let
        nodeState = st.${node} or 0;
      in
        if nodeState == 1
        then let
          idx = lib.lists.findFirstIndex (x: x == node) null path;
          len = builtins.length path - idx;
          cyclePath = (lib.sublist idx len path) ++ [node];
          viaPath = lib.sublist idx len vias;
          detailPath = lib.sublist idx len details;
        in {
          state = st;
          found = true;
          cycle = cyclePath;
          vias = viaPath;
          details = detailPath;
        }
        else if nodeState == 2
        then {
          state = st;
          found = false;
          cycle = [];
          vias = [];
          details = [];
        }
        else let
          stEntering = st // {${node} = 1;};
          step = acc: succ:
            if acc.found
            then acc
            else let
              child =
                walk
                acc.state
                (path ++ [node])
                (vias ++ [succ.via])
                (details ++ [succ])
                succ.to;
            in
              child;
          walked =
            lib.foldl' step
            {
              state = stEntering;
              found = false;
              cycle = [];
              vias = [];
              details = [];
            }
            (succOf node);
          stDone =
            if walked.found
            then walked.state
            else walked.state // {${node} = 2;};
        in
          walked // {state = stDone;};
    in
      if state.found
      then state
      else walk (state.state or {}) [] [] [] start;

    result =
      lib.foldl'
      (state: start: visit state start)
      {
        found = false;
        cycle = [];
        vias = [];
        details = [];
        state = {};
      }
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
      hasIncoming = builtins.listToAttrs (map (e: {
          name = e.to;
          value = true;
        })
        es);
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
    then {
      found = false;
      cycle = [];
      vias = [];
      details = [];
    }
    else detectCyclesDfs {inherit edges;};

  formatCycleError = {
    cycle,
    vias,
    details ? [],
    ...
  }: let
    # cycle = [ A B C A ], vias = [ x y z ] (edge cycle[i] -> cycle[i+1]
    # が configName vias[i] を経由する), details = [ edge詳細 ... ] (vias と
    # 同じ長さ。各要素は { writePaths; writeReason; } または null)。
    hop = i: "${builtins.elemAt cycle i} --${builtins.elemAt vias i}-->";
    hops =
      lib.concatStringsSep " "
      (lib.imap0 (i: _: hop i) vias)
      + " ${builtins.head cycle}";
    # Phase 3: 各エッジの書き込みpathを詳細ブロックに列挙する。
    # 既知なら path 一覧、未知ならその理由 (全体関数 send / property
    # wrapper / 宣言時評価不能) をそのまま表示する。
    formatPath = p: "." + lib.concatStringsSep "." p;
    formatPaths = ps:
      if ps == []
      then "no leaf paths (empty attrset contribution)"
      else if ps == [ [] ]
      then "the whole configName"
      else "[" + lib.concatStringsSep ", " (map formatPath ps) + "]";
    # imap0 は f を (index, element) の2引数で呼ぶ。detailLine はそれに合わせて
    # 2引数 (i: d: ...) を取る (v6 では1引数のまま imap0 に渡しており、
    # 「attempt to call something which is not a function but a string」で
    # 落ちていた)。
    detailLine = i: d: let
      writes =
        if d == null
        then null
        else if d.writePaths or null != null
        then "writes ${formatPaths d.writePaths}"
        else if d.writeReason or null != null
        then "writes unknown paths -- ${d.writeReason}"
        else null;
    in
      if writes == null
      then null
      else "  ${hop i} ${builtins.elemAt cycle (i + 1)}: ${writes}";
    detailLines =
      lib.filter (l: l != null) (lib.imap0 detailLine details);
    detailBlock =
      if detailLines == []
      then ""
      else
        "write paths along the cycle:\n"
        + lib.concatStringsSep "\n" detailLines
        + "\n";
    # A -> A: the same module name is both ends of the edge, i.e. the module
    # sends and receives the same configName, and at least one of its sends
    # has statically unknown write paths.  Such a send is applied with the
    # resolved value -- including its own contribution -- so depending on it
    # from the same module risks infinite recursion.  Plain data sends and
    # derived leaf-function sends (write paths declared by nesting) are
    # allowed to self-feed and never reach this error.
    isSelfDependency =
      builtins.length cycle
      == 2
      && builtins.elemAt cycle 0 == builtins.elemAt cycle 1;
    selfReason =
      if details != [] && builtins.head details != null
      then (builtins.head details).writeReason or null
      else null;
    selfDetail = ''
      module '${builtins.head cycle}' depends on itself: it both sends and receives configName '${builtins.head vias}'.
      The same module name appears more than once in the cycle, which is not allowed.
      This is reported because the write paths of this module's send to this
      configName cannot be determined statically:
        ${if selfReason != null then selfReason else "the send value could not be analysed"}
      so it reads the resolved value including its own contribution.
      Plain data sends and derived leaf-function sends (write paths declared
      by nesting) are allowed to self-feed and never reach this error.
      help: send plain data, or declare a derived contribution by nesting the
      help: function under an explicit path (send.<configName>.<path...> = fn),
      help: or receive the configName in a different module (module names must be unique).
    '';
    headline = "mulix: dependency cycle detected";
  in ''
    ${headline}
    ${hops}
    ${detailBlock}${
      if isSelfDependency
      then selfDetail
      else ""
    }(declared dependency graph cycle detection)
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
    then
      throw
      (formatCycleError {
        inherit (result) cycle vias;
        details = result.details or [];
      })
    else graph;
in {
  inherit
    sendersOf
    receiversOf
    sendInfoOf
    sendWriteInfoOf
    buildGraph
    detectCycles
    detectCyclesDfs
    formatCycleError
    checkNoCycles
    ;
}
