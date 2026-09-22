{lib}: let
  errors = import ./errors.nix {inherit lib;};
  allowedTargets = ["os" "home" "darwin"];
  allowedTopLevel = ["name" "options" "always" "os" "home" "darwin" "send"];
  allowedAlwaysTargets = ["os" "home" "darwin" "send"];

  checkUnknownKeys = context: allowed: attrs:
    if !builtins.isAttrs attrs
    then
      throw ''
        mulix: invalid module shape
        in module: ${context}
        expected an attrset, got: ${builtins.typeOf attrs}
        (invalid module shape)
      ''
    else let
      unknown = builtins.filter (k: !(builtins.elem k allowed)) (builtins.attrNames attrs);
      firstUnknown =
        if unknown == []
        then null
        else builtins.head unknown;
      position =
        if firstUnknown == null
        then null
        else errors.attrPos attrs firstUnknown;
    in
      if unknown != []
      then
        errors.invalidField {
          module = context;
          field = firstUnknown;
          inherit allowed position;
          help = ["remove the field, or use one of the allowed fields above."];
        }
      else attrs;

  /*
  target fragment / send の値は WHNF レベルでのみ型検査する。
  (中身まで強制評価しない — laziness を壊さないため。)

  fragment (always.<target>, os, home, darwin):
    Nix module fragment として扱うため attrset または function
  send:
    configName -> contribution の attrset。`send.force` は強制 contribution の
    特殊名前空間として扱い、正規化後は `sendForce` に分離される。
  */
  checkFragmentValue = context: position: value:
    if builtins.isAttrs value || lib.isFunction value
    then value
    else
      throw ''
        mulix: invalid module definition
        location: ${context}${errors.formatLocation position}
        target fragment must be an attrset (or function) that is a
        valid Nix module fragment, got: ${builtins.typeOf value}
      '';

  checkSendShape = context: position: value:
    if builtins.isAttrs value
    then value
    else
      throw ''
        mulix: invalid module definition
        location: ${context}${errors.formatLocation position}
        'send' must be an attrset mapping configName -> contribution,
        got: ${builtins.typeOf value}
      '';
