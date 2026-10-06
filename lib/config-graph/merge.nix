# Merge strategies and value resolution for the configName graph.
#
# This file owns:
#   - the three merge strategies `single` / `namespaced` / `ordered`
#     (`resolveSingle`, `resolveNamespaced`, `resolveOrdered`,
#     `resolveByStrategy`);
#   - the public resolution entry points `resolveConfigNameWithPresence`
#     and `resolveAll`.
#
# Dependency injection:
#   The merge strategies consume helpers from `overlap.nix` (path overlap
#   index, send value traversal) and the `validateRegistry` / `validateType`
#   entry points from `registry.nix`. Rather than prefix every call site
#   with `overlap.` or `registry.`, this file `inherit`s the needed names
#   into its own `let` scope, so the function bodies are unchanged from
#   the original monolithic `config-graph.nix`.
{lib}: let
  inherit (builtins) isAttrs isList elem attrNames;
  overlap = import ./overlap.nix {inherit lib;};
  inherit (overlap)
    recursiveUpdateMany
    collectPathsIn
    pathsOverlap
    pathKey
    formatPath
    formatWriter
    collectLeafWrites
    applyNestedLeafOverrides
    buildOverlapIndex
    overlapMinOther
    ;
  registry = import ./registry.nix {inherit lib;};
  inherit (registry) validateRegistry validateType mergeStrategies;
  findSingleConflicts = withPaths: let
    numbered = lib.imap0 (pos: c: {inherit pos c;}) withPaths;
    index =
      buildOverlapIndex
      (lib.concatMap
        (n:
          map (p: {
            path = p;
            module = n.c.module;
            rank = n.pos;
          })
          n.c.paths)
        numbered);
    conflictFor = n: let
      found =
        lib.foldl'
        (acc: hit:
          if hit == null
          then acc
          else if acc == null || hit.rank < acc.rank
          then hit
          else acc)
        null
        (map (p: overlapMinOther index p n.c.module) n.c.paths);
    in
      if found == null || found.rank >= n.pos
      then []
      else [
        {
          writer = n.c;
          other = builtins.elemAt withPaths found.rank;
        }
      ];
  in
    lib.concatMap conflictFor numbered;

  resolveSingle = configName: contributions:
  # [{ module; value; index; }]
  let
    sorted = lib.sort (a: b: a.index < b.index) contributions;

    badValues = builtins.filter (c: !(isAttrs c.value)) sorted;

    withPaths = map (c:
      c
      // {
        # Only leaf paths represent actual writes.  Intermediate paths are
        # not owned by a writer: A.foo and B.bar may coexist under the same
        # top-level attribute.  Prefix conflicts are checked explicitly below
        # (e.g. A.foo versus B.foo.bar).
        paths = collectPathsIn "configName '${configName}' (module '${c.module}')" [] c.value;
      })
    sorted;

    conflicts = findSingleConflicts withPaths;

    formatConflict = conflict: let
      a = conflict.writer;
      b = conflict.other;
      # Every overlapping *path* (a list of attr names) of `a` against `b`.
      overlappingPaths =
        lib.unique
        (lib.concatMap
          (p: map (q: p) (lib.filter (q: pathsOverlap p q) b.paths))
          a.paths);
    in ''
      paths:
        ${lib.concatStringsSep ", " (map formatPath overlappingPaths)}
      writers:
        - ${formatWriter a}
        - ${formatWriter b}
    '';

    conflictText =
      lib.concatStringsSep "\n" (map formatConflict conflicts);
  in
    if badValues != []
    then
      throw ''
        mulix: type error
        configName: ${configName}
        strategy: single
        writer(s) [${builtins.concatStringsSep ", " (map (c: c.module) badValues)}]
        did not provide an attrset value
        (The contribution of “single strategy” is “attrset.)
      ''
    else if conflicts != []
    then
      throw ''
        mulix: ownership conflict
        configName: ${configName}
        strategy: single
        conflicting path count: ${toString (builtins.length conflicts)}
        ${conflictText}
        (In a single strategy, leaf paths must not overlap or be nested
         across different modules.)
      ''
    else recursiveUpdateMany (map (c: c.value) sorted);

  # ---- namespaced strategy ----

  namespacedLeafClash = configName: path:
    throw ''
      mulix: ownership conflict
      configName: ${configName}
      path: ${formatPath path}
      strategy: namespaced
      (There are multiple writers on the same leaf.
       Namespaced strategies do not allow overwriting on a leaf by a later writer.)
    '';

  # Union of the contributions' attrsets, in ONE pass.  Where two or more
  # values meet at a key they must all be attrsets (and are merged
  # recursively); anything else is a clash on a leaf and throws -- lazily, at
  # the key, exactly like the pairwise merge it replaces.
  mergeNamespacedMany = configName: path: values:
    if !(lib.all isAttrs values)
    then namespacedLeafClash configName path
    else let
      entries = lib.concatMap (v:
        lib.mapAttrsToList (k: x: {
          name = k;
          value = x;
        })
        v)
      values;
      grouped = builtins.groupBy (e: e.name) entries;
    in
      builtins.mapAttrs
      (k: es:
        if builtins.length es == 1
        then (builtins.head es).value
        else mergeNamespacedMany configName (path ++ [k]) (map (e: e.value) es))
      grouped;

  # pathKey -> writers of that leaf path (in resolution order), restricted to
  # leaf paths that more than one MODULE writes.  `sorted` is in resolution order.
  findNamespacedConflicts = configName: sorted: let
    pathWriters =
      builtins.mapAttrs
      (_: es: map (e: e.writer) es)
      (builtins.groupBy
        (e: e.key)
        (lib.concatMap
          (c:
            map
            (p: {
              key = pathKey p;
              writer = {
                module = c.module;
                source = c.source or null;
                path = p;
              };
            })
            (collectPathsIn "configName '${configName}' (module '${c.module}')" [] c.value))
          sorted));
  in
    lib.filterAttrs (_: writers: lib.length (lib.unique (map (w: w.module) writers)) > 1) pathWriters;

  resolveNamespaced = configName: contributions: let
    sorted = lib.sort (a: b: a.index < b.index) contributions;
    conflicts = findNamespacedConflicts configName sorted;
    conflictText = lib.concatStringsSep "\n" (lib.mapAttrsToList (_: writers: let
      p = builtins.head writers;
    in ''
      path: ${formatPath p.path}
      writers:
        ${lib.concatStringsSep "\n  " (map (w: "- " + formatWriter w) writers)}'')
    conflicts);
  in
    if conflicts != {}
    then
      throw ''
        mulix: ownership conflict
        configName: ${configName}
        strategy: namespaced
        ${conflictText}
        (There are multiple writers on the same leaf.
         Namespaced strategies do not allow overwriting on a leaf by a later writer.)
      ''
    else mergeNamespacedMany configName [] (map (c: c.value) sorted);

  # ---- ordered strategy ----

  resolveOrdered = configName: contributions: let
    # `contributions` arrive already ordered by applySendProperties
    # (mkBefore / mkAfter / mkOrder, stable w.r.t. module order).  Re-sorting
    # by module index here would silently undo that.
    sorted = contributions;
    bad = builtins.filter (c: !(isList c.value)) sorted;
  in
    if bad != []
    then
      throw ''
        mulix: type error
        configName: ${configName}
        strategy: ordered
        writer(s) [${builtins.concatStringsSep ", " (map (c: c.module) bad)}]
        did not provide a list value (The value of `ordered` must be of type `list` only.)
      ''
    else lib.concatMap (c: c.value) sorted;

  resolveByStrategy = strategy: configName: contributions: let
    normalized = applyNestedLeafOverrides configName contributions;
  in
    if strategy == "single"
    then resolveSingle configName normalized
    else if strategy == "namespaced"
    then resolveNamespaced configName normalized
    else if strategy == "ordered"
    then resolveOrdered configName normalized
    else throw "mulix: internal error: unknown merge strategy '${strategy}'";

  # ---- default handling ----

  resolveConfigNameWithPresence = registry: configName: contributions: forceValue: forcePresent: baseValues: let
    entry =
      registry.${
        configName
      } or (throw ''
        mulix: unknown configName: '${configName}'
        (all configName must be declared in the registry before use)
      '');

    isModulesBinding = (entry.bind or null) == "mulix.modules";
    hasBoundBase = isModulesBinding && builtins.hasAttr configName baseValues;
    boundBase =
      if hasBoundBase
      then baseValues.${configName}
      else {};

    sentValue =
      if contributions != []
      then resolveByStrategy entry.merge configName contributions
      else if hasBoundBase
      then boundBase
      else if entry ? default
      then entry.default
      else
        throw ''
          mulix: configName '${configName}' has no value
          no enabled sender contributed, and no default is declared
          (this error is raised lazily, only when a receiver
           actually accesses this configName)
        '';

    base =
      if hasBoundBase && contributions != []
      then
        if isAttrs boundBase && isAttrs sentValue
        then lib.recursiveUpdate boundBase sentValue
        else sentValue
      else sentValue;
  in let
    # force 適用 (force は最終値を override する)。
    # force が attrset の場合は path 単位の deep merge、
    # それ以外は全置換。
    finalValue =
      if !forcePresent
      then base
      else if isAttrs base && isAttrs forceValue
      then lib.recursiveUpdate base forceValue
      else forceValue;
  in
    builtins.seq
    (validateType configName "resolved value" entry.type finalValue)
    finalValue;

  /*
  resolveAll:
    registry       = configName registry (name -> entry)。上記の通り
                     未登録 configName への send / force は error。
    contributions  = [{ module; configName; value; index; }]
                      (optional eager list for direct library use)
    contributionsFor = configName: [{ module; configName; value; index; }]
                      (推奨。configName ごとに lazy に sender を評価する。
                       `enable` が別の configName を読む場合の循環を避けるために
                       必要。send は conditional output)
    force           = host force attrset (name -> value),

  戻り値: configName -> resolved value の attrset。
  未参照の configName で missing-value になる場合でも、Nix の laziness
  により実際にアクセスされるまで throw は発火しない。

  --- laziness と構造検査の配置 ---

  この関数の WHNF (attrset の構築) は registry にのみ依存し、
  contributions に依存しない。これは default.nix の循環評価回避に
  必須である: module function 呼び出し引数に configGraphThunk を
  含むため、resolveAll の WHNF が contributions を要求すると
  「module function 呼び出し → configGraph WHNF → contributions →
  module function 呼び出し」の無限再帰になる。

  そのため unknown send / force の検査は「いずれかの configName 値を
  最初に参照した時点」で発火する (builtins.seq)。mkMulix 経由で
  normalization 段階の eager 検査が必要な場合は default.nix 側の
  builtins.seq による構造チェックが先にこれを検出する。
  */
  resolveAll = {
    registry,
    contributions ? [],
    contributionsFor ? null,
    force ? {},
    baseValues ? {},
  }: let
    validated = validateRegistry registry;

    registryNames = attrNames validated;

    unknownSenders =
      builtins.filter
      (c: !(elem c.configName registryNames))
      contributions;

    unknownForceNames =
      builtins.filter
      (k: !(elem k registryNames))
      (attrNames force);

    structuralCheck =
      if unknownSenders != []
      then
        throw ''
          mulix: unknown configName in send
          module(s) send to configName(s) not declared in the registry:
            ${lib.concatStringsSep "\n  "
            (map (c: "- ${c.configName} (by module '${c.module}')")
              unknownSenders)}
          (all configName must be declared in the registry before use)
        ''
      else if unknownForceNames != []
      then
        throw ''
          mulix: unknown configName in force
          force targets configName(s) not declared in the registry:
            ${builtins.concatStringsSep ", " unknownForceNames}
          (all configName must be declared in the registry before use)
        ''
      else true;

    byConfigName =
      if contributionsFor == null
      then lib.groupBy (c: c.configName) contributions
      else {};

    contributionsOf = configName:
      if contributionsFor == null
      then byConfigName.${configName} or []
      else contributionsFor configName;
  in
    # mapAttrs 自体は registry のキーだけを構築し、各 value は lazy に
    # contributionsOf configName を要求する。これにより `waybar.enable =
    # wmconfig.bar == "waybar"` の評価では wmconfig の sender だけが評価され、
    # 無関係な sender の enable を先に全件評価しない。
    lib.mapAttrs
    (configName: entry:
      builtins.seq structuralCheck
      (resolveConfigNameWithPresence
        validated
        configName
        (contributionsOf configName)
        (force.${configName} or null)
        (builtins.hasAttr configName force)
        baseValues))
    validated;

in rec {
  inherit
    findSingleConflicts
    resolveSingle
    namespacedLeafClash
    mergeNamespacedMany
    findNamespacedConflicts
    resolveNamespaced
    resolveOrdered
    resolveByStrategy
    resolveConfigNameWithPresence
    resolveAll
    ;
}
