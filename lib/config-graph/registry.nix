# Registry validation for the configName graph.
#
# This file owns the parts of `lib/config-graph.nix` that validate the
# user-supplied `configNames` registry: type / merge-strategy / binding
# / default checks, plus the `validateRegistry*` entry points.
#
# Self-contained: depends only on `lib` (and `lib.types` / `lib.modules`).
# Split out so that future changes to validation rules live in one place
# rather than being scattered across the 864-line original file.
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
    else let
      merged =
        lib.modules.mergeDefinitions
        ["mulix" configName fieldName]
        type
        [
          {
            file = "<mulix ${configName}.${fieldName}>";
            inherit value;
          }
        ];
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
        else
          entry.merge or (throw ''
            mulix: invalid configName registry entry '${configName}'
            missing required field: merge
          '');
      ownership = entry.ownership or "path";
      normalized =
        if isModulesBinding
        then
          entry
          // {
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
      (
        if !(normalized ? type)
        then
          throw ''
            mulix: invalid configName registry entry '${configName}'
            missing required field: type
          ''
        else if !hasTypeCheck
        then
          throw ''
            mulix: invalid configName registry entry '${configName}'
            field 'type' is not a Nix option type with a check function
          ''
        else if !(elem strategy mergeStrategies)
        then
          throw ''
            mulix: invalid configName registry entry '${configName}'
            invalid merge strategy '${strategy}',
            expected one of: ${builtins.concatStringsSep ", " mergeStrategies}
          ''
        else if ownership != "path"
        then
          throw ''
            mulix: invalid configName registry entry '${configName}'
            invalid ownership '${ownership}', expected: path
          ''
        else if strategy == "ordered" && (normalized ? default) && !(isList normalized.default)
        then
          throw ''
            mulix: invalid configName registry entry '${configName}'
            merge strategy 'ordered' requires default to be a list
          ''
        else
          builtins.seq orderedTypeCheck
          (builtins.seq defaultCheck
            (normalized // {inherit ownership;}))
      );

  # reservedNames is intentionally opt-in here: the graph library can validate
  # a registry independently, while mkMulix supplies the actual public
  # function-argument namespace and turns collisions into construction-time
  # errors.
  validateRegistryWithReserved = registry: {reservedNames ? []}: let
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
    else lib.mapAttrs validateRegistryEntry registry;

  validateRegistry = registry: validateRegistryWithReserved registry {};

  # ---- path collection (for single-strategy ownership checking) ----


in rec {
  inherit
    mergeStrategies
    validateType
    validateRegistryEntry
    validateRegistryWithReserved
    validateRegistry
    ;
}
