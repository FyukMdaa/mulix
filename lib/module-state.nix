{lib}: let
  errors = import ./errors.nix {inherit lib;};

  # ---- which module states does a module read? --------------------------
  #
  # `myconfig` is just `config.mulix.modules`.  Nix cannot report which
  # attributes of a value were forced, so the dependency graph is built from
  # the *source text* of the module (when it came from a file):
  #
  #     myconfig.constants.username      ->  reads "constants"
  #     myconfig."my-module".x           ->  reads "my-module"
  #
  # Line comments are stripped first.  Inference is deliberately conservative
  # about what it accepts (only `myconfig.<name>` spellings) and is a static
  # over/under-approximation like every module-level edge in mulix:
  #
  #   * aliases (`let mc = myconfig; in mc.x`) and `myconfig.${dynamic}` are not seen;
  #   * a module made of several files is scanned in its main file only.
  #
  # A module can state its reads explicitly (`reads = [ "constants" ];`).  An
  # explicit list is authoritative: inference is not used for that module, so
  # it is also the escape hatch for any false positive / false negative.
  stripLineComments = text:
    lib.concatStrings (builtins.filter builtins.isString (builtins.split "#[^\n]*" text));

  matchesOf = re: text:
    map (m: builtins.elemAt m 1) (builtins.filter builtins.isList (builtins.split re text));

  prefixRe = "(^|[^A-Za-z0-9_'.-])";
  identRe = "${prefixRe}myconfig\\.([A-Za-z_][A-Za-z0-9_'-]*)";
  quotedRe = "${prefixRe}myconfig\\.\"([^\"]+)\"";

  inferReads = text: let
    clean = stripLineComments text;
  in
    lib.unique (matchesOf identRe clean ++ matchesOf quotedRe clean);

  # normalized module -> { names; explicit; }
  readsOf = mod:
    if (mod.reads or null) != null
    then {
      names = lib.unique mod.reads;
      explicit = true;
    }
    else if (mod.sourcePath or null) != null
    then {
      names = inferReads (builtins.readFile mod.sourcePath);
      explicit = false;
    }
    else {
      names = [];
      explicit = false;
    };
in rec {
  inherit inferReads readsOf;

  # An explicit `reads` naming a module that does not exist is a plain mistake.
  checkExplicitReads = modules: let
    names = map (m: m.name) modules;
    bad =
      lib.concatMap
      (mod: let
        r = readsOf mod;
      in
        if r.explicit
        then map (n: {module = mod.name; read = n;}) (builtins.filter (n: !(builtins.elem n names)) r.names)
        else [])
      modules;
  in
    if bad != []
    then
      throw ''
        mulix: myconfig reads an unknown module
        ${lib.concatStringsSep "\n" (map (b: "- module '${b.module}' reads '${b.read}'\n  ${errors.didYouMean b.read names}") bad)}
        (declared with `reads`; module names: ${builtins.concatStringsSep ", " names})
      ''
    else true;

  # Inferred reads that name no module (reported by diagnostics; never fatal,
  # because inference is textual).
  unknownInferredReads = modules: let
    names = map (m: m.name) modules;
  in
    lib.concatMap
    (mod: let
      r = readsOf mod;
    in
      if r.explicit
      then []
      else map (n: {module = mod.name; read = n; source = mod.source or null;}) (builtins.filter (n: !(builtins.elem n names)) r.names))
    modules;

  # Data-flow orientation, like configName edges: the module whose state is
  # read is the provider (`from`), the reader is the consumer (`to`).  This is
  # what lets one cycle check cover configName and module-state edges
  # together.  A module reading its own state is normal and is not an edge.
  moduleStateEdges = modules: let
    names = map (m: m.name) modules;
  in
    lib.concatMap
    (mod:
      map
      (n: {
        from = n;
        to = mod.name;
        via = "module-state";
        kind = "module-state";
      })
      (builtins.filter (n: n != mod.name && builtins.elem n names) (readsOf mod).names))
    modules;
}
