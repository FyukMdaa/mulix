# Replaces `lix` (a package) by a package SET, as overlays commonly do.
{ mulib, ... }:
mulib.overlay {
  name = "lix";
  overlay = final: prev: { lix = { nix-init = "nix-init-from-overlay"; }; };
}
