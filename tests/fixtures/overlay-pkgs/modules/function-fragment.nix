# A fragment written as a function that asks for `pkgs`.
{mulib, ...}:
mulib.module {
  name = "function-fragment";
  options.enable = mulib.bool.true;
  os = {pkgs, ...}: {out.fromFunction = pkgs.lix.nix-init;};
}
