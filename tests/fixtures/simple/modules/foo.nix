{mulib, ...}:
mulib.module {
  name = "foo";
  options.enable = mulib.bool.true;
  os = {out.foo = 1;};
}
