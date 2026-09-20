# A function fragment: `pkgs` comes from the module system, `host` from mulix.
{ mulib, ... }:
mulib.host {
  name = "Inspiron14-5445";
  os = { pkgs, host, ... }: {
    out.initrd = "${pkgs.marker}-${host.name}";
  };
}
