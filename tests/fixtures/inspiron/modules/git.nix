# Reads another module's state through `myconfig`; no configName is declared.
{ mulib, ... }:
mulib.module {
  name = "git";
  options.enable = mulib.bool.true;
  home = { myconfig, ... }: {
    out.gitUser = myconfig.constants.username;
  };
}
