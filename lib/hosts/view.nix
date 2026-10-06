# Host condition view.
#
# This file owns the parts of `lib/hosts.nix` that turn a composed host
# into the boolean condition universe the modules see via `host`:
#   - `validateHostAgainst`     - host conditions vs declared names
#   - `validateComposedHosts`   - validate the whole fleet
#   - `validateHosts`           - convenience wrapper
#   - `mkComposedView`         - the boolean { is; type; feat; role; }
#   - `mkHostsView`            - convenience for hostDefs callers
#
# Dependency injection: needs `validateConditionNames` from
# `./validate.nix`, `composeHostDefs` from `./compose.nix`, and the
# system-flag helpers from `./constants.nix`.
{lib}: let
  inherit (builtins) elem;
  constants = import ./constants.nix {inherit lib;};
  inherit
    (constants)
    systemFlags
    typeNamesOf
    generatedIsNames
    unionAcross
    mkBoolUniverse
    ;
  validate = import ./validate.nix {inherit lib;};
  inherit (validate) validateConditionNames;
  compose = import ./compose.nix {inherit lib;};
  inherit (compose) composeHostDefs;
in rec {
  validateHostAgainst = conditionNames: context: host: let
    declared = {
      type = conditionNames.type or [];
      feat = conditionNames.feat or [];
      role = conditionNames.role or [];
    };
    check = kind: values: let
      allowed =
        if kind == "feat"
        then lib.unique (declared.feat ++ systemFlags host)
        else declared.${kind};
      bad = builtins.filter (x: !(elem x allowed)) values;
    in
      if bad != []
      then
        throw ''
          mulix: undeclared ${kind} condition(s) in host '${context}':
          ${builtins.concatStringsSep ", " bad}
          ${
            if kind == "feat"
            then "Add these names to conditionNames.feat before using them, unless the name is already a generated system flag."
            else "Add these names to conditionNames." + kind + " before using them."
          }
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
      composed.${
        hostName
      }
      or (throw ''
        mulix: unknown host '${hostName}'
        known hosts: ${builtins.concatStringsSep ", " (builtins.attrNames composed)}
      '');

    fleetSystemFlags = unionAcross systemFlags composed;
    typeUniverse = conditionNames.type or [];
    featUniverse = lib.unique ((conditionNames.feat or []) ++ (host.features or []));
    roleUniverse = conditionNames.role or [];
    isUniverse =
      lib.unique (["linux" "darwin"] ++ fleetSystemFlags ++ typeUniverse ++ roleUniverse ++ featUniverse);

    ownedType = typeNamesOf host;
    ownedFeat = host.features or [];
    ownedRole = host.roles or [];

    # There is intentionally no cross-namespace name collision check here.
    # `type`, `feat`, and `role` are independent user-controlled namespaces;
    # `is` is the generated flattened view.
    reservedCheck = true;

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
}
