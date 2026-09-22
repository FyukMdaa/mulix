{
  lib,
  pkgs ? null,
  inputs ? {},
}: let
  # Canonical module-function namespace reserved by mulix.  Keep this list in
  # one place only; diagnostics.nix receives it explicitly.
  mulixReservedArgs = [
    "mulib"
    "host"
    "pkgs"
    "lib"
    "inputs"
    "config"
    "options"
    "opt"
    "types"
    "mkOption"
    "mkEnableOption"
    "mkIf"
    "mkMerge"
    "mkDefault"
    "mkForce"
    "mkOverride"
    "mkOrder"
    "mkBefore"
    "mkAfter"
    # NixOS / Home Manager module environments may provide these through
    # specialArgs or _module.args.  They are not configName namespaces.
    "modulesPath"
    "osConfig"
  ];
  hostsLib = import ./hosts.nix {inherit lib;};
  collectorLib = import ./collector.nix {inherit lib;};
  normalizeLib = import ./normalize.nix {inherit lib;};
  configGraphLib = import ./config-graph.nix {inherit lib;};
  dependencyLib = import ./dependency.nix {inherit lib;};
  targetLib = import ./target.nix {inherit lib;};
  overlaysLib = import ./overlays.nix {inherit lib;};
  diagnosticsLib = import ./diagnostics.nix {inherit lib; reservedArgs = mulixReservedArgs;};
  errorsLib = import ./errors.nix {inherit lib;};
  graphLib = import ./graph.nix {inherit lib;};
  optionShorthands = import ./option-shorthands.nix {inherit lib;};
