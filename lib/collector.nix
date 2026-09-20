{lib}: rec {
  /*
  module source の入力形式は2通りをサポートする:

    1. 明示的なリスト: `mulib.module` で明示的に包んだモジュール定義のリスト。
       この場合、与えられた順序をそのまま deterministic order とする。

    2. ディレクトリパス: `lib.filesystem` 相当で `*.nix` を列挙し、
       ファイル名でソートする (builtins.readDir は既に attrname で
       ソートされているため、追加ソートは冗長だが明示しておく)。
  */
  collectFromList = moduleDefs:
    lib.imap0 (index: def: {inherit index def; source = null; path = null; label = null;}) moduleDefs;

  # ---- shared file discovery -------------------------------------------
  #
  # Every directory walk in mulix goes through `listNixFiles`, so `modules =
  # ./dir` and `paths = [ ./dir ]` order and label files the same way.
  #
  #   recursive    descend into subdirectories
  #   defaultFirst inside a directory, `default.nix` comes before its siblings
  #                (a host directory's default.nix is its "base" fragment)
  #
  # Order (deterministic): a directory's files (default.nix first when
  # requested, then the rest sorted by name), then its subdirectories sorted
  # by name, each expanded in place.  Hidden entries (".git") and non-.nix
  # files are ignored.  Symlinks are followed.
  #
  # Each result: { path; label; dirName; } where
  #   label   = "<root dir name>/<relative path>"   e.g. "hosts/alpha/tpm2.nix"
  #   dirName = first subdirectory below the root ("alpha"), or null for a file
  #             sitting directly in the root
  # (`readDir` of the parent rather than `readFileType`: the latter needs Nix >= 2.14.)
  entryType = path:
    (builtins.readDir (dirOf path)).${baseNameOf (toString path)};

  listNixFiles = {
    root,
    recursive ? false,
    defaultFirst ? false,
  }: let
    rootName = baseNameOf (toString root);
    walk = dir: rel: let
      entries = builtins.readDir dir;
      visible = lib.filterAttrs (name: _: !(lib.hasPrefix "." name)) entries;
      # `readDir` does not follow symlinks: a symlink named *.nix is a file
      # (as it always was here); other symlinks are not descended into.
      typeOf = name: visible.${name};
      isNixFile = name:
        lib.hasSuffix ".nix" name
        && (typeOf name == "regular" || typeOf name == "symlink");
      files =
        builtins.sort
        (a: b:
          if defaultFirst && a == "default.nix" && b != "default.nix" then true
          else if defaultFirst && b == "default.nix" && a != "default.nix" then false
          else a < b)
        (builtins.filter isNixFile (builtins.attrNames visible));
      dirs =
        builtins.filter
        (name: typeOf name == "directory")
        (builtins.attrNames visible);
      fileEntry = name: {
        path = dir + "/${name}";
        label = "${rootName}/${rel}${name}";
        dirName =
          if rel == ""
          then null
          else builtins.head (lib.splitString "/" rel);
      };
    in
      map fileEntry files
      ++ lib.optionals recursive
      (lib.concatMap (d: walk (dir + "/${d}") "${rel}${d}/") dirs);
  in
    walk root "";

  # `modules = ./dir` (legacy): flat, alphabetical, every file is a module.
  collectFromDir = dir:
    lib.imap0
    (index: e: {
      inherit index;
      inherit (e) path label;
      def = import e.path;
      source = toString e.path;
    })
    (listNixFiles {root = dir; recursive = false; defaultFirst = false;});

  # `paths = [ ./hosts ./modules ./overlays ]`: recursive discovery.  A path may
  # also name a single .nix file.  Entries are classified later (module / host /
  # overlay) from the descriptor each file returns.
  collectPaths = paths:
    lib.concatMap
    (root:
      if entryType root != "directory"
      then [{
        path = root;
        label = baseNameOf (toString root);
        dirName = null;
      }]
      else listNixFiles {inherit root; recursive = true; defaultFirst = true;})
    paths;

  /*
  collected: [{ index; def; }] を受け取り、各 def を評価コンテキストで
  呼び出して `mulib.module` descriptor を取り出しつつ、
  重複 module name を検査する。

  def が function の場合は normalizer 側の callModule 経由で呼び出す。
  評価結果は `mulib.module` が付与した内部 descriptor marker を必須とする。

  ここでは "name" だけを先に取得する必要があるため、function module は
  引数なしで安全に name を取り出せないケースがある。そのため mulix の
  module function は `name` を top-level attrset のキーとして持つのでは
  なく、function 自体が呼び出された結果の attrset に `name` を持つ
  という前提を置いている。

  -> したがって name の重複検査は "呼び出し可能な最小限の引数" で
     一度評価してから行う。呼び出しに必要な引数一式は normalizer が
     持っているため、collector は normalizer 経由で呼ばれる
     `collectAndCheck` を提供する。
  */
  collectAndCheck = callModule: collected: let
    sourceLabel = c:
      if (c.source or null) == null
      then ""
      else " [source: ${c.source}]";
    resolved = map (c: let
      # `def` is the raw module definition (attrset or function).  Only the
      # result of callModule is stored as `mod`; the function itself must
      # never cross the normalized-module boundary.
      evaluatedMod = callModule c;
      mod = evaluatedMod;
    in
      if !builtins.isAttrs mod
      then
        throw ''
          mulix: invalid module shape
          module at collection index ${toString c.index}${sourceLabel c}
          expected a mulib.module descriptor after module evaluation, got: ${builtins.typeOf mod}
          Wrap the module definition in 'mulib.module { ... }'.
        ''
      else if (mod._mulixKind or null) != "module"
      then
        throw ''
          mulix: invalid module shape
          module at collection index ${toString c.index}${sourceLabel c}
          expected a mulib.module descriptor.
          Wrap the module definition in 'mulib.module { ... }' instead of returning a raw attrset.
        ''
      else c // {inherit mod;}) collected;

    names = map (c:
      if !(c.mod ? name)
      then throw ''
        mulix: invalid module shape
        module at collection index ${toString c.index}${sourceLabel c} has no 'name'
      ''
      else c.mod.name)
    resolved;

    # Names that occur more than once, in order of first appearance.
    # Counted with one grouping pass: counting per name would rescan every name
    # (O(N^2)).  Only strings are grouped; a non-string name is reported by the
    # module-shape check in normalizeModule ("'name' must be a string").
    nameGroups = builtins.groupBy (n: n) (builtins.filter builtins.isString names);
    dupNames = lib.unique (
      builtins.filter
      (n: builtins.isString n && builtins.length nameGroups.${n} > 1)
      names
    );
  in
    if dupNames != []
    then
      throw ''
        mulix: duplicate module name(s): ${builtins.concatStringsSep ", " dupNames}
        modules sharing a name:
          ${lib.concatStringsSep "\n  " (map (c: "- ${c.mod.name}${sourceLabel c}") (builtins.filter (c: builtins.elem c.mod.name dupNames) resolved))}
        (There must not be multiple modules with the same name within the same collection)
      ''
    else resolved;
}
