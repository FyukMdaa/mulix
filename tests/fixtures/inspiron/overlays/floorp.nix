{mulib, ...}:
mulib.overlay {
  name = "floorp";
  overlay = final: prev: {floorp = "floorp-overlay";};
}
