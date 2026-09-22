# gui AND (niri OR hyprland)
{
  host,
  mulib,
  ...
}:
mulib.module {
  name = "graphics";
  options.enable = [host.feat.gui [host.feat.niri host.feat.hyprland]];
  os = {out.graphics = true;};
}
