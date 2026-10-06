# `configurations` - the fleet helper that turns `paths` into
# `nixosConfigurations` / `darwinConfigurations` / `homeConfigurations`.
#
# This file exists to keep `lib/default.nix` focused on the wiring layer.
# `configurations` is a cohesive 300-line function: it does fleet
# discovery, builds `mkMulix` once per host, and feeds the result into
# `nixosSystem` / `darwinSystem` / `homeManagerConfiguration`.
#
# Dependency injection:
#   `lib/default.nix` imports this file and supplies `lib`, `mulibApi`,
#   `mkMulix`, and the collector / normalizer helpers. The wrapper
#   returns `{ configurations = ...; }` so the original `configurations`
#   assignment is preserved byte-for-byte.
{
  lib,
  mulibApi,
  mkMulix,
  normalizeLib,
  collectorLib,
}: {
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
    # Home Manager を NixOS / nix-darwin の OS build に統合する。
    # `true` だけでも有効化でき、その場合は `homeManagerUser` を利用する。
    # Attrset なら `user` / `useGlobalPkgs` を指定できる。
    #
    #   homeManager = {
    #     enable = true;
    #     user = "alice";
    #     useGlobalPkgs = true;
    #   };
    homeManager ? false,
    # standalone home-manager 用のユーザ名。`homeManager.user` が指定されていれば
    # そちらを優先する。
    homeManagerUser ? null,
    # 各 module-system の wrapper。渡されなければ nixpkgs.lib.nixosSystem 等を使う。
    nixosSystem ? null,
    darwinSystem ? null,
    homeManagerConfiguration ? null,
    # legacyPackages を引く pkgs-set。渡されなければ inputs.nixpkgs.legacyPackages を使う。
    pkgsFor ? null,
  }: let
    homeManagerConfig =
      if builtins.isBool homeManager
      then { enable = homeManager; }
      else if builtins.isAttrs homeManager
      then homeManager
      else throw ''
        mulix: invalid homeManager input
        expected a bool or attrset, got: ${builtins.typeOf homeManager}
        (configurations input)
      '';
    homeManagerEnabled = homeManagerConfig.enable or false;
    homeManagerUseGlobalPkgs = homeManagerConfig.useGlobalPkgs or true;
    effectiveHomeManagerUser =
      if (homeManagerConfig.user or null) != null
      then homeManagerConfig.user
      else homeManagerUser;
    _homeManagerShapeCheck =
      if !(builtins.isBool homeManagerEnabled)
      then throw ''
        mulix: invalid homeManager.enable input
        expected a boolean, got: ${builtins.typeOf homeManagerEnabled}
        (configurations input)
      ''
      else if !(builtins.isBool homeManagerUseGlobalPkgs)
      then throw ''
        mulix: invalid homeManager.useGlobalPkgs input
        expected a boolean, got: ${builtins.typeOf homeManagerUseGlobalPkgs}
        (configurations input)
      ''
      else if effectiveHomeManagerUser != null && !(builtins.isString effectiveHomeManagerUser)
      then throw ''
        mulix: invalid Home Manager user
        expected a string or null, got: ${builtins.typeOf effectiveHomeManagerUser}
        (configurations input)
      ''
      else true;
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

    # Standalone Home Manager wrapper.  This is independent from the
    # `homeManager.enable` integration switch: a caller may still expose
    # `homeConfigurations` without integrating Home Manager into the OS build.
    homeManagerConfigurationFn =
      if homeManagerConfiguration != null
      then homeManagerConfiguration
      else if inputs ? home-manager
      then inputs.home-manager.lib.homeManagerConfiguration
      else null;

    homeManagerNixosModuleFor = r:
      if !homeManagerEnabled
      then []
      else if effectiveHomeManagerUser == null
      then throw ''
        mulix: homeManager integration is enabled for NixOS, but no user was specified.
        Set `homeManager.user` (or the legacy `homeManagerUser`) in `configurations`.
      ''
      else if !(inputs ? home-manager)
      then throw ''
        mulix: homeManager integration is enabled, but `inputs.home-manager` is missing.
      ''
      else if !(inputs.home-manager ? nixosModules) || !(inputs.home-manager.nixosModules ? home-manager)
      then throw ''
        mulix: `inputs.home-manager.nixosModules.home-manager` is missing.
      ''
      else [{
        imports = [ inputs.home-manager.nixosModules.home-manager ];
        home-manager.useGlobalPkgs = homeManagerUseGlobalPkgs;
        home-manager.extraSpecialArgs = specialArgs // { inherit inputs; };
        home-manager.users.${effectiveHomeManagerUser}.imports =
          (r.targetModuleList "home") ++ extraHomeModules;
      }];

    homeManagerDarwinModuleFor = r:
      if !homeManagerEnabled
      then []
      else if effectiveHomeManagerUser == null
      then throw ''
        mulix: homeManager integration is enabled for nix-darwin, but no user was specified.
        Set `homeManager.user` (or the legacy `homeManagerUser`) in `configurations`.
      ''
      else if !(inputs ? home-manager)
      then throw ''
        mulix: homeManager integration is enabled, but `inputs.home-manager` is missing.
      ''
      else if !(inputs.home-manager ? darwinModules) || !(inputs.home-manager.darwinModules ? home-manager)
      then throw ''
        mulix: `inputs.home-manager.darwinModules.home-manager` is missing.
      ''
      else [{
        imports = [ inputs.home-manager.darwinModules.home-manager ];
        home-manager.useGlobalPkgs = homeManagerUseGlobalPkgs;
        home-manager.extraSpecialArgs = specialArgs // { inherit inputs; };
        home-manager.users.${effectiveHomeManagerUser}.imports =
          (r.targetModuleList "home") ++ extraHomeModules;
      }];

    _integratedHomeManagerCheck = builtins.seq _homeManagerShapeCheck true;

    # NixOS configurations (linux host のみ)
    nixosConfigurations = builtins.seq _integratedHomeManagerCheck
      (builtins.listToAttrs (lib.filter (x: x != null) (lib.mapAttrsToList (hostName: r:
      if isLinux r
      then {
        name = hostName;
        value = nixosSystemFn {
          system = r.host.system;
          modules = (r.targetModuleList "os") ++ [
            r.overlayModule
          ] ++ extraNixosModules ++ (homeManagerNixosModuleFor r);
          specialArgs = specialArgs // { inherit inputs; };
        };
      }
      else null
    ) rawPerHost)));

    # nix-darwin configurations (darwin host のみ)
    darwinConfigurations = builtins.seq _integratedHomeManagerCheck
      (builtins.listToAttrs (lib.filter (x: x != null) (lib.mapAttrsToList (hostName: r:
      if isDarwin r
      then {
        name = hostName;
        value = darwinSystemFn {
          system = r.host.system;
          modules = (r.targetModuleList "darwin") ++ [
            r.overlayModule
          ] ++ extraDarwinModules ++ (homeManagerDarwinModuleFor r);
          specialArgs = specialArgs // { inherit inputs; };
        };
      }
      else null
    ) rawPerHost)));

    # Home Manager standalone configurations (全 host)
    # homeManagerUser が指定された場合はそのユーザ名をキーに、
    # 省略時は host 名をキーにする
    homeConfigurations =
      if homeManagerConfigurationFn == null
      then {}
      else builtins.listToAttrs (lib.mapAttrsToList (hostName: r:
        let
          key = if effectiveHomeManagerUser != null then effectiveHomeManagerUser else hostName;
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
