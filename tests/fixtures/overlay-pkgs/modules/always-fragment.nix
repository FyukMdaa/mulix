{ mulib, ... }:
mulib.module {
  name = "always-fragment";
  options.enable = mulib.bool.false;
  always.os = { pkgs, ... }: { out.fromAlways = pkgs.lix.nix-init; };
}
