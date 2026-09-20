{ host, mulib, ... }:
mulib.overlay {
  name = "emacs";
  enable = [ host.feat.gui ];
  overlay = final: prev: { emacs = "emacs-overlay"; };
}
