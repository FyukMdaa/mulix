/* mulix option specification helpers. */
{lib}: let
  mk = type: default: lib.mkOption {inherit type default;};
  mkOptionalDefault = type: default:
    if default == null
    then lib.mkOption {inherit type;}
    else mk type default;
in {
  type = {
    bool = lib.types.bool;
    int = lib.types.int;
    float = lib.types.float;
    str = lib.types.str;
    lines = lib.types.lines;
    path = lib.types.path;
    package = lib.types.package;
    attrs = lib.types.attrs;
    enum = values: lib.types.enum values;
    oneOf = values: lib.types.oneOf values;
    attrsOf = elemType: lib.types.attrsOf elemType;
    listOf = elemType: lib.types.listOf elemType;
    nullOr = elemType: lib.types.nullOr elemType;
    either = a: b: lib.types.either a b;
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
  attrs = value: mkOptionalDefault lib.types.attrs value;
  path = value: mkOptionalDefault lib.types.path value;
  package = value: mkOptionalDefault lib.types.package value;
  listOf = elemType: value: mkOptionalDefault (lib.types.listOf elemType) value;
  # `null` is the public spelling for "no default".  `nullOr` is the one
  # intentional exception: its `null` argument means literal default = null.
  nullOr = elemType: value: mk (lib.types.nullOr elemType) value;

  str = value: mkOptionalDefault lib.types.str value;
  int = value: mkOptionalDefault lib.types.int value;
  float = value: mkOptionalDefault lib.types.float value;
  lines = value: mkOptionalDefault lib.types.lines value;
  enum = values: default: mkOptionalDefault (lib.types.enum values) default;
  oneOf = values: default: mkOptionalDefault (lib.types.oneOf values) default;
  attrsOf = elemType: default: mkOptionalDefault (lib.types.attrsOf elemType) default;
  either = leftType: rightType: default: mkOptionalDefault (lib.types.either leftType rightType) default;

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
