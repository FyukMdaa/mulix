{ mulib, ... }:
mulib.host {
  name = "Inspiron14-5445";
  feat = [ "secureboot" ];
  os = { out.secureboot = true; };
}
