{lib}: let
  targets = ["os" "home" "darwin"];
  isEmptyStatic = frag: !(lib.isFunction frag) && frag == {};
  optOf = moduleName: config: config.mulix.modules.${moduleName};
  enableOf = moduleName: config: (optOf moduleName config).enable;

  defaultEnableOption = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether this mulix module is enabled";
  };

  conditionValue = context: value:
    if builtins.isBool value
    then value
    else if builtins.isList value
    then
      if builtins.any builtins.isList value
      then
        builtins.all
        (v:
          if builtins.isList v
          then builtins.any (conditionValue context) v
          else conditionValue context v)
        value
      else builtins.all (conditionValue context) value
    else
      throw ''
        mulix: invalid enable condition in ${context}
        expected a bool or condition list, got: ${builtins.typeOf value}
        condition lists use top-level AND and nested lists as OR groups
      '';

  normalizeEnableSpec = context: value:
    if builtins.isList value
    then
      if value == []
      then
        throw ''
          mulix: invalid enable condition in ${context}
          an empty condition list is ambiguous and is not allowed;
          provide at least one condition
        ''
      else
        lib.mkOption {
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
    then
      if lib.isFunction mod.definition
      then mod.definition specialArgs
      else mod.definition
    else mod;

  /*
  The `pkgs` a module fragment sees at TARGET time.

  The authoritative `pkgs` is the one the module system built, i.e.
  `config._module.args.pkgs`: it has `nixpkgs.overlays`, `nixpkgs.config`
  (allowUnfree, ...) and the real hostPlatform applied.  mkMulix's own `pkgs`
  argument (a plain `legacyPackages.<system>`) has none of that, so handing it
  to fragments makes overlay-provided attributes disappear
  (`pkgs.lix.nix-init` -> "attribute 'nix-init' missing").

  Precedence when building fragment arguments:
      specialArgsBase.pkgs   (mkMulix `pkgs`; fallback when no module system pkgs)
    < config._module.args.pkgs   (this function)
    < args.pkgs           (explicit `specialArgs = { pkgs = ...; }`)

  Lazy on purpose: nothing is forced until a fragment actually uses `pkgs`.
  */
  moduleSystemPkgs = config: specialArgsBase: {
    pkgs = config._module.args.pkgs or (specialArgsBase.pkgs or null);
  };

  optionsFragment = {
    mod,
    specialArgsBase,
    configGraphForConfig,
    configGraphForOptions ? configGraphForConfig,
  }: args @ {
    config,
    lib,
    ...
  }: let
    graph = configGraphForOptions config;
    evalArgs =
      specialArgsBase
      // moduleSystemPkgs config specialArgsBase
      // args
      // graph
      // {
        opt = optOf mod.name config;
      };
    evaluated = evalDefinition mod evalArgs;
    raw = evaluated.options or {};
    evaluatedOptions =
      if lib.isFunction raw
      then raw evalArgs
      else raw;

    normalizedEnable =
      if evaluatedOptions ? enable
      then normalizeEnableSpec "options.enable" evaluatedOptions.enable
      else defaultEnableOption;
  in
    builtins.seq normalizedEnable {
      options.mulix.modules.${mod.name} =
        evaluatedOptions // {enable = normalizedEnable;};
    };

  mkAlwaysEntry = {
    mod,
    target,
    specialArgsBase,
    configGraphForConfig,
  }: args @ {
    config,
    lib,
    ...
  }: let
    # `args` は NixOS module system が供給する全引数 (config, lib, pkgs,
    # modulesPath, options, _module, specialArgs 経由の _module.args, ...)
    # を含む。`specialArgsBase` には mulix が供給する引数 (host, mulib,
    # configNames, ...) が入る。
    # `args` を後で `//` することで、NixOS module system 由来の modulesPath 等
    # が specialArgsBase の stub を上書きする。
    common =
      specialArgsBase
      // moduleSystemPkgs config specialArgsBase
      // args
      // configGraphForConfig config;
    evaluated = evalDefinition mod common;
    frag = evaluated.always.${target} or {};
  in
    if isEmptyStatic frag
    then {}
    else if lib.isFunction frag
    then frag (common // {opt = optOf mod.name config;})
    else frag;

  mkConditionalEntry = {
    mod,
    target,
    specialArgsBase,
    configGraphForConfig,
  }: args @ {
    config,
    lib,
    ...
  }: let
    common =
      specialArgsBase
      // moduleSystemPkgs config specialArgsBase
      // args
      // configGraphForConfig config;
    evaluated = evalDefinition mod common;
    frag = evaluated.${target} or {};
  in
    if isEmptyStatic frag
    then {}
    else if lib.isFunction frag
    then let
      result = frag (common // {opt = optOf mod.name config;});
    in {config = lib.mkIf (enableOf mod.name config) result;}
    else {config = lib.mkIf (enableOf mod.name config) frag;};

  mkModuleFragments = {
    mod,
    target,
    specialArgsBase,
    configGraphForConfig,
  }: [
    (mkAlwaysEntry {inherit mod target specialArgsBase configGraphForConfig;})
    (mkConditionalEntry {inherit mod target specialArgsBase configGraphForConfig;})
  ];

  checkTarget = context: target:
    if !(builtins.elem target targets)
    then
      throw ''
        mulix: invalid target '${target}'
        in module: ${context}
        allowed targets: ${builtins.concatStringsSep ", " targets}
      ''
    else target;

  /*
  Host configuration fragments (`os` / `home` / `darwin` of the merged host)
  are ordinary module-system modules, so the Nix module system does the merging.
  Cross-module host values use `send` / `send.force` and therefore do not have
  a separate direct-injection path.

  A function fragment is wrapped so that
    * arguments the module system can supply (`pkgs`, `lib`, `config`,
      `modulesPath`, `_module.args` entries, ...) are supplied by it, and
    * mulix's own arguments (`host`, `mulib`, configNames,
      specialArgs) are injected.
  `supplied` lists the names mulix injects; every other requested name is left
  to the module system.
  */
  mkHostFragmentModule = {
    frag,
    supplied,
    specialArgsBase,
    configGraphForConfig,
  }:
    if !lib.isFunction frag
    then frag
    else let
      requested = lib.functionArgs frag;
      suppliedSet = lib.genAttrs supplied (_: true);
    in
      lib.setFunctionArgs
      (args: let
        config = args.config;
        # Only the names mulix owns are injected; `pkgs`, `lib`, `modulesPath`,
        # ... keep coming from the module system.
        injected =
          builtins.intersectAttrs suppliedSet
          (
            specialArgsBase
            // configGraphForConfig config
          );
      in
        frag (builtins.intersectAttrs requested (args // injected)))
      ({
          config = false;
          lib = false;
        }
        // builtins.removeAttrs requested supplied);

  mkHostModules = {
    hostConfig,
    target,
    supplied,
    specialArgsBase,
    configGraphForConfig,
  }:
    map
    (f:
      mkHostFragmentModule {
        inherit (f) frag;
        inherit supplied specialArgsBase configGraphForConfig;
      })
    hostConfig.config.${target};

  mkTargetModuleList = {
    modules,
    target,
    specialArgsBase,
    configGraphForConfig,
    configGraphForOptions ? configGraphForConfig,
    hostConfig ? null,
    supplied ? [],
  }: let
    _targetCheck = checkTarget "mkTargetModuleList" target;
    optionsFrags = map (mod: optionsFragment {inherit mod specialArgsBase configGraphForConfig configGraphForOptions;}) modules;
    bodyFrags =
      lib.concatMap
      (mod: mkModuleFragments {inherit mod target specialArgsBase configGraphForConfig;})
      modules;
    hostFrags =
      if hostConfig == null
      then []
      else mkHostModules {inherit hostConfig target supplied specialArgsBase configGraphForConfig;};
  in
    builtins.seq _targetCheck (optionsFrags ++ bodyFrags ++ hostFrags);
in {
  inherit
    targets
    checkTarget
    optionsFragment
    mkAlwaysEntry
    mkConditionalEntry
    mkModuleFragments
    mkTargetModuleList
    mkHostModules
    mkHostFragmentModule
    conditionValue
    normalizeEnableSpec
    optOf
    ;
}
