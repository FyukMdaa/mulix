{mulib, ...}:
mulib.host {
  name = "Inspiron14-5445";
  feat = ["preservation"];
  os = {out.preservation = true;};
}
