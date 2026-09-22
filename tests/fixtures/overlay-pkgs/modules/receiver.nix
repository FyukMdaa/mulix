{mulib, ...}:
mulib.module {
  name = "receiver";
  options.enable = mulib.bool.true;
  os = {pkgNames, ...}: {out.pkgNames = pkgNames;};
}
