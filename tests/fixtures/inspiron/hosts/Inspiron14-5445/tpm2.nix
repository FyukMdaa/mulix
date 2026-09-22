{ mulib, ... }:
mulib.host {
  name = "Inspiron14-5445";
  feat = [ "tpm2" ];
  os = { out.tpm2 = true; };
}
