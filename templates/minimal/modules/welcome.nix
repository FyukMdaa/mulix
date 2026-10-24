{packageNames, mulib, ...}:
mulib.module {
  name = "welcome";

  options.enable = mulib.bool.true;

  home = { ... }: {
    # `packageNames` is a configName receiver.
    home.file.".config/mulix-package-names".text =
      builtins.concatStringsSep "\\n" packageNames;
  };
}
