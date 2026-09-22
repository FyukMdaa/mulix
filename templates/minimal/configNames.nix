{lib, ...}: {
  # The complete module-option view.
  # This is useful for host send.force overrides.
  myconfig = {
    bind = "mulix.modules";
  };

  # Example of a normal cross-module data channel.
  packageNames = {
    type = lib.types.listOf lib.types.str;
    merge = "ordered";
    default = [];
  };
}
