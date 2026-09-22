# Reads the complete module-options view through the explicitly bound `hostconf` configName.
{mulib, ...}:
mulib.module {
  name = "git";
  options.enable = mulib.bool.true;
  home = {hostconf, ...}: {
    out.gitUser = hostconf.constants.username;
  };
}
