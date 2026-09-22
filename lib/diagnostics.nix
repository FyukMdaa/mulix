{lib, reservedArgs}: let
  inherit (builtins) isAttrs isList elem;
  errorsLib = import ./errors.nix {inherit lib;};
  hostsLib = import ./hosts.nix {inherit lib;};

  # The canonical reserved namespace is owned by default.nix and injected here.
  # Do not duplicate the list: registry validation and diagnostics must use the
  # exact same namespace.
  mulixReservedArgs = reservedArgs;

  mkReport = severity: rule: module: source: message: {
    inherit severity rule module source message;
  };

  # always fragment が function で、opt を要求しているか
  alwaysUsesOpt = mod: let
    checkFrag = f:
      f
      != null
      && lib.isFunction f
      && elem "opt" (builtins.attrNames (lib.functionArgs f));
  in
    builtins.any checkFrag
    (
      [
        (mod.always.os or null)
        (mod.always.home or null)
        (mod.always.darwin or null)
      ]
      ++ builtins.attrValues (mod.always.send or {})
    );
in rec {
  inherit mulixReservedArgs;

  /*
  run:
    modules   = mkMulix 結果の modules (normalize 済み)
    registry  = configName registry (生の値でよい)
    force     = host force attrset (省略可)
    edges     = dependencyGraph.edges (省略可 — 使うルールでは
                実質不要だが、将来のルール拡張のために受ける)

  すべてのチェックは throw しない。ただし modules の属性
  (name / receiverArgs / declaredArgs / send / always) の WHNF を
  要求する — つまり mkMulix の正常完了後に呼ぶことを前提とする。
  */
  run = {
    modules,
    registry,
    force ? {},
    edges ? [],
    # mkMulix result `hosts` (merged hosts) and `hostFragments`
    hosts ? {},
    hostFragments ? [],
  }: let
    registryNames = builtins.attrNames registry;

    # ---- host composition ----
    # A fragment that sits in `hosts/<dir>/` but names a different host than
    # <dir> is usually a misplaced file.  The host's identity is always
    # `mulib.host { name }`, so this is a warning, never an error.
    hostDirectoryMismatch =
      map
      (f:
        mkReport "warning" "host-directory-mismatch" null (f.source or null) ''
          fragment ${f.label or "(unknown)"} declares host '${f.def.name}',
          but lives in directory '${f.dirName}'.
          The host identity is `mulib.host { name = ...; }`, so this fragment
          contributes to host '${f.def.name}', not to '${f.dirName}'.
          help: move the file, or fix `name` if it belongs to '${f.dirName}'.
        '')
      (builtins.filter
        (f: (f.dirName or null) != null && f.dirName != f.def.name)
        hostFragments);

    hostComposition =
      map
      (name:
        mkReport "info" "host-composition" null null ''
          host '${name}' is composed from ${toString (builtins.length hosts.${name}.sources.fragments)} fragments:
          ${hostsLib.formatSources hosts.${name}}
        '')
      (builtins.filter
        (name: builtins.length hosts.${name}.sources.fragments > 1)
        (builtins.attrNames hosts));

    # ---- 1. opaque dependency ----
    opaqueDeps =
      map
      (mod:
        mkReport "info" "opaque-dependency" mod.name (mod.source or null) ''
          module '${mod.name}' declares { config, ... } (or 'config'
          function argument). Dependencies through the Nix module
          system 'config' are opaque: mulix does not resolve or
          track them. Prefer send/configName for
          module-to-module communication.
        '')
      (builtins.filter
        (mod: elem "config" mod.declaredArgs)
        modules);

    # ---- 2. opt inside always ----
    optInAlways =
      map
      (mod:
        mkReport "warning" "opt-in-always" mod.name (mod.source or null) ''
          module '${mod.name}' has a function fragment under 'always'
          requesting 'opt'. 'always' is evaluated even when the module
          is disabled, so every option referenced through opt
          MUST have a safe default (contract). If a default
          cannot be provided, move that expression into the
          conditional target output (os/home/darwin).
        '')
      (builtins.filter alwaysUsesOpt modules);

    # ---- 3. no-default-no-sender ----
    # send は module-local enable とは独立したデータチャネルなので、
    # sender は常に contribution 候補になる。
    sendersByConfigName = lib.groupBy (c: c) (lib.concatMap
      (mod: builtins.attrNames (mod.send // (mod.always.send or {})))
      modules);

    potentialSenders = sendersByConfigName;

    receiversByConfigName = lib.groupBy (c: c) (lib.concatMap
      (mod:
        builtins.filter (a: elem a registryNames)
        (mod.receiverArgs or mod.declaredArgs or []))
      modules);

    noDefaultNoSender =
      map
      (configName:
        mkReport "warning" "no-default-no-sender" null null ''
          configName '${configName}' has no default and no sender contributes. If a receiver accesses
          it, mulix raises the missing-value error lazily:
            configName '${configName}' has no value
          Declare a default in the registry or add a sender.
        '')
      (builtins.filter
        (
          configName:
            !(builtins.hasAttr configName registry)
            || !(registry.${configName} ? default)
        )
        (builtins.filter
          (configName:
            (builtins.hasAttr configName receiversByConfigName)
            && !(builtins.hasAttr configName sendersByConfigName))
          registryNames));

    # ---- 4. unused configName (info) ----
    unusedConfigNames =
      map
      (configName:
        mkReport "info" "unused-configName" null null ''
          configName '${configName}' is declared in the registry but no
          module sends to it and no receiver requests it. Consider
          removing it or wiring a sender/receiver.
        '')
      (builtins.filter
        (configName:
          !(builtins.hasAttr configName potentialSenders)
          && !(builtins.hasAttr configName receiversByConfigName)
          && !(builtins.hasAttr configName force))
        registryNames);

    # ---- 5. reserved arg collision ----
    # configName 名が mulix 予約引数と衝突すると、receiver の
    # function argument で mulix 側の host/pkgs/lib/... が
    # shadowing される (callArgsBase // configGraphThunk では
    # configGraphThunk が後勝ちする)。
    reservedCollisions =
      map
      (configName:
        mkReport "error" "configName-reserved-arg-collision" null null ''
          configName '${configName}' collides with a mulix built-in
          function argument name (${builtins.concatStringsSep ", " mulixReservedArgs}).
          Receivers declaring { ${configName}, ... } would receive the
          configName value instead of the mulix built-in. Rename the
          configName (reserves is/type/feat/role for host conditions;
          this rule protects module function arguments analogously).
        '')
      (builtins.filter
        (configName: elem configName mulixReservedArgs)
        registryNames);

    # ---- 6. unknown configName の lint レポート ----
    # (mkMulix / resolveAll が throw するが、lint としても列挙する)
    unknownSends =
      lib.concatMap
      (mod:
        map
        (configName:
          mkReport "error" "unknown-configName-send" mod.name (mod.source or null) ''
            module '${mod.name}' sends to configName '${configName}'
            which is not declared in the registry.
          '')
        (builtins.filter
          (c: !(elem c registryNames))
          (builtins.attrNames (mod.send // (mod.always.send or {})))))
      modules;

    unknownReceiverArgs =
      lib.concatMap
      (mod:
        map
        (arg:
          mkReport "error" "unknown-configName-receiver" mod.name (mod.source or null) ''
            module '${mod.name}' requests function argument '${arg}'
            which is neither a mulix built-in nor a registered
            configName.
          '')
        (builtins.filter
          (arg: !(elem arg mulixReservedArgs) && !(elem arg registryNames))
          (mod.receiverArgs or mod.declaredArgs or [])))
      modules;

    unknownForces =
      map
      (configName:
        mkReport "error" "unknown-configName-force" null null ''
          force targets configName '${configName}' which is not declared
          in the registry.
        '')
      (builtins.filter (k: !(elem k registryNames)) (builtins.attrNames force));

    allReports =
      opaqueDeps
      ++ optInAlways
      ++ noDefaultNoSender
      ++ unusedConfigNames
      ++ reservedCollisions
      ++ unknownSends
      ++ unknownReceiverArgs
      ++ unknownForces
      ++ hostDirectoryMismatch
      ++ hostComposition;

    errors = builtins.filter (r: r.severity == "error") allReports;
    warnings = builtins.filter (r: r.severity == "warning") allReports;
    infos = builtins.filter (r: r.severity == "info") allReports;

    summary = ''
      mulix diagnostics: ${toString (builtins.length errors)} error(s),
      ${toString (builtins.length warnings)} warning(s),
      ${toString (builtins.length infos)} info(s)
    '';
  in {
    reports = allReports;
    inherit errors warnings infos summary;
  };

  /*
  formatReport: 1レポートを人間可読に整形する。
  (nix-instantiate での利用を想定した pure string 出力)
  */
  formatReport = r: ''
    [${r.severity}] ${r.rule}${
      if r.module == null
      then ""
      else " (module: ${r.module})"
    }${
      if (r.source or null) == null
      then ""
      else " [source: ${r.source}]"
    }
      ${lib.concatStringsSep "\n  " (lib.splitString "\n" r.message)}
  '';

  /*
  formatReports: run の戻り値を丸ごと整形する。
  */
  formatReports = {
    errors,
    warnings,
    infos,
    ...
  }:
    lib.concatStringsSep "\n"
    (map formatReport (errors ++ warnings ++ infos));
}
