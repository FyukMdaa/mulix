# Lives in hosts/alpha/ but declares host "beta".
{mulib, ...}:
mulib.host {
  name = "beta";
  system = "x86_64-linux";
}
