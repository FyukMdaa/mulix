/* mulix option specification helpers. */
{lib}: let
  mk = type: default: lib.mkOption {inherit type default;};
in {
  type = {
    bool = lib.types.bool;
    int = lib.types.int;
    str = lib.types.str;
    attrs = lib.types.attrs;
    path = lib.types.path;
    package = lib.types.package;
    enum = values: lib.types.enum values;
    listOf = elemType: lib.types.listOf elemType;
    nullOr = elemType: lib.types.nullOr elemType;
  };

  bool = {
    true = mk lib.types.bool true;
    false = mk lib.types.bool false;
  };
  # ---- less frequent shorthands -----------------------------------------
  # Only the ones that are used constantly get a shorthand; everything else
  # stays a plain `mkOption { type = ...; }`.
  #
  #   mulib.attrs { }                          attrs
  #   mulib.path ./foo                         path
  #   mulib.package pkgs.git                   package
  #   mulib.listOf mulib.type.str [ "a" ]      listOf <type>
  #   mulib.nullOr mulib.type.str null         nullOr <type>
  attrs = value: mk lib.types.attrs value;
  path = value: mk lib.types.path value;
  package = value: mk lib.types.package value;
  listOf = elemType: value: mk (lib.types.listOf elemType) value;
  nullOr = elemType: value: mk (lib.types.nullOr elemType) value;

  str = value: mk lib.types.str value;
  int = value: mk lib.types.int value;
  enum = values: default: mk (lib.types.enum values) default;

  # Select a result by the exact string value of `value`.  The `default`
  # branch is optional; without it, an unmatched value is an explicit error.
  select = value: cases:
    if !builtins.isString value
    then throw "mulix: mulib.select expects a string value, got ${builtins.typeOf value}"
    else if !builtins.isAttrs cases
    then throw "mulix: mulib.select expects an attrset of cases, got ${builtins.typeOf cases}"
    else let
      caseNames = builtins.attrNames cases;
    in
      if builtins.hasAttr value cases
      then cases.${value}
      else if builtins.hasAttr "default" cases
      then cases.default
      else
        throw ''
          mulix: mulib.select has no case for value '${value}'
          available cases: ${lib.concatStringsSep ", " (builtins.filter (x: x != "default") caseNames)}
        '';

}
