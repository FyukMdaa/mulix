# Sorts BEFORE default.nix alphabetically.
{ mulib, ... }: mulib.host { name = "alpha"; feat = [ "gui" ]; }
