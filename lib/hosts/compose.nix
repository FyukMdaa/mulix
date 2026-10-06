# Fragment collection and merging.
#
# This file owns the parts of `lib/hosts.nix` that turn multiple host
# fragments into one composed host:
#   - `fragmentsFromHostDefs` - flatten the `hostDefs` attrset
#   - `conflictError`, `singleValue`, `listContributions`
#   - `mergeFragments`        - merge fragments sharing a `name`
#   - `composeFragments`      - group + merge all fragments
#   - `composeHostDefs`       - convenience: hostDefs -> composed hosts
#
# Dependency injection: needs `validateHost` from `./validate.nix` and
# the constants from `./constants.nix`. Inherits the names it needs so
# the function bodies are unchanged.
{lib}: let
  constants = import ./constants.nix {inherit lib;};
  inherit (constants)
    fragmentLabel
    quote
    listAliases
    configFields
    ;
  validate = import ./validate.nix {inherit lib;};
  inherit (validate) validateHost;
in rec {
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
          checked = builtins.seq (validateHost label def) def;
          identityCheck =
            if checked.name != key
            then
              throw ''
                mulix: host identity mismatch
                host map key: ${key}
                host.name: ${checked.name}
                source: ${label}
                The host definition name must equal its map key.
              ''
            else true;
        in
          builtins.seq identityCheck {
            def = checked;
            inherit label;
            source = null;
            dirName = null;
          };
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
        lib.optional (builtins.hasAttr target f.def && f.def.${target} != null) {
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

}
