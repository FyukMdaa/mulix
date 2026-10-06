# Host and conditionNames shape validation.
#
# This file owns the parts of `lib/hosts.nix` that validate user-supplied
# descriptors:
#   - `checkStringList` / `checkUniqueStringList`  - list field shape checks
#   - `validateConditionNames`                     - the conditionNames registry
#   - `validateHost`                                - per-fragment host shape check
#   - `mkHost`                                      - the `mulib.host` constructor
#
# Dependency injection: imports the constants + small helpers from
# `./constants.nix` and `inherit`s the names it needs so the function
# bodies are unchanged from the original monolithic file.
{lib}: let
  inherit (builtins) elem;
  constants = import ./constants.nix {inherit lib;};
  inherit
    (constants)
    errors
    singleFields
    listFields
    listAliases
    configFields
    allowedHostFields
    checkSendShape
    ;
in rec {
  inherit allowedHostFields singleFields listFields configFields;
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
            allowed fields: ${builtins.concatStringsSep ", " (["name"] ++ singleFields ++ listFields ++ ["features" "roles" "send"] ++ configFields)}
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
              if builtins.hasAttr alias host
              then builtins.seq ok2 (checkStringList context alias host.${alias})
              else ok2)
            true
            listAliases.${field}))
        true
        listFields;
      sendCheck =
        checkSendShape "${context}.send" (errors.attrPos host "send") (host.send or {});
      sendForceCheck =
        if builtins.hasAttr "force" (host.send or {})
        then checkSendShape "${context}.send.force" (errors.attrPos (host.send or {}) "force") (host.send.force or {})
        else true;
      configCheck =
        builtins.foldl'
        (ok: field:
          builtins.seq ok
          (
            if builtins.hasAttr field host && !(builtins.isAttrs host.${field} || lib.isFunction host.${field})
            then
              throw ''
                mulix: invalid host shape
                host: ${context}
                field '${field}' must be a module (attrset or function), got: ${builtins.typeOf host.${field}}
              ''
            else true
          ))
        true
        configFields;
    in
      builtins.seq isCheck
      (builtins.seq fieldCheck
        (builtins.seq nameCheck
          (builtins.seq systemCheck
            (builtins.seq typeCheck
              (builtins.seq listCheck
                (builtins.seq sendCheck
                  (builtins.seq sendForceCheck configCheck)))))));

  # The public constructor.  The marker is deliberately added here so raw
  # attrsets cannot enter the host registry by accident.
  mkHost = hostConfig:
    if !builtins.isAttrs hostConfig
    then throw "mulix: mulib.host expects a host attrset, got ${builtins.typeOf hostConfig}"
    else let
      marked = hostConfig // {_mulixKind = "host";};
    in
      builtins.seq (validateHost (hostConfig.name or "<unnamed>") marked) marked;
}
