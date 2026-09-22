{mulib, ...}:
mulib.module {
  name = "tools";

  options.enable = mulib.bool.false;

  os = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      curl
      git
      ripgrep
    ];
  };

  home = {pkgs, ...}: {
    home.packages = with pkgs; [
      fd
      jq
    ];
  };

  # Demonstrates a normal cross-module contribution.
  send.packageNames = [ "curl" "git" "ripgrep" "fd" "jq" ];
}
