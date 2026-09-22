# Top-level `pkgs` used inside an attrset fragment (the reported case).
{ mulib, pkgs, ... }:
mulib.module {
  name = "attrset-fragment";
  options.enable = mulib.bool.true;
  os = { out.tools = with pkgs; [ devenv lix.nix-init ]; };
}
