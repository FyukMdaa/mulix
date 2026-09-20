{lib}: let
  errors = import ./errors.nix {inherit lib;};
  inherit (builtins) elem;

  reservedNamespaces = ["is" "type" "feat" "role"];

  # ---- host field classification --------------------------------------
  #
  #   single value (must agree across fragments) : system type
  #   identity                                    : name
  #   merged lists                                : feat role
  #   generated (user input is an error)          : is
  #   configuration (module-system merge)        : os home darwin shared
  #
  # `features` / `roles` are accepted as aliases of `feat` / `role`.
  singleFields = ["system" "type"];
  listFields = ["feat" "role"];
  listAliases = {
    feat = ["feat" "features"];
    role = ["role" "roles"];
  };
  configFields = ["os" "home" "darwin" "shared"];
  allowedHostFields =
    ["name"] ++ singleFields ++ listFields ++ ["features" "roles"] ++ configFields;

  # "x86_64-linux" -> { arch = "x86_64"; os = "linux"; }
  parseSystem = system: let
    parts = lib.splitString "-" system;
  in
    if builtins.length parts < 2
    then {
      arch = system;
      os = null;
    }
    else {
      arch = builtins.head parts;
      os = builtins.concatStringsSep "-" (builtins.tail parts);
    };

  # Flags derived from `system` alone: linux / darwin / <arch>.
  systemFlags = host: let
    sys = parseSystem (host.system or "");
  in
    (lib.optional (sys.os == "linux") "linux")
    ++ (lib.optional (sys.os == "darwin") "darwin")
    ++ (lib.optional (sys.arch != "") sys.arch);

  # ---- merged-host accessors -------------------------------------------
  typeNamesOf = host:
    if (host.type or null) != null
    then [host.type]
    else [];

  # `host.is` is GENERATED: system flags plus the host's type / roles / features.
  generatedIsNames = host:
    systemFlags host ++ typeNamesOf host ++ (host.roles or []) ++ (host.features or []);

  unionAcross = extract: hosts:
    lib.unique (lib.concatMap extract (builtins.attrValues hosts));

  checkReserved = context: kind: names: let
    bad = builtins.filter (n: elem n reservedNamespaces) names;
  in
    if bad != []
    then
      throw ''
        mulix: reserved namespace collision
        host: ${context}
        ${kind} name(s) [${builtins.concatStringsSep ", " bad}] collide
        with reserved host condition namespaces: is/type/feat/role
      ''
    else names;

  # Names that would be indistinguishable from a system flag in the generated
  # `host.is` namespace.
  checkSystemFlagCollision = context: kind: fleetFlags: names: let
    bad = builtins.filter (n: elem n fleetFlags) names;
  in
    if bad != []
    then
      throw ''
        mulix: reserved namespace collision
        host: ${context}
        ${kind} name(s) [${builtins.concatStringsSep ", " bad}] collide with
        system-derived host.is flags (linux / darwin / architecture names)
      ''
    else names;

  mkBoolUniverse = universe: owned:
    builtins.listToAttrs (map
      (n: {
        name = n;
        value = elem n owned;
      })
      universe);

  # ---- source labels ---------------------------------------------------
  fragmentLabel = f:
    if (f.label or null) != null
    then f.label
    else if (f.source or null) != null
    then f.source
    else "(in-memory definition)";

  quote = v: builtins.toJSON v;
