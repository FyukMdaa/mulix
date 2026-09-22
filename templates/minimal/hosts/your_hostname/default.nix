{mulib, ...}:
mulib.host {
  # Host identity is determined by `name`, not by the directory name.
  name = "your_hostname";
  system = "x86_64-linux";
  type = "laptop";
  feat = [ "cli" "gui" ];
  role = [ "workstation" ];

  os = {
    nixpkgs.hostPlatform = "x86_64-linux";
    system.stateVersion = "26.05";
  };

  home = {
    home.stateVersion = "26.05";
  };

  # Host -> module override.  `myconfig` is bound to `mulix.modules`.
  send.force.myconfig = {
    tools.enable = true;
  };
}
