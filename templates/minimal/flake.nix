{
  description = "Minimal NixOS + Home Manager configuration using mulix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    mulix = {
      url = "github:fyukmdaa/mulix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    mulix,
    ...
  }: let
    lib = nixpkgs.lib;
    m = mulix.lib {inherit lib inputs;};

    cfgs = m.configurations {
      paths = [./hosts ./modules ./overlays];
      conditionNames = import ./conditionNames.nix;
      configNames = import ./configNames.nix {inherit lib;};
      specialArgs = {inherit inputs;};

      homeManager = {
        enable = true;
        user = "your_username";
        useGlobalPkgs = true;
      };
    };
  in {
    inherit (cfgs) nixosConfigurations homeConfigurations darwinConfigurations;
  };
}