in rec {
  /*
  callModule:
    context   = module の識別情報 (エラーメッセージ用。index 等)
    callArgs  = function module に渡す引数一式
                (host, pkgs, lib, inputs, configName args ...)
    def       = module 定義 (attrset か function)

  attrset module はそのまま返す。function module は callArgs で
  呼び出す。

  呼び出し前に引数の欠落を検査し、mulix 固有の diagnostics を
  Nix の深い evaluation error より前に発生させる。Nix 原生の
  "called without required argument" エラーは builtins.tryEval で
  捕捉できないため、mulix が先に catch 可能な throw を出す。

  デフォルト値付きの引数 (`{ x ? 1 }: ...`) は省略可能として扱う
  (builtins.functionArgs の attrset 値: paramName -> hasDefault)。
  */
  callModule = context: callArgs: def:
    if lib.isFunction def
    then let
      argsSpec = lib.functionArgs def;
      missing =
        builtins.filter
        (arg:
          !(builtins.isAttrs callArgs && builtins.hasAttr arg callArgs)
          && !argsSpec.${arg})
        (builtins.attrNames argsSpec);
    in
      if missing != []
      then
        throw ''
          mulix: module function requests missing argument(s)
          in module source: ${context}
          missing: ${builtins.concatStringsSep ", " missing}
          These names are treated as configNames received via function
          argument or mulix built-ins. Declare configNames
          in the registry before use, or check the argument name.
        ''
      else def callArgs
    else def;

  # function module が要求する引数名 (dependency discovery)
  functionArgsOf = def:
    if lib.isFunction def
    then builtins.attrNames (lib.functionArgs def)
    else [];

  isFunctionModule = def: lib.isFunction def;

  /*
  normalizeModule:
    mod = callModule 済みの module 本体 (attrset)
    isFunction = 元の定義が function だったか (依存宣言可否に使う)
    declaredArgs = functionArgsOf の結果

  戻り値: 正規化された module record。

  このデフォルトは仕様に明記されていない実装判断である。
  */
  normalizeModule = {
    mod,
    isFunction,
    declaredArgs,
    source ? null,
  }: let
    descriptorCheck =
      if !builtins.isAttrs mod
      then
        throw ''
          mulix: invalid module shape
          expected a mulib.module descriptor, got: ${builtins.typeOf mod}
          Wrap the module definition in 'mulib.module { ... }'.
        ''
      else if (mod._mulixKind or null) != "module"
      then
        throw ''
          mulix: invalid module shape
          expected a mulib.module descriptor.
          Wrap the module definition in 'mulib.module { ... }' instead of using a raw attrset.
        ''
      else true;
    cleanMod = builtins.removeAttrs mod ["_mulixKind"];
    context = cleanMod.name or "<unnamed>";
    sourceSuffix =
      if source == null
      then ""
      else " [source: ${source}]";
    contextWithSource = "${context}${sourceSuffix}";

    _nameCheck =
      if !(mod ? name)
      then
        errors.missingField {
          module = context;
          field = "name";
          position = errors.attrPos mod "name";
        }
      else if !(builtins.isString mod.name)
      then
        throw ''
          mulix: invalid module shape
          module 'name' must be a string, got: ${builtins.typeOf mod.name}
        ''
      else if mod.name == ""
      then
        throw ''
          mulix: invalid module definition
          module: ${context}${errors.formatLocation (errors.attrPos mod "name")}
          field 'name' must not be empty
        ''
      else true;

    _shapeCheck = checkUnknownKeys contextWithSource allowedTopLevel cleanMod;

    alwaysRaw = cleanMod.always or {};
    _alwaysShapeCheck = checkUnknownKeys "${contextWithSource}.always" allowedAlwaysTargets alwaysRaw;
    always =
      if builtins.isAttrs alwaysRaw
      then alwaysRaw
      else
        throw ''
          mulix: invalid module shape
          in module: ${contextWithSource}
          'always' must be an attrset with per-target fragments
          (${builtins.concatStringsSep ", " allowedAlwaysTargets}), got:
          ${builtins.typeOf alwaysRaw}
        '';

    # Each target is normalized independently so omitted targets become {}.
    # This is important because later dependency discovery accesses all three
    # target keys unconditionally.
    alwaysSendRaw = alwaysRaw.send or {};
    alwaysChecked = {
      os = checkFragmentValue "${contextWithSource}.always.os" (errors.attrPos alwaysRaw "os") (alwaysRaw.os or {});
      home = checkFragmentValue "${contextWithSource}.always.home" (errors.attrPos alwaysRaw "home") (alwaysRaw.home or {});
      darwin = checkFragmentValue "${contextWithSource}.always.darwin" (errors.attrPos alwaysRaw "darwin") (alwaysRaw.darwin or {});
      send = checkSendShape "${contextWithSource}.always.send" (errors.attrPos alwaysRaw "send") alwaysSendRaw;
    };

    osChecked = checkFragmentValue "${contextWithSource}.os" (errors.attrPos cleanMod "os") (cleanMod.os or {});
    homeChecked = checkFragmentValue "${contextWithSource}.home" (errors.attrPos cleanMod "home") (cleanMod.home or {});
    darwinChecked = checkFragmentValue "${contextWithSource}.darwin" (errors.attrPos cleanMod "darwin") (cleanMod.darwin or {});
    sendRaw = cleanMod.send or {};
    sendForceRaw =
      if builtins.isAttrs sendRaw
      then sendRaw.force or {}
      else {};
    _sendForceShapeCheck =
      if builtins.isAttrs sendRaw && builtins.hasAttr "force" sendRaw
      then checkSendShape "${contextWithSource}.send.force" (errors.attrPos sendRaw "force") sendForceRaw
      else true;
    sendChecked =
      checkSendShape "${contextWithSource}.send" (errors.attrPos cleanMod "send")
      (
        if builtins.isAttrs sendRaw
        then builtins.removeAttrs sendRaw ["force"]
        else sendRaw
      );

    /*
    shape 検査の発火保証。

    Nix では未参照の let binding は評価されないため、_shapeCheck /
    _alwaysShapeCheck は戻り値の構築に seq で紐付ける必要がある。
    参照するのは cleanMod の attrNames (WHNF) のみであり、循環評価の
    リスクはない。
    */
    optionsRaw = cleanMod.options or {};
    optionsChecked =
      if builtins.isAttrs optionsRaw || lib.isFunction optionsRaw
      then optionsRaw
      else
        throw ''
          mulix: invalid module shape
          in module: ${contextWithSource}.options
          'options' must be an attrset or function, got:
          ${builtins.typeOf optionsRaw}
        '';
    optionsDeclaredArgs = functionArgsOf optionsChecked;
    fragmentDeclaredArgs =
      (functionArgsOf osChecked)
      ++ (functionArgsOf homeChecked)
      ++ (functionArgsOf darwinChecked)
      ++ (functionArgsOf alwaysChecked.os)
      ++ (functionArgsOf alwaysChecked.home)
      ++ (functionArgsOf alwaysChecked.darwin);
    sendDeclaredArgs =
      (lib.concatMap functionArgsOf (builtins.attrValues sendChecked))
      ++ (lib.concatMap functionArgsOf (builtins.attrValues sendForceRaw))
      ++ (lib.concatMap functionArgsOf (builtins.attrValues alwaysChecked.send));
    receiverArgs =
      lib.unique
      (declaredArgs ++ optionsDeclaredArgs ++ fragmentDeclaredArgs ++ sendDeclaredArgs);

    result = {
      inherit context isFunction declaredArgs receiverArgs;
      name = cleanMod.name;
      options = optionsChecked;
      optionsDeclaredArgs = optionsDeclaredArgs;
      always = {
        os = alwaysChecked.os or {};
        home = alwaysChecked.home or {};
        darwin = alwaysChecked.darwin or {};
        send = alwaysChecked.send or {};
      };
      os = osChecked;
      home = homeChecked;
      darwin = darwinChecked;
      send = sendChecked;
      sendForce = sendForceRaw;
    };
  in
    builtins.seq descriptorCheck
    (builtins.seq _nameCheck
      (builtins.seq _shapeCheck
        (builtins.seq _alwaysShapeCheck
          (builtins.seq _sendForceShapeCheck result))));

  inherit allowedTargets;
}
