# A send FUNCTION gets the same pkgs.
{mulib, ...}:
mulib.module {
  name = "sender";
  options.enable = mulib.bool.true;
  send.pkgNames = {pkgs, ...}: [pkgs.lix.nix-init];
}
