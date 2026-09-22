{
  description = "mulix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
    ...
  }: let
    forAllSystems = nixpkgs.lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
  in {
    lib = import ./lib;

    templates.minimal = {
      path = ./templates/minimal;
      description = "Minimal NixOS + Home Manager configuration using mulix";
    };
  };
}