in rec {
  inherit
    hostsLib
    collectorLib
    normalizeLib
    configGraphLib
    dependencyLib
    targetLib
    optionShorthands
    overlaysLib
    ;
  inherit diagnosticsLib graphLib;

  inherit mulixReservedArgs;
  module = definition:
    if builtins.isAttrs definition
    then definition // { _mulixKind = "module"; }
    else
      throw "mulix: mulib.module expects a module attrset, got ${builtins.typeOf definition}";

  host = definition:
    if builtins.isAttrs definition
    then hostsLib.mkHost definition
    else throw "mulix: mulib.host expects a host attrset, got ${builtins.typeOf definition}";
  overlay = definition:
    if builtins.isAttrs definition
    then overlaysLib.mkOverlay definition
    else throw "mulix: mulib.overlay expects an attrset, got ${builtins.typeOf definition}";
  mulibApi = {
    inherit module host overlay;
    mkMulix = mkMulix;
    runDiagnostics = diagnosticsLib.run;
    graphLib = graphLib;
    types = lib.types;
    type = optionShorthands.type;
    inherit (lib) mkOption mkEnableOption mkIf mkMerge mkDefault mkForce
      mkOverride mkOrder mkBefore mkAfter;
    inherit (optionShorthands) bool str int float lines enum oneOf attrs attrsOf path package listOf nullOr either select;
  };
  runDiagnostics = diagnosticsLib.run;
  mkMulix = {
    # Host definitions: { <name> = mulib.host {...}; } (a list of fragments per
    # name is accepted too).  Optional: hosts can also come from `paths`.
    hostDefs ? {},
    host,
    conditionNames ? {},
    # Directories (or single files) discovered recursively. Only files that
    # return a mulib.module, mulib.host or mulib.overlay descriptor participate.
    paths ? [],
    # Extra mulib.overlay descriptors (in addition to those found in `paths`).
    overlays ? [],
    configNames ? {},
    force ? {},
    specialArgs ? {},
    # pkgs: module トップレベル関数が `pkgs` を要求する場合に渡す。
    # `configurations` は host の system から自動的に引いて渡す。
    # 手動で mkMulix を呼ぶ場合は明示的に渡す必要がある (省略時は null)。
    #
    # 使われる場面:
    #   * collection 時 (name / 静的な send 値 / 診断など): overlay 適用済みの
    #     `pkgs.extend` 版 (Pass 2) が使われる。
    #   * target 評価時: これは *fallback* でしかない。module system が構築した
    #     `config._module.args.pkgs` (nixpkgs.overlays / nixpkgs.config /
    #     hostPlatform 適用済み) があればそちらが fragment に渡される。
    #     (target.nix: moduleSystemPkgs)
    pkgs ? null,
  }: let
    _hostDefsInputCheck =
      if !builtins.isAttrs hostDefs
      then throw ''
        mulix: invalid hosts input
        expected an attrset mapping host names to host definitions, got: ${builtins.typeOf hostDefs}
        (input validation)
      ''
      else true;
    _pathsInputCheck =
      if !builtins.isList paths || builtins.any (p: !(builtins.isPath p)) paths
      then throw ''
        mulix: invalid paths input
        expected a list of paths (directories or .nix files), got: ${builtins.typeOf paths}
        (input validation)
      ''
      else true;
    _overlaysInputCheck =
      if !builtins.isList overlays
      then throw ''
        mulix: invalid overlays input
        expected a list of mulib.overlay descriptors, got: ${builtins.typeOf overlays}
        (input validation)
      ''
      else true;
    _hostInputCheck =
      if !(builtins.isString host)
      then throw ''
        mulix: invalid host input
        expected a host name string, got: ${builtins.typeOf host}
        (input validation)
      ''
      else true;
    _configNamesInputCheck =
      if !(builtins.isAttrs configNames)
      then throw ''
        mulix: invalid configNames input
        expected an attrset registry, got: ${builtins.typeOf configNames}
        (input validation)
      ''
      else true;
    _forceInputCheck =
      if !(builtins.isAttrs force)
      then throw ''
        mulix: invalid force input
        expected an attrset mapping configName paths to overrides, got: ${builtins.typeOf force}
        (input validation)
      ''
      else true;
    _specialArgsInputCheck =
      if !(builtins.isAttrs specialArgs)
      then throw ''
        mulix: invalid specialArgs input
        expected an attrset of module arguments, got: ${builtins.typeOf specialArgs}
        (input validation)
      ''
      else true;
    _inputChecks =
      builtins.seq _hostDefsInputCheck
      (builtins.seq _pathsInputCheck
      (builtins.seq _overlaysInputCheck
      (builtins.seq _hostInputCheck
        (builtins.seq _configNamesInputCheck
            (builtins.seq _forceInputCheck
              _specialArgsInputCheck)))));
    registryNames = builtins.attrNames configNames;
    reservedArgNames = lib.unique (mulixReservedArgs ++ builtins.attrNames specialArgs);
    validatedRegistry = configGraphLib.validateRegistryWithReserved configNames {reservedNames = reservedArgNames;};
    # Intentional strictness: mulix statically validates the registry before
    # constructing the module graph.  This deepSeq is part of the static
    # evaluation contract, not an incidental implementation detail.
    _registryCheck = builtins.deepSeq validatedRegistry true;
    selectedHostName = host;

    # ---- discovery: `paths` -----------------------------------------------
    # Every .nix file below `paths` is imported and called for descriptor
    # classification. Only mulib.module / mulib.host / mulib.overlay results
    # participate; other results are ignored.
    pathEntries =
      map
      (e:
        e
        // {
          def = import e.path;
          source = toString e.path;
        })
      (collectorLib.collectPaths paths);

    # ---- Pass 1: classify files & extract overlays -------------------------
    # Check top-level function receiver names before calling the function.  A
    # missing unknown receiver must be reported as a configName error rather
    # than as a generic Nix missing-argument error from callModule.  Target
    # fragments/options/send functions are checked later by normalizeModule.
    checkTopLevelReceiverArgs = context: def:
      let
        unknown = builtins.filter
          (arg:
            !(builtins.elem arg reservedArgNames)
            && !(builtins.elem arg registryNames))
          (normalizeLib.functionArgsOf def);
      in
        if unknown == []
        then true
        else
          throw ''
            mulix: unknown configName in receiver arguments
            module function(s) in '${context}' request argument name(s) that are
            neither mulix built-ins nor declared configNames:
              ${lib.concatStringsSep "\n  " (map (arg: "- '${arg}'") unknown)}
            (The “receiver” argument must be pre-registered in the registry.)
            help: declare the configName in configNames before use.
          '';
    calledPathEntriesPass1 =
      map
      (e:
        e
        // {
          called =
            builtins.seq
            (checkTopLevelReceiverArgs e.label e.def)
            (normalizeLib.callModule
              "at ${e.label}"
              (callArgsBase // configGraphThunk)
              e.def);
        })
      pathEntries;
    kindOfPass1 = e:
      if builtins.isAttrs e.called
      then e.called._mulixKind or null
      else null;
    entriesOfKindPass1 = kind: builtins.filter (e: kindOfPass1 e == kind) calledPathEntriesPass1;
    # Non-descriptor files are intentionally ignored. This keeps `paths`
    # flexible enough to contain helper .nix files without making them part of
    # mulix's public collection contract.
    _pathsKindCheck = true;

    # ---- overlays (resolved from Pass 1 descriptors) -----------------------
    overlayEntries =
      map (e: {def = e.called; label = e.label;}) (entriesOfKindPass1 "overlay")
      ++ lib.imap0 (i: d: {def = d; label = "overlays[${toString i}]";}) overlays;
    resolvedOverlays = overlaysLib.resolve {
      entries = overlayEntries;
      conditionValue = targetLib.conditionValue;
    };
    _overlayCheck = builtins.seq (builtins.length resolvedOverlays.overlays) true;

    # ---- build overlay-applied pkgs (Pass 2 pkgs) --------------------------
    # Re-evaluate module/host files with pkgs that has overlays applied,
    # so `pkgs.stable` (overlay-derived) works inside attrset fragments.
    # `pkgs.extend` applies overlays on top of the base pkgs, giving the
    # same result as NixOS module system's `nixpkgs.overlays`.
    hostPkgs =
      if pkgs != null && resolvedOverlays.overlays != []
      then pkgs.extend (lib.composeManyExtensions resolvedOverlays.overlays)
      else pkgs;
    callArgsBasePass2 = callArgsBase // { pkgs = hostPkgs; };

    # ---- Pass 2: re-call module/host files with overlay-applied pkgs -------
    # Module and host descriptors from Pass 1 used overlay-less pkgs, so
    # any `pkgs.stable` in attrset fragments would be broken.  Re-call
    # them with overlay-applied pkgs to fix this.  Overlay descriptors
    # from Pass 1 are reused (they don't reference pkgs at top level).
    calledPathEntries =
      map
      (e:
        if kindOfPass1 e == "overlay"
        then e
        else
          e
          // {
            called =
              normalizeLib.callModule
              "at ${e.label}"
              (callArgsBasePass2 // configGraphThunk)
              e.def;
          })
      calledPathEntriesPass1;
    kindOf = e:
      if builtins.isAttrs e.called
      then e.called._mulixKind or null
      else null;
    entriesOfKind = kind: builtins.filter (e: kindOf e == kind) calledPathEntries;

    # ---- hosts: fragments -> one merged host per name -----------------------
    hostFragments =
      hostsLib.fragmentsFromHostDefs hostDefs
      ++ map
      (e:
        builtins.seq (hostsLib.validateHost e.label e.called) {
          def = e.called;
          inherit (e) source label dirName;
        })
      (entriesOfKind "host");
    composedHosts = hostsLib.composeFragments hostFragments;
    _selectedHostCheck =
      if builtins.hasAttr selectedHostName composedHosts
      then true
      else
        throw ''
          mulix: unknown host '${selectedHostName}'
          known hosts: ${builtins.concatStringsSep ", " (builtins.attrNames composedHosts)}
        '';
    hostView = hostsLib.mkComposedView {
      composed = composedHosts;
      inherit conditionNames;
      hostName = selectedHostName;
    };
    hostDef = builtins.seq _selectedHostCheck composedHosts.${selectedHostName};
    hostAttrs = {
      inherit (hostDef) name system features roles sources;
      is = hostView.is;
      type = hostView.type;
      feat = hostView.feat;
      role = hostView.role;
    };
    hostViewRaw = hostView;
    hostViewCheck =
      if builtins.isAttrs hostViewRaw
      then true
      else throw ''
        mulix: internal error: host view must be an attrset,
        got: ${builtins.typeOf hostViewRaw}
      '';

    # ---- modules: descriptors discovered from `paths` -----------------------
    collected =
      lib.imap0
      (index: e: e // {inherit index;})
      (entriesOfKind "module");
    topLevelConfigPlaceholder = throw ''
      mulix: 'config' is not available at module top-level
      The Nix module system 'config' (escape hatch) is provided
      by lib.evalModules, which runs after mulix's module collection.
      It IS available inside target fragments written as functions:

        os = { config, opt, ... }: { ... };        # OK
        home = { config, opt, ... }: { ... };      # OK
        always.os = { config, opt, ... }: { ... }; # OK

      but NOT in the module top-level (name/always/os/home/
      darwin/send values evaluated eagerly by mulix):

        os = { foo = config.bar; };                # NOT available

      If you need the merged config inside a fragment, make the
      fragment a function. If you need a value from another module,
      use send / configName instead.
    '';
    topLevelOptionsPlaceholder = throw ''
      mulix: 'options' is not available at module top-level
      The Nix module system 'options' is provided by
      lib.evalModules. Make the target fragment a function
      ({ options, opt, ... }: ...) to access it.
    '';

    mulibForHost = mulibApi;
    # NixOS module system が提供する引数の stub。
    # `modulesPath` は host fragment の `os`/`home`/`darwin`/`shared` 内で
    # よく使われる (imports = [ (modulesPath + "/...") ])。collection 時に
    # null を渡すと、thunk に null が焼き込まれ target time に復旧できない。
    # そこで inputs.nixpkgs から real path を構築して渡す。
    # `osConfig` / `_module` は collection 時には使われないので null でよい。
    nixosStubArgs = {
      modulesPath =
        if inputs ? nixpkgs
        then builtins.toString (inputs.nixpkgs + "/nixos/modules")
        else null;
      osConfig = null;
      _module = null;
    };
    callArgsBase =
      nixosStubArgs
      // specialArgs
      // {
        mulib = mulibForHost;
        host = hostAttrs;
        pkgs = specialArgs.pkgs or pkgs;
        inherit lib inputs;
        config = topLevelConfigPlaceholder;
        options = topLevelOptionsPlaceholder;
        inherit (mulibApi) types mkOption mkEnableOption mkIf mkMerge mkDefault mkForce
          mkOverride mkOrder mkBefore mkAfter;
      };
    checkedRaw =
      collectorLib.collectAndCheck
      (c:
        c.called
        or (normalizeLib.callModule
          "at collection index ${toString c.index}${if (c.source or null) == null then "" else " [source: ${c.source}]"}"
          (callArgsBase // configGraphThunk)
          c.def))
      collected;

    normalizedModules =
      map
      (c:
        normalizeLib.normalizeModule {
          mod = c.mod;
          isFunction = normalizeLib.isFunctionModule c.def;
          declaredArgs = normalizeLib.functionArgsOf c.def;
          source = c.source or null;
        }
        // {
          index = c.index;
          source = c.source or null;
          definition = c.def;
        })
      checkedRaw;
    unknownReceiverArgs =
      builtins.concatMap
      (mod:
        map
        (arg: {
          inherit arg;
          module = mod.name;
        })
        (builtins.filter
          (arg:
            !(builtins.elem arg reservedArgNames)
            && !(builtins.elem arg registryNames))
          mod.receiverArgs))
      normalizedModules;

    _receiverCheck =
      if unknownReceiverArgs != []
      then
        throw ''
          mulix: unknown configName in receiver arguments
          module function(s) request argument name(s) that are neither
          mulix built-ins nor declared configNames:
            ${lib.concatStringsSep "\n  "
            (map (u: "- '${u.arg}' (in module '${u.module}')")
              unknownReceiverArgs)}
          (The “receiver” argument must be pre-registered in the registry.
           mulix reserved args: ${builtins.concatStringsSep ", " reservedArgNames})
        ''
      else true;
    dependencyGraph = dependencyLib.checkNoCycles {
      modules = normalizedModules;
      configNames = registryNames;
    };
    sendDeclarations =
      builtins.concatMap
      (mod:
        map
        (configName: {
          inherit configName;
          module = mod.name;
          source = mod.source or null;
          position = errorsLib.attrPos mod.send configName;
          alwaysPosition = errorsLib.attrPos mod.always.send configName;
        })
        (builtins.attrNames (mod.send // mod.always.send)))
      normalizedModules;

    unknownSendTargets =
      builtins.filter
      (c: !(builtins.elem c.configName registryNames))
      sendDeclarations;
    _sendCheck =
      if unknownSendTargets != []
      then
        throw ''
          mulix: unknown configName in send
          module(s) send to configName(s) not declared in the registry:
            ${lib.concatStringsSep "\n  "
            (map (c:
              "- '${c.configName}' (in module '${c.module}'${if (c.source or null) == null then "" else " [source: ${c.source}]"})${errorsLib.formatLocation (if c.position != null then c.position else c.alwaysPosition)}")
              unknownSendTargets)}
          (all configName must be declared in the registry before use)
          help: declare the configName in configNames before any module sends to it.
          help: if this name is a typo, check the configNames registry spelling.
        ''
      else true;
    evalSendValue = {config, contribution, graph}: let
      # `contribution.module` is the sender's module name, which is exactly the
      # key of its options; no module lookup is needed (a linear scan per
      # contribution would be O(N^2) over all senders).
      baseArgs =
        callArgsBase
        // {
          opt = config.mulix.modules.${contribution.module};
          # Same rule as target fragments: the module system's `pkgs` (with
          # overlays applied) wins over mkMulix's own `pkgs` argument.
          pkgs = config._module.args.pkgs or (callArgsBase.pkgs or null);
        }
        // graph;
    in
      if lib.isFunction contribution.value
      then contribution.value baseArgs
      else contribution.value;

    # `send` carries ordinary Nix module-definition properties as well as
    # values.  Discharge/filter/sort them *across the complete contribution
    # set for one configName*, just like lib.evalModules does.  Applying
    # filterOverrides/sortProperties one contribution at a time would lose
    # the priority/order information needed to compare different modules.
    # mkIf / mkMerge discharge.  `lib.modules.dischargeProperties` is deprecated
    # for external use (it emits an evaluation warning), so this is a local
    # equivalent with the same semantics.
    dischargeSendProperties = value: let
      type = if builtins.isAttrs value then value._type or null else null;
    in
      if type == "merge"
      then lib.concatMap dischargeSendProperties value.contents
      else if type == "if"
      then
        if builtins.isBool value.condition
        then
          if value.condition
          then dischargeSendProperties value.content
          else []
        else throw "mulix: mkIf in send was called with a non-boolean condition (got: ${builtins.typeOf value.condition})"
      else [value];

    applySendProperties = {config, contributions, graph}: let
      defs = map
        (contribution: {
          file = contribution.source or "<mulix ${contribution.module}>";
          value = evalSendValue {inherit config contribution graph;};
          inherit contribution;
        })
        contributions;
      discharged = lib.concatMap
        (def:
          map
          (value: {
            inherit (def) file contribution;
            inherit value;
          })
          (dischargeSendProperties def.value))
        defs;
      filtered = lib.modules.filterOverrides discharged;
      sorted = lib.modules.sortProperties filtered;
    in
      map (def: def.contribution // {value = def.value;}) sorted;

    configGraphForConfig = config: let
      graph = configGraphLib.resolveAll {
        # Re-validate the user registry here rather than the normalized registry:
        # bind = "mulix.modules" owns its injected type/default, so feeding the
        # normalized form back into the public validator would look like a user
        # supplied type/default. The eager `_registryCheck` above has already
        # validated the same original input.
        registry = configNames;
        baseValues = lib.genAttrs boundConfigNames (_: config.mulix.modules);
        contributionsFor = configName:
          applySendProperties {
            inherit config graph;
            contributions = builtins.filter
              (c: (c.always or false) || config.mulix.modules.${c.module}.enable)
              (sendContributionsFor configName);
          };
        inherit force;
      };
    in graph;

    sendContributionsFor = configName:
      lib.concatMap
      (mod:
        (lib.optional (builtins.hasAttr configName mod.send) {
          inherit configName;
          module = mod.name;
          index = mod.index;
          value = mod.send.${configName};
          source = mod.source or null;
        })
        ++ (lib.optional (builtins.hasAttr configName mod.always.send) {
          inherit configName;
          module = mod.name;
          index = mod.index;
          value = mod.always.send.${configName};
          source = mod.source or null;
          always = true;
        }))
      normalizedModules;

    # `configGraph` (exported) is the STATIC view of the configName graph.
    #
    # `enable` only exists inside the module fixpoint, so this view cannot
    # know it: it contains the send contributions of EVERY module, including
    # modules that end up DISABLED when a target is evaluated.  Target
    # fragments and receivers observe the enable-filtered graph instead
    # (disabled modules' non-`always` sends are excluded there).  Read
    # `configGraph` as "all potential contributions", never as "effective
    # values".  Function-valued sends (which need `opt`) are not available in
    # this view at all; they are evaluated at target time.
    #
    # Collection-time arguments for ordinary configNames use the static graph.
    # A configName bound to `config.mulix.modules` deliberately throws when forced
    # this early because its base value exists only at target time.
    configGraph = configGraphLib.resolveAll {
      registry = configNames;
      contributionsFor = configName:
        applySendProperties {
          config = null;
          graph = configGraphThunk;
          contributions = map
            (c: c // {
              value =
                if lib.isFunction c.value
                then throw ''
                  mulix: send.${configName} requires evaluated module options
                  (`opt`) and therefore cannot be consumed during module
                  collection. Consume this configName from a target fragment
                  or another send transformation instead.
                ''
                else c.value;
            })
            (sendContributionsFor configName);
        };
      inherit force;
    };
    unknownForceTargets =
      builtins.filter
      (k: !(builtins.elem k registryNames))
      (builtins.attrNames force);
    _forceCheck =
      if unknownForceTargets != []
      then
        throw ''
          mulix: unknown configName in force
          force targets configName(s) not declared in the registry:
            ${builtins.concatStringsSep ", " unknownForceTargets}
          (all configName must be declared in the registry before use)
        ''
      else true;
    # Bound configNames are aliases of config.mulix.modules and therefore only
    # exist after the target module-system fixpoint. They are present in the
    # receiver namespace during collection, but accessing one there is an error.
    boundConfigNames = builtins.filter
      (name: (validatedRegistry.${name}.bind or null) == "mulix.modules")
      registryNames;
    configGraphThunk = lib.genAttrs registryNames (name:
      if builtins.elem name boundConfigNames
      then throw ''
        mulix: configName '${name}' is bound to config.mulix.modules
        and is not available during module collection.
        Use it from a target fragment after the Nix module fixpoint is available.
      ''
      else configGraph.${name});
    targetArgsFor = target:
      builtins.removeAttrs
        callArgsBase
        # `config` / `options` は target time に module system から供給される。
        # `modulesPath` / `osConfig` / `_module` は NixOS module system が
        # 供給するため、stub を remove して module system 由来の値が使われるようにする。
        ["config" "options" "modulesPath" "osConfig" "_module"];

    # Argument names mulix itself injects into host `os` / `home` / `darwin` /
    # `shared` function fragments.  Everything else they request (`pkgs`, `lib`,
    # `modulesPath`, ...) is left to the Nix module system.
    hostFragmentSuppliedArgs =
      lib.unique
      ([
          "host" "mulib" "types" "mkOption" "mkEnableOption" "mkIf"
          "mkMerge" "mkDefault" "mkForce" "mkOverride" "mkOrder" "mkBefore" "mkAfter"
        ]
        ++ registryNames
        ++ builtins.attrNames specialArgs
        ++ lib.optional (inputs != {}) "inputs");

    targetModuleList = target:
      targetLib.mkTargetModuleList {
        modules = normalizedModules;
        inherit target;
        specialArgsBase = targetArgsFor target;
        configGraphForConfig = configGraphForConfig;
        configGraphForOptions = _: configGraphThunk;
        hostConfig = hostDef;
        supplied = hostFragmentSuppliedArgs;
      };
    _checksDone =
      builtins.seq _inputChecks
      (builtins.seq _pathsKindCheck
      (builtins.seq _overlayCheck
      (builtins.seq hostViewCheck
      (builtins.seq _registryCheck
      (builtins.seq _receiverCheck
        (builtins.seq _sendCheck
          (builtins.seq _forceCheck
            (builtins.seq dependencyGraph true))))))));
  in
    builtins.seq _checksDone {
      host = hostAttrs;
      inherit
        configGraph
        dependencyGraph
        targetArgsFor
        targetModuleList
        hostFragments
        ;
      # every host of the fleet, merged from its fragments
      hosts = composedHosts;
      # where the selected host's fields came from (see hostsLib.formatSources)
      hostSources = hostDef.sources;
      overlays = resolvedOverlays.overlays;
      overlaysByName = resolvedOverlays.byName;
      # include this in a NixOS / nix-darwin configuration to apply the overlays
      overlayModule = {nixpkgs.overlays = resolvedOverlays.overlays;};
      modules = normalizedModules;
    };

  # ===========================================================================
  # configurations — denix.lib.configurations と同じ立ち位置の helper
  # ===========================================================================
  #
  # flake.nix のボイラープレートをなくすための1関数 API。
  #
  #   let
  #     m = mulix.lib { inherit lib; inputs; };
  #     cfgs = m.configurations {
  #       paths = [ ./hosts ./modules ./overlays ];
  #       conditionNames = import ./conditionNames.nix;
  #       configNames = import ./configNames.nix { inherit lib; };
  #       specialArgs = { inherit inputs; };
  #       extraNixosModules = [ home-manager.nixosModules.home-manager ];
  #       extraDarwinModules = [ home-manager.darwinModules.home-manager ];
  #     };
  #   in {
  #     inherit (cfgs) nixosConfigurations darwinConfigurations homeConfigurations;
  #   }
  #
  # 戻り値:
  #   {
  #     nixosConfigurations  = { <linux-host> = nixosSystem の結果; };
  #     darwinConfigurations = { <darwin-host> = darwinSystem の結果; };
  #     homeConfigurations   = { <全host> = homeManagerConfiguration の結果; };
  #     raw                  = { <host> = mkMulix の結果; };   # diagnostics / graph 用
  #   }
  #
  # host が linux か darwin かは `host.system` から自動判別される。
  # `nixosSystem` / `darwinSystem` / `homeManagerConfiguration` は外部から渡せる
  # (依存を硬encodeしない)。
  configurations = {
    # 収集対象。`paths` 1つで hosts / modules / overlays を全部収集する。
    paths ? [],
    # hosts / overlays を明示的に足す (optional)
    hostDefs ? {},
    overlays ? [],
    # mulix 設定
    conditionNames ? {},
    configNames ? {},
    force ? {},
    specialArgs ? {},
    # 各 module-system に足す extra module (home-manager の module 等)
    extraNixosModules ? [],
    extraDarwinModules ? [],
    extraHomeModules ? [],
    # 各 module-system の wrapper。渡されなければ nixpkgs.lib.nixosSystem 等を使う。
    nixosSystem ? null,
    darwinSystem ? null,
    homeManagerConfiguration ? null,
    # legacyPackages を引く pkgs-set。渡されなければ inputs.nixpkgs.legacyPackages を使う。
    pkgsFor ? null,
    # standalone home-manager 用のユーザ名 (homeConfigurations のキーにする)
    # 省略時は host 名をそのままキーにする
    homeManagerUser ? null,
  }: let
    # ---- fleet discovery ------------------------------------------------
    # `configurations` は全 host を一度にビルドする必要があるが、`mkMulix` は
    # `host` (単一) を必須とする。そこで、paths と hostDefs から host 名を
    # 先に取り出す軽量 discovery を行う。
    #
    # host fragment は通常 `mulib` しか読まない (host を定義する側なので)。
    # ここでは `host` / `config` と登録済み configName を throw にした callArgs で呼び出し、
    # `_mulixKind == "host"` なものだけを拾う。
    #
    # NixOS module system が提供する引数 (modulesPath, osConfig, ...) も
    # stub として渡す。host fragment のトップレベルではこれらを使わない
    # (os/home/darwin フラグメントの中で使う) ので、null で十分。
    fleetHostNames =
      let
        pathEntries = collectorLib.collectPaths paths;
        # NixOS module system が提供する引数の stub。host fragment の関数が
        # これらを要求しても throw しないようにする。実際の値は target time
        # に module system から注入される。
        nixosStubArgs = lib.genAttrs [
          "modulesPath" "osConfig" "_module"
        ] (_: null);
        discoveryConfigNames = lib.genAttrs (builtins.attrNames configNames) (name:
          throw ''
            mulix: configName '${name}' is not available during fleet discovery
            A configName is injected after the target module-system fixpoint is built.
          '');
        discoveryArgs =
          specialArgs
          // nixosStubArgs
          // discoveryConfigNames
          // {
            mulib = mulibApi;
            host = throw "mulix: 'host' is not available during fleet discovery";
            inherit pkgs lib inputs;
            config = throw "mulix: 'config' is not available during fleet discovery";
            options = throw "mulix: 'options' is not available during fleet discovery";
            inherit (mulibApi) types mkOption mkEnableOption mkIf mkMerge mkDefault mkForce
              mkOverride mkOrder mkBefore mkAfter;
          };
        calledFromPaths =
          lib.filter (x: x != null)
          (map
            (e:
              let
                def = import e.path;
                called = normalizeLib.callModule "at ${e.label}" discoveryArgs def;
              in
                if builtins.isAttrs called && (called._mulixKind or null) == "host"
                then called.name
                else null)
            pathEntries);
        fromHostDefs = builtins.attrNames hostDefs;
      in
        lib.unique (calledFromPaths ++ fromHostDefs);

    # pkgs を引く helper
    pkgsOf = system:
      if pkgsFor != null
      then
        if lib.isFunction pkgsFor
        then pkgsFor system
        else pkgsFor.${system} or (throw "mulix: pkgsFor has no entry for system '${system}'")
      else if inputs ? nixpkgs
      then inputs.nixpkgs.legacyPackages.${system} or (throw "mulix: nixpkgs.legacyPackages has no entry for system '${system}'")
      else throw "mulix: configurations needs `pkgsFor` or `inputs.nixpkgs` to build packages for system '${system}'";

    # 各 host について mkMulix を呼ぶ
    # host の system から pkgs を引いて渡す。これにより module トップレベルで
    # `pkgs` を要求する module が collection 時に正しい pkgs を参照できる。
    rawPerHost = builtins.listToAttrs (map (hostName:
      let
        # fleet discovery で取得した host 名から system を引くため、
        # 一度 mkMulix を host 指定で呼んで host.system を取り出す必要があるが、
        # それだと2回評価することになる。代わりに paths/hostDefs から
        # host fragment を評価して system を取り出す。
        # 簡易的に、mkMulix を pkgs=null で1回呼んで host.system を取得し、
        # その system から pkgs を引いて再度 mkMulix を呼ぶ。
        # ただし Nix の laziness により、host.system に依存しない部分は
        # 1回しか評価されないので、実質的なオーバーヘッドは少ない。
        r0 = mkMulix {
          inherit paths hostDefs overlays conditionNames configNames force specialArgs;
          host = hostName;
        };
        system = r0.host.system or null;
        hostPkgs = if system != null then pkgsOf system else null;
      in {
        name = hostName;
        value = mkMulix {
          inherit paths hostDefs overlays conditionNames configNames force specialArgs;
          host = hostName;
          pkgs = hostPkgs;
        };
      }
    ) fleetHostNames);

    # host の system から linux / darwin を判別
    isLinux = r: let sys = r.host.system or null; in sys != null && (builtins.match ".*-linux" sys) != null;
    isDarwin = r: let sys = r.host.system or null; in sys != null && (builtins.match ".*-darwin" sys) != null;

    # nixosSystem の遅延解決
    nixosSystemFn =
      if nixosSystem != null
      then nixosSystem
      else if inputs ? nixpkgs
      then inputs.nixpkgs.lib.nixosSystem
      else throw "mulix: configurations needs `nixosSystem` or `inputs.nixpkgs` to build NixOS configurations";

    darwinSystemFn =
      if darwinSystem != null
      then darwinSystem
      else if inputs ? nix-darwin
      then inputs.nix-darwin.lib.darwinSystem
      else throw "mulix: configurations needs `darwinSystem` or `inputs.nix-darwin` to build nix-darwin configurations";

    homeManagerConfigurationFn =
      if homeManagerConfiguration != null
      then homeManagerConfiguration
      else if inputs ? home-manager
      then inputs.home-manager.lib.homeManagerConfiguration
      else null;  # home は省略可能にする

    # NixOS configurations (linux host のみ)
    nixosConfigurations = builtins.listToAttrs (lib.filter (x: x != null) (lib.mapAttrsToList (hostName: r:
      if isLinux r
      then {
        name = hostName;
        value = nixosSystemFn {
          system = r.host.system;
          modules = (r.targetModuleList "os") ++ [
            r.overlayModule
          ] ++ extraNixosModules;
          specialArgs = specialArgs // { inherit inputs; };
        };
      }
      else null
    ) rawPerHost));

    # nix-darwin configurations (darwin host のみ)
    darwinConfigurations = builtins.listToAttrs (lib.filter (x: x != null) (lib.mapAttrsToList (hostName: r:
      if isDarwin r
      then {
        name = hostName;
        value = darwinSystemFn {
          system = r.host.system;
          modules = (r.targetModuleList "darwin") ++ [
            r.overlayModule
          ] ++ extraDarwinModules;
          specialArgs = specialArgs // { inherit inputs; };
        };
      }
      else null
    ) rawPerHost));

    # Home Manager standalone configurations (全 host)
    # homeManagerUser が指定された場合はそのユーザ名をキーに、
    # 省略時は host 名をキーにする
    homeConfigurations =
      if homeManagerConfigurationFn == null
      then {}
      else builtins.listToAttrs (lib.mapAttrsToList (hostName: r:
        let
          key = if homeManagerUser != null then homeManagerUser else hostName;
        in {
          name = key;
          value = homeManagerConfigurationFn {
            pkgs = pkgsOf r.host.system;
            modules = (r.targetModuleList "home") ++ [
              r.overlayModule
            ] ++ extraHomeModules;
            extraSpecialArgs = specialArgs // { inherit inputs; };
          };
        }
      ) rawPerHost);
  in {
    inherit nixosConfigurations darwinConfigurations homeConfigurations;
    # diagnostics / graph 用に mkMulix 結果も露出
    raw = rawPerHost;
    # fleet 全体の host 名リスト (debug 用)
    hostNames = fleetHostNames;
  };
}
