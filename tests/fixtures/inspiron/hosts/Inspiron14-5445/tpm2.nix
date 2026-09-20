{ mulib, ... }:
mulib.host {
  name = "Inspiron14-5445";
  feat = [ "tpm2" ];
  os = { out.tpm2 = true; };
  # `shared` applies to every target (os / home / darwin).
  shared = { out.sharedFromTpm2 = true; };
}
