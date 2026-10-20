# Repeats `system` / `type` with the SAME values (allowed) and adds a feature.
{mulib, ...}:
mulib.host {
  name = "Inspiron14-5445";
  system = "x86_64-linux";
  type = "laptop";
  feat = ["amd"];
  os = {out.microcode = "amd";};
}
