{mulib, ...}:
mulib.module {
  name = "system";

  options = {
    enable = mulib.bool.true;
    username = mulib.str "your_username";
    timezone = mulib.str "Asia/Tokyo";
  };

  os = {opt, ...}: {
    time.timeZone = opt.timezone;

    users.users.${opt.username} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
    };
  };

  home = {opt, ...}: {
    home.username = opt.username;
    home.homeDirectory = "/home/${opt.username}";
    home.stateVersion = "26.05";
  };
}
