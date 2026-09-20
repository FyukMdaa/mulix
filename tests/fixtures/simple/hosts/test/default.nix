{ mulib, ... }:
mulib.host { name = "test"; system = "x86_64-linux"; type = "desktop"; os = { out.fromDefault = 1; }; }
