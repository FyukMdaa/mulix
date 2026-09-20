# Disabled on this host: it needs the `hyprland` feature.
{ host, mulib, ... }:
mulib.overlay {
  name = "fmnixpkgs";
  enable = [ host.feat.hyprland ];
  overlay = final: prev: { fm = "fm-overlay"; };
}
