{ mulib, ... }:
mulib.module {
  name = "constants";
  options = {
    enable = mulib.bool.true;
    username = mulib.str "alice";
    timezone = mulib.str "Asia/Tokyo";
  };
}
