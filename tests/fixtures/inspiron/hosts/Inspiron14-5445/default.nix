# Identity + base of the host.  Every other file in this directory is another
# fragment of the SAME host: they are merged by `name`.
{ mulib, ... }:
mulib.host {
  name = "Inspiron14-5445";
  system = "x86_64-linux";
  type = "laptop";
  feat = [ "gui" "niri" ];
  role = [ "desktop" ];
  os = { out.hostname = "inspiron"; };
}
