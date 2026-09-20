{lib}: let
  targets = ["os" "home" "darwin"];
  isEmptyStatic = frag: !(builtins.isFunction frag) && frag == {};
  optOf = moduleName: config: config.mulix.modules.${moduleName};
  enableOf = moduleName: config: (optOf moduleName config).enable;

  defaultEnableOption = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether this mulix module is enabled";
  };

  conditionValue = context: value:
    if builtins.isBool value then value
    else if builtins.isList value
    then
      if builtins.any builtins.isList value
      then builtins.all
        (v: if builtins.isList v
            then builtins.any (conditionValue context) v
            else conditionValue context v)
        value
      else builtins.all (conditionValue context) value
    else throw ''
      mulix: invalid enable condition in ${context}
      expected a bool or condition list, got: ${builtins.typeOf value}
      condition lists use top-level AND and nested lists as OR groups
    '';

  normalizeEnableSpec = context: value:
    if builtins.isList value
    then if value == []
      then throw ''
        mulix: invalid enable condition in ${context}
        an empty condition list is ambiguous and is not allowed;
        provide at least one condition
      ''
      else lib.mkOption {
        type = lib.types.bool;
        default = conditionValue context value;
        description = "Whether this mulix module is enabled";
      }
    else value;

  ensureEnableOption = options:
    if options ? enable
    then options // {enable = normalizeEnableSpec "options.enable" options.enable;}
    else options // {enable = defaultEnableOption;};

  # mkMulix attaches the original definition as an internal field.
  # Standalone normalized records do not, so accept either representation.
  evalDefinition = mod: specialArgs:
    if mod ? definition
    then if builtins.isFunction mod.definition
      then mod.definition specialArgs
      else mod.definition
    else mod;

  optionsFragment = {mod, specialArgsBase, configGraphForConfig}:
    {config, lib, ...} @ nixArgs: let
      graph = configGraphForConfig config;
      evalArgs =
        specialArgsBase
        // nixArgs
        // graph
        // {
          opt = optOf mod.name config;
          # `myconfig` is `config.mulix.modules` itself (no separate storage).
          myconfig = config.mulix.modules;
        };
      evaluated = evalDefinition mod evalArgs;
      raw = evaluated.options or {};
      evaluatedOptions = if builtins.isFunction raw then raw evalArgs else raw;

      normalizedEnable =
        if evaluatedOptions ? enable
        then normalizeEnableSpec "options.enable" evaluatedOptions.enable
        else defaultEnableOption;
    in
      builtins.seq normalizedEnable {
        options.mulix.modules.${mod.name} =
          evaluatedOptions // { enable = normalizedEnable; };
      };

  mkAlwaysEntry = {mod, target, specialArgsBase, configGraphForConfig}:
    {config, lib, ...} @ nixArgs: let
      common =
        specialArgsBase
        // nixArgs
        // configGraphForConfig config
        // {myconfig = config.mulix.modules;};
      evaluated = evalDefinition mod common;
      frag = evaluated.always.${target} or {};
    in
      if isEmptyStatic frag then {}
      else if builtins.isFunction frag
      then frag (common // {opt = optOf mod.name config;})
      else frag;

  mkConditionalEntry = {mod, target, specialArgsBase, configGraphForConfig}:
    {config, lib, ...} @ nixArgs: let
      common =
        specialArgsBase
        // nixArgs
        // configGraphForConfig config
        // {myconfig = config.mulix.modules;};
      evaluated = evalDefinition mod common;
      frag = evaluated.${target} or {};
    in
      if isEmptyStatic frag then {}
      else if builtins.isFunction frag
      then let
        result = frag (common // {opt = optOf mod.name config;});
      in {config = lib.mkIf (enableOf mod.name config) result;}
      else {config = lib.mkIf (enableOf mod.name config) frag;};

  mkModuleFragments = {mod, target, specialArgsBase, configGraphForConfig}:
    [
      (mkAlwaysEntry {inherit mod target specialArgsBase configGraphForConfig;})
      (mkConditionalEntry {inherit mod target specialArgsBase configGraphForConfig;})
    ];

  checkTarget = context: target:
    if !(builtins.elem target targets)
    then throw ''
      mulix: invalid target '${target}'
      in module: ${context}
      allowed targets: ${builtins.concatStringsSep ", " targets}
    ''
    else target;

  /*
  Host configuration fragments (`os` / `home` / `darwin` / `shared` of the
  merged host) as ordinary module-system modules, so the Nix module system
  does the merging.  `shared` applies to every target and comes first.

  A function fragment is wrapped so that
    * arguments the module system can supply (`pkgs`, `lib`, `config`,
      `modulesPath`, `_module.args` entries, ...) are supplied by it, and
    * mulix's own arguments (`host`, `mulib`, `myconfig`, configNames,
      specialArgs) are injected.
  `supplied` lists the names mulix injects; every other requested name is left
  to the module system.
  */
  mkHostFragmentModule = {frag, supplied, specialArgsBase, configGraphForConfig}:
    if !builtins.isFunction frag
    then frag
    else let
      requested = builtins.functionArgs frag;
      suppliedSet = lib.genAttrs supplied (_: true);
    in
      lib.setFunctionArgs
      (args: let
        config = args.config;
        # Only the names mulix owns are injected; `pkgs`, `lib`, `modulesPath`,
        # ... keep coming from the module system.
        injected =
          builtins.intersectAttrs suppliedSet
          (specialArgsBase
            // configGraphForConfig config
            // {myconfig = config.mulix.modules;});
      in
        frag (builtins.intersectAttrs requested (args // injected)))
      ({config = false; lib = false;} // builtins.removeAttrs requested supplied);

  mkHostModules = {hostConfig, target, supplied, specialArgsBase, configGraphForConfig}:
    map
    (f: mkHostFragmentModule {inherit (f) frag; inherit supplied specialArgsBase configGraphForConfig;})
    (hostConfig.config.shared ++ hostConfig.config.${target});

  mkTargetModuleList = {
    modules,
    target,
    specialArgsBase,
    configGraphForConfig,
    hostConfig ? null,
    supplied ? [],
  }:
    let
      _targetCheck = checkTarget "mkTargetModuleList" target;
      optionsFrags = map (mod: optionsFragment {inherit mod specialArgsBase configGraphForConfig;}) modules;
      bodyFrags = lib.concatMap
        (mod: mkModuleFragments {inherit mod target specialArgsBase configGraphForConfig;}) modules;
      hostFrags =
        if hostConfig == null
        then []
        else mkHostModules {inherit hostConfig target supplied specialArgsBase configGraphForConfig;};
    in builtins.seq _targetCheck (optionsFrags ++ bodyFrags ++ hostFrags);
in {
  inherit targets checkTarget optionsFragment mkAlwaysEntry mkConditionalEntry
    mkModuleFragments mkTargetModuleList mkHostModules mkHostFragmentModule
    conditionValue normalizeEnableSpec optOf;
}
