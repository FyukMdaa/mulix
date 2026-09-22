{mulib, ...}:
mulib.overlay {
  name = "example-packages";

  overlay = final: _prev: {
    mulix-hello = final.writeShellApplication {
      name = "mulix-hello";
      text = ''
        echo "hello from a mulix overlay"
      '';
    };
  };
}
