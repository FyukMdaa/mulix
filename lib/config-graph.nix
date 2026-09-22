{lib}: let
  inherit (builtins) isAttrs isList attrNames elem;

  mergeStrategies = ["single" "namespaced" "ordered"];

  # ---- registry validation ----

  validateType = configName: fieldName: type: value:
    if !(type.check value)
    then
      throw ''
        mulix: type error in configName '${configName}'
        field: ${fieldName}
        value does not satisfy the declared Nix type
      ''
    else
      let
        merged = lib.modules.mergeDefinitions
          ["mulix" configName fieldName]
          type
          [{
            file = "<mulix ${configName}.${fieldName}>";
            inherit value;
          }];
      in
      # Use Nix's canonical option-definition validation path.  For V2 types,
      # mergeDefinitions checks `headError` produced by the type's merge.v2
      # implementation, which is where attrsOf/listOf report nested failures.
      # Force the result because registry validation is intentionally eager.
      builtins.deepSeq merged true;

  validateRegistryEntry = configName: entry:
    if !isAttrs entry
    then
      throw ''
        mulix: invalid configName registry entry '${configName}'
        expected an attrset, got: ${builtins.typeOf entry}
      ''
    else let
      binding = entry.bind or null;
      isModulesBinding = binding == "mulix.modules";
      hasType = entry ? type;
      hasDefault = entry ? default;
      strategy =
        if isModulesBinding
        then entry.merge or "single"
        else entry.merge or (throw ''
          mulix: invalid configName registry entry '${configName}'
          missing required field: merge
        '');
      ownership = entry.ownership or "path";
      normalized =
        if isModulesBinding
        then entry // {
          type = lib.types.attrs;
          merge = strategy;
          default = {};
          bind = "mulix.modules";
        }
        else entry;
      type = normalized.type or null;
      hasTypeCheck = type != null && (type ? check);
      defaultCheck =
        if !(normalized ? type)
        then true
        else if normalized ? default
        then validateType configName "default" normalized.type normalized.default
        else true;
      orderedTypeCheck =
        if strategy == "ordered"
        then
          if (type.name or null) == "listOf"
          then true
          else
            throw ''
              mulix: invalid configName registry entry '${configName}'
              merge strategy 'ordered' requires a list-compatible Nix type
            ''
        else true;
      bindingCheck =
        if binding != null && !isModulesBinding
        then
          throw ''
            mulix: invalid configName registry entry '${configName}'
            unknown binding '${binding}'
            supported bindings: mulix.modules
          ''
        else if isModulesBinding && hasType
        then
          throw ''
            mulix: invalid configName registry entry '${configName}'
            bind = "mulix.modules" owns the type; do not specify 'type'
          ''
        else if isModulesBinding && hasDefault
        then
          throw ''
            mulix: invalid configName registry entry '${configName}'
            bind = "mulix.modules" owns the default; do not specify 'default'
          ''
        else if isModulesBinding && !(builtins.elem strategy ["single" "namespaced"])
        then
          throw ''
            mulix: invalid configName registry entry '${configName}'
            bind = "mulix.modules" only supports merge strategy 'single' or 'namespaced'
          ''
        else true;
    in
      builtins.seq bindingCheck
      (if !(normalized ? type)
       then throw ''
         mulix: invalid configName registry entry '${configName}'
         missing required field: type
       ''
       else if !hasTypeCheck
       then throw ''
         mulix: invalid configName registry entry '${configName}'
         field 'type' is not a Nix option type with a check function
       ''
       else if !(elem strategy mergeStrategies)
       then throw ''
         mulix: invalid configName registry entry '${configName}'
         invalid merge strategy '${strategy}',
         expected one of: ${builtins.concatStringsSep ", " mergeStrategies}
       ''
       else if ownership != "path"
       then throw ''
         mulix: invalid configName registry entry '${configName}'
         invalid ownership '${ownership}', expected: path
       ''
       else if strategy == "ordered" && (normalized ? default) && !(isList normalized.default)
       then throw ''
         mulix: invalid configName registry entry '${configName}'
         merge strategy 'ordered' requires default to be a list
       ''
       else
         builtins.seq orderedTypeCheck
         (builtins.seq defaultCheck
           (normalized // {inherit ownership;})));

  # reservedNames is intentionally opt-in here: the graph library can validate
  # a registry independently, while mkMulix supplies the actual public
  # function-argument namespace and turns collisions into construction-time
  # errors.
  validateRegistryWithReserved = registry: { reservedNames ? [] }:
    let
      collisions = builtins.filter (name: elem name reservedNames) (attrNames registry);
    in
      if collisions != []
      then
        throw ''
          mulix: configName registry contains reserved function argument name(s):
          ${builtins.concatStringsSep ", " collisions}
          These names are reserved by mulix and cannot be used as configName
          because receiver function arguments would shadow mulix built-ins.
        ''
      else
        lib.mapAttrs validateRegistryEntry registry;

  validateRegistry = registry: validateRegistryWithReserved registry {};

  # ---- path collection (for single-strategy ownership checking) ----

  # attrset を再帰的に辿り、実際に値を書き込む leaf path だけを列挙する。
  # 中間 path 自体は所有権を持たないため、兄弟キー共有を許可できる。
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
      other = builtins.listToAttrs
        (builtins.filter (kv: kv.value.module != best.${kv.name}.module) keyed);
    in { inherit best other; };
  in {
    exact = summarize (map (e: { name = pathKey e.path; value = e; }) sorted);
    below = summarize
      (lib.concatMap
        (e: map (k: { name = k; value = e; }) (properPrefixKeys e.path))
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
      (acc: i: if isAttrs (builtins.elemAt values i) then acc else i)
      (-1)
      (lib.range 0 (n - 1));
    run = lib.drop (lastNonAttr + 1) values;
    entries = lib.concatMap (v: lib.mapAttrsToList (k: x: {name = k; value = x;}) v) run;
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
      if f == null then null
      else if f.module != module then f
      else summary.other.${k} or null;
    candidates =
      [ (pick index.exact (pathKey path)) (pick index.below (pathKey path)) ]
      ++ map (k: pick index.exact k) (properPrefixKeys path);
  in
    lib.foldl'
    (acc: c:
      if c == null then acc
      else if acc == null || c.rank < acc.rank then c
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

  formatWriter = w:
    "${w.module}${if (w.source or null) == null then "" else " [source: ${w.source}]"}";

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

  collectLeafWrites = ctx: prefix: value: inheritedPriority:
    let
      propertyType = if isAttrs value then value._type or null else null;
    in
      if propertyType == "override"
      # An override replaces the priority for everything below it.  (It must
      # not be `min`-ed with the inherited priority: the inherited default is
      # 100, which would turn mkDefault (1000) into a normal definition.)
      then collectLeafWrites ctx prefix value.content value.priority
      else if propertyType == "if"
      then if value.condition
        then collectLeafWrites ctx prefix value.content inheritedPriority
        else []
      else if propertyType == "merge"
      then lib.concatMap (v: collectLeafWrites ctx prefix v inheritedPriority) value.contents
      else if propertyType == "order"
      then collectLeafWrites ctx prefix value.content inheritedPriority
      else if isAttrs value && !(isOpaqueValue value)
      then
        let
          entries = builtins.seq (checkSendDepth ctx prefix)
            (lib.mapAttrsToList
              (k: v: collectLeafWrites ctx (prefix ++ [k]) v inheritedPriority)
              value);
        in
          if entries == []
          # An empty attrset defines nothing: it is kept in the result (so
          # `foo = {}` stays `foo = {}`) but it owns no path -- collectPathsIn
          # gives it none -- and therefore must not override other modules'
          # values either.  `inert` marks such a write.
          then [{path = prefix; inherit value; priority = inheritedPriority; inert = true;}]
          else lib.concatLists entries
      else
        [{path = prefix; inherit value; priority = inheritedPriority;}];

  applyNestedLeafOverrides = configName: contributions: let
    numbered = lib.imap0 (cid: contribution: contribution // {_mulixContributionId = cid;}) contributions;

    writes = lib.concatMap
      (contribution:
        map
          (write: write // {
            contributionId = contribution._mulixContributionId;
            module = contribution.module;
          })
          (collectLeafWrites "configName '${configName}' (module '${contribution.module}')" [] contribution.value defaultOverridePriority))
      (builtins.filter (c: isAttrs c.value) numbered);

    # A write is dominated when a write of a different module, on an
    # overlapping path, has a strictly smaller priority number.
    # Inert writes (empty attrsets) never dominate anything, so they are not in
    # the index; they can still be dominated by a stronger write below.
    priorityIndex = buildOverlapIndex
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
          value = recursiveUpdateMany
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
  # withPaths: [{ module; paths; ... }] in resolution order.
  findSingleConflicts = withPaths: let
    numbered = lib.imap0 (pos: c: {inherit pos c;}) withPaths;
    index = buildOverlapIndex
      (lib.concatMap
        (n: map (p: {path = p; module = n.c.module; rank = n.pos;}) n.c.paths)
        numbered);
    conflictFor = n: let
      found =
        lib.foldl'
        (acc: hit:
          if hit == null then acc
          else if acc == null || hit.rank < acc.rank then hit
          else acc)
        null
        (map (p: overlapMinOther index p n.c.module) n.c.paths);
    in
      if found == null || found.rank >= n.pos
      then []
      else [{ writer = n.c; other = builtins.elemAt withPaths found.rank; }];
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
      entries = lib.concatMap (v: lib.mapAttrsToList (k: x: {name = k; value = x;}) v) values;
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
            (p: {key = pathKey p; writer = {module = c.module; source = c.source or null; path = p;};})
            (collectPathsIn "configName '${configName}' (module '${c.module}')" [] c.value))
          sorted));
  in
    lib.filterAttrs (_: writers: lib.length (lib.unique (map (w: w.module) writers)) > 1) pathWriters;

  resolveNamespaced = configName: contributions: let
    sorted = lib.sort (a: b: a.index < b.index) contributions;
    conflicts = findNamespacedConflicts configName sorted;
    conflictText = lib.concatStringsSep "\n" (lib.mapAttrsToList (_: writers: let p = builtins.head writers; in ''
      path: ${formatPath p.path}
      writers:
        ${lib.concatStringsSep "\n  " (map (w: "- " + formatWriter w) writers)}'') conflicts);
  in
    if conflicts != {}
    then throw ''
      mulix: ownership conflict
      configName: ${configName}
      strategy: namespaced
      ${conflictText}
      (There are multiple writers on the same leaf.
       Namespaced strategies do not allow overwriting on a leaf by a later writer.)
    ''
    else
      mergeNamespacedMany configName [] (map (c: c.value) sorted);

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
    boundBase = if hasBoundBase then baseValues.${configName} else {};

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
in {
  inherit validateRegistry validateRegistryWithReserved validateRegistryEntry mergeStrategies;
  inherit collectPaths pathsOverlap;
  # Exported for the differential tests (tests/property).
  inherit findSingleConflicts applyNestedLeafOverrides collectLeafWrites collectPathsIn pathKey recursiveUpdateMany mergeNamespacedMany findNamespacedConflicts;
  inherit resolveSingle resolveNamespaced resolveOrdered;
  inherit resolveAll;
}