in rec {
  inherit reservedNamespaces allowedHostFields singleFields listFields configFields;

  checkStringList = context: field: value:
    if !builtins.isList value
    then
      throw ''
        mulix: invalid host shape
        host: ${context}
        field '${field}' must be a list of strings, got: ${builtins.typeOf value}
      ''
    else let
      bad = builtins.filter (x: !(builtins.isString x)) value;
    in
      if bad != []
      then
        throw ''
          mulix: invalid host shape
          host: ${context}
          field '${field}' must contain only strings
        ''
      else true;

  checkUniqueStringList = context: field: value:
    builtins.seq (checkStringList context field value)
    (let
      duplicates = lib.unique (builtins.filter (x: lib.count (y: y == x) value > 1) value);
    in
      if duplicates != []
      then
        throw ''
          mulix: invalid conditionNames input
          field '${field}' contains duplicate condition name(s):
          ${builtins.concatStringsSep ", " duplicates}
          Each condition namespace must declare each name at most once.
        ''
      else true);

  validateConditionNames = conditionNames:
    if !builtins.isAttrs conditionNames
    then
      throw ''
        mulix: invalid conditionNames input
        expected an attrset with type/feat/role string lists, got: ${builtins.typeOf conditionNames}
      ''
    else if (conditionNames.is or []) != []
    then
      throw ''
        mulix: conditionNames.is is reserved for generated state
        host.is is generated from the host's system, type, role and feat;
        it is not declared by hand.
        help: declare the names under conditionNames.type / conditionNames.feat / conditionNames.role
      ''
    else
      builtins.seq (checkUniqueStringList "conditionNames" "type" (conditionNames.type or []))
      (builtins.seq (checkUniqueStringList "conditionNames" "feat" (conditionNames.feat or []))
        (checkUniqueStringList "conditionNames" "role" (conditionNames.role or [])));

  # ---- one host fragment (what `mulib.host { ... }` returns) -----------
  validateHost = context: host:
    if !builtins.isAttrs host
    then
      throw ''
        mulix: invalid host shape
        host: ${context}
        expected a mulib.host descriptor, got: ${builtins.typeOf host}
        Wrap the host definition in 'mulib.host { ... }'.
      ''
    else if (host._mulixKind or null) != "host"
    then
      throw ''
        mulix: invalid host shape
        host: ${context}
        expected a mulib.host descriptor.
        Wrap the host definition in 'mulib.host { ... }' instead of using a raw attrset.
      ''
    else let
      fields = builtins.attrNames (builtins.removeAttrs host ["_mulixKind"]);

      isCheck =
        if host ? is
        then
          throw ''
            mulix: host.is is reserved for generated state
            host: ${context}
            'is' is generated from the host's system, type, role and feat and cannot be
            defined by hand.
            help: put the information in 'type', 'role' or 'feat' instead.
          ''
        else true;

      unknown = builtins.filter (f: !(elem f allowedHostFields)) (builtins.filter (f: f != "is") fields);
      fieldCheck =
        if unknown != []
        then
          throw ''
            mulix: invalid host definition
            host: ${context}
            unknown field: ${builtins.concatStringsSep ", " (map (f: "'${f}'") unknown)}
            allowed fields: ${builtins.concatStringsSep ", " (["name"] ++ singleFields ++ listFields ++ configFields)}
            ${errors.didYouMean (builtins.head unknown) allowedHostFields}
          ''
        else true;

      nameCheck =
        if !(host ? name)
        then
          throw ''
            mulix: invalid host shape
            host: ${context}
            required field 'name' is missing
          ''
        else if !(builtins.isString host.name)
        then
          throw ''
            mulix: invalid host shape
            host: ${context}
            field 'name' must be a string, got: ${builtins.typeOf host.name}
          ''
        else if host.name == ""
        then
          throw ''
            mulix: invalid host shape
            host: ${context}
            field 'name' must not be empty
          ''
        else true;
      systemCheck =
        if host ? system && !(builtins.isString host.system)
        then
          throw ''
            mulix: invalid host shape
            host: ${context}
            field 'system' must be a string, got: ${builtins.typeOf host.system}
          ''
        else true;
      typeCheck =
        if host ? type && host.type != null && !(builtins.isString host.type)
        then
          throw ''
            mulix: invalid host shape
            host: ${context}
            field 'type' must be a string or null, got: ${builtins.typeOf host.type}
          ''
        else true;
      listCheck =
        builtins.foldl'
        (ok: field:
          builtins.seq ok
          (builtins.foldl'
            (ok2: alias:
              if host ? ${alias}
              then builtins.seq ok2 (checkStringList context alias host.${alias})
              else ok2)
            true
            listAliases.${field}))
        true
        listFields;
      configCheck =
        builtins.foldl'
        (ok: field:
          builtins.seq ok
          (if host ? ${field} && !(builtins.isAttrs host.${field} || builtins.isFunction host.${field})
          then
            throw ''
              mulix: invalid host shape
              host: ${context}
              field '${field}' must be a module (attrset or function), got: ${builtins.typeOf host.${field}}
            ''
          else true))
        true
        configFields;
    in
      builtins.seq isCheck
      (builtins.seq fieldCheck
        (builtins.seq nameCheck
          (builtins.seq systemCheck
            (builtins.seq typeCheck
              (builtins.seq listCheck configCheck)))));

  # The public constructor.  The marker is deliberately added here so raw
  # attrsets cannot enter the host registry by accident.
  mkHost = hostConfig:
    if !builtins.isAttrs hostConfig
    then throw "mulix: mulib.host expects a host attrset, got ${builtins.typeOf hostConfig}"
    else let
      marked = hostConfig // {_mulixKind = "host";};
    in
      builtins.seq (validateHost (hostConfig.name or "<unnamed>") marked) marked;

  # ---- fragments -------------------------------------------------------
  #
  # A fragment is { def; source; label; dirName; } where `def` is a validated
  # host descriptor.  `label` is the human-readable source shown in
  # diagnostics ("hosts/alpha/default.nix").

  # hostDefs: { <name> = descriptor | [ descriptor ... ]; }
  fragmentsFromHostDefs = hostDefs:
    if !builtins.isAttrs hostDefs
    then
      throw ''
        mulix: invalid hosts input
        expected an attrset mapping host names to host definitions, got: ${builtins.typeOf hostDefs}
        (input validation)
      ''
    else
      lib.concatMap
      (key: let
        value = hostDefs.${key};
        defs =
          if builtins.isList value
          then value
          else [value];
        one = i: def: let
          label =
            if builtins.isList value
            then "hostDefs.${key}[${toString i}]"
            else "hostDefs.${key}";
          identityCheck =
            if def.name != key
            then
              throw ''
                mulix: host identity mismatch
                host map key: ${key}
                host.name: ${def.name}
                source: ${label}
                The host definition name must equal its map key.
              ''
            else true;
        in
          builtins.seq (validateHost label def)
          (builtins.seq identityCheck {
            inherit def label;
            source = null;
            dirName = null;
          });
      in
        lib.imap0 one defs)
      (builtins.attrNames hostDefs);

  # ---- merging ---------------------------------------------------------
  conflictError = field: hostName: contributions: let
    distinct = lib.unique (map (c: c.value) contributions);
    block = value: let
      sources = map (c: c.source) (builtins.filter (c: c.value == value) contributions);
    in
      ''
        value: ${quote value}
      ''
      + lib.concatMapStrings (s: "source: ${s}\n") sources;
  in
    throw ''
      mulix: host ${field} conflict
      host: ${hostName}

      ${lib.concatStringsSep "\n" (map block distinct)}
      help: '${field}' is a single-value host field: every fragment of the host that sets it must agree.
    '';

  singleValue = hostName: field: fragments: let
    contributions =
      lib.concatMap
      (f:
        lib.optional ((f.def.${field} or null) != null) {
          value = f.def.${field};
          source = fragmentLabel f;
        })
      fragments;
    distinct = lib.unique (map (c: c.value) contributions);
  in
    if builtins.length distinct > 1
    then conflictError field hostName contributions
    else {
      value =
        if contributions == []
        then null
        else builtins.head distinct;
      sources = contributions;
    };

  listContributions = field: fragments:
    lib.concatMap
    (f:
      map
      (value: {
        inherit value;
        source = fragmentLabel f;
      })
      (lib.concatMap (alias: f.def.${alias} or []) listAliases.${field}))
    fragments;

  # Merge every fragment of ONE host (`fragments` already share a name).
  mergeFragments = hostName: fragments: let
    system = singleValue hostName "system" fragments;
    type = singleValue hostName "type" fragments;
    featC = listContributions "feat" fragments;
    roleC = listContributions "role" fragments;
    configOf = target:
      lib.concatMap
      (f:
        lib.optional (f.def ? ${target} && f.def.${target} != null) {
          frag = f.def.${target};
          source = fragmentLabel f;
        })
      fragments;
  in {
    name = hostName;
    system =
      if system.value == null
      then null
      else system.value;
    type = type.value;
    # Order of first appearance in fragment order (deterministic: see the
    # collector's ordering rule), duplicates dropped.
    features = lib.unique (map (c: c.value) featC);
    roles = lib.unique (map (c: c.value) roleC);
    config = lib.genAttrs configFields configOf;
    sources = {
      system = system.sources;
      type = type.sources;
      feat = featC;
      role = roleC;
      fragments =
        map
        (f: {
          source = fragmentLabel f;
          dirName = f.dirName or null;
          fields = builtins.attrNames (builtins.removeAttrs f.def ["_mulixKind" "name"]);
        })
        fragments;
    };
  };

  # All fragments -> { <name> = merged host; }.
  composeFragments = fragments:
    builtins.mapAttrs
    mergeFragments
    (builtins.groupBy (f: f.def.name) fragments);

  composeHostDefs = hostDefs: composeFragments (fragmentsFromHostDefs hostDefs);

  # ---- validation against declared condition names ----------------------
  validateHostAgainst = conditionNames: context: host: let
    declared = {
      type = conditionNames.type or [];
      feat = conditionNames.feat or [];
      role = conditionNames.role or [];
    };
    check = kind: values: let
      bad = builtins.filter (x: !(elem x declared.${kind})) values;
    in
      if bad != []
      then
        throw ''
          mulix: undeclared ${kind} condition(s) in host '${context}':
          ${builtins.concatStringsSep ", " bad}
          Add these names to conditionNames.${kind} before using them.
        ''
      else true;
  in
    builtins.seq (check "type" (typeNamesOf host))
    (builtins.seq (check "feat" (host.features or []))
      (check "role" (host.roles or [])));

  # composed: { name = merged host; }
  validateComposedHosts = composed: conditionNames:
    builtins.seq (validateConditionNames conditionNames)
    (builtins.foldl'
      (ok: key:
        builtins.seq composed.${key}.system
        (builtins.seq composed.${key}.type
          (builtins.seq (validateHostAgainst conditionNames key composed.${key}) ok)))
      true
      (builtins.attrNames composed));

  # API kept from the single-fragment days: hostDefs -> true | throw.
  validateHosts = hosts: conditionNames:
    validateComposedHosts (composeHostDefs hosts) conditionNames;

  /*
  mkComposedView:
    composed      = { name = merged host; } (see composeFragments)
    conditionNames
    hostName      = the host under evaluation

  Returns { is; type; feat; role; } boolean views.  `is` is generated:
  system flags (linux / darwin / arch) plus the host's own type / role / feat
  names, so type / role / feat stay the single source of truth.
  */
  mkComposedView = {
    composed,
    conditionNames,
    hostName,
  }: let
    _check = validateComposedHosts composed conditionNames;
    host =
      composed.${hostName}
      or (throw ''
        mulix: unknown host '${hostName}'
        known hosts: ${builtins.concatStringsSep ", " (builtins.attrNames composed)}
      '');

    fleetSystemFlags = unionAcross systemFlags composed;
    typeUniverse = conditionNames.type or [];
    featUniverse = conditionNames.feat or [];
    roleUniverse = conditionNames.role or [];
    isUniverse =
      lib.unique (["linux" "darwin"] ++ fleetSystemFlags ++ typeUniverse ++ roleUniverse ++ featUniverse);

    ownedType = typeNamesOf host;
    ownedFeat = host.features or [];
    ownedRole = host.roles or [];

    reservedCheck =
      builtins.seq (checkReserved hostName "feature" ownedFeat)
      (builtins.seq (checkReserved hostName "role" ownedRole)
        (builtins.seq (checkReserved hostName "type" ownedType)
          (builtins.seq (checkSystemFlagCollision hostName "feature" (["linux" "darwin"] ++ fleetSystemFlags) ownedFeat)
            (builtins.seq (checkSystemFlagCollision hostName "role" (["linux" "darwin"] ++ fleetSystemFlags) ownedRole)
              (checkSystemFlagCollision hostName "type" (["linux" "darwin"] ++ fleetSystemFlags) ownedType)))));

    view = {
      is = mkBoolUniverse isUniverse (generatedIsNames host);
      type = mkBoolUniverse typeUniverse ownedType;
      feat = mkBoolUniverse featUniverse ownedFeat;
      role = mkBoolUniverse roleUniverse ownedRole;
    };
  in
    builtins.seq _check (builtins.seq reservedCheck view);

  # Convenience for callers that only have hostDefs.
  mkHostsView = {
    hosts,
    conditionNames,
    hostName,
  }:
    mkComposedView {
      composed = composeHostDefs hosts;
      inherit conditionNames hostName;
    };

  # ---- diagnostics text ------------------------------------------------
  # Where every piece of a composed host came from.
  formatSources = host: let
    line = c: "      ${quote c.value}  <-  ${c.source}";
    section = title: cs:
      if cs == []
      then []
      else ["    ${title}:"] ++ map line cs;
  in
    lib.concatStringsSep "\n"
    ([
        "  ${host.name}"
        "    fragments:"
      ]
      ++ map (f: "      ${f.source}") host.sources.fragments
      ++ section "system" host.sources.system
      ++ section "type" host.sources.type
      ++ section "feat" host.sources.feat
      ++ section "role" host.sources.role);

  # Edges (fragment file --field--> host) for graphLib.toMermaid / toDot.
  sourceEdges = composed:
    lib.concatMap
    (name: let
      host = composed.${name};
      fieldEdges = field:
        map
        (c: {
          from = c.source;
          to = host.name;
          via = "${field}:${toString c.value}";
          kind = "host-source";
        })
        host.sources.${field};
      fragmentEdges =
        map
        (f: {
          from = f.source;
          to = host.name;
          via = "fragment";
          kind = "host-source";
        })
        host.sources.fragments;
    in
      fragmentEdges ++ lib.concatMap fieldEdges ["system" "type" "feat" "role"])
    (builtins.attrNames composed);
}
