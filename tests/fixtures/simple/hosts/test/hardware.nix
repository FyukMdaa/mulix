{ mulib, ... }:
mulib.host { name = "test"; feat = [ "amd" ]; os = { out.fromHardware = 1; }; }
