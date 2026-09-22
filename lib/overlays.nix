{lib}: let
  descriptor = context: def:
    if !builtins.isAttrs def
    then
      throw ''
        mulix: invalid overlay shape
        overlay: ${context}
        expected a mulib.overlay descriptor, got: ${builtins.typeOf def}
      ''
    else if (def._mulixKind or null) != "overlay"
    then
      throw ''
        mulix: invalid overlay shape
        overlay: ${context}
        expected a mulib.overlay descriptor.
        Wrap the overlay in 'mulib.overlay { name = ...; overlay = final: prev: { ... }; }'.
      ''
    else true;

  allowedFields = ["name" "overlay" "enable"];
in rec {
  /*
  mulib.overlay { name = "floorp"; overlay = final: prev: { ... }; }

    name     identity (unique among overlays)
    overlay  a nixpkgs overlay: final: prev: { ... }
    enable   optional; a bool or a condition list like a module's
             `options.enable` (top-level AND, nested lists OR).  Default: true.
             Evaluated statically, so it can use `host.*` but not module state.
  */
  mkOverlay = def:
    if !builtins.isAttrs def
    then throw "mulix: mulib.overlay expects an attrset, got ${builtins.typeOf def}"
    else let
      context = def.name or "<unnamed>";
      unknown = builtins.filter (f: !(builtins.elem f allowedFields)) (builtins.attrNames def);
      checks =
        if unknown != []
        then
          throw ''
            mulix: invalid overlay definition
            overlay: ${context}
            unknown field: ${builtins.concatStringsSep ", " (map (f: "'${f}'") unknown)}
            allowed fields: ${builtins.concatStringsSep ", " allowedFields}
          ''
        else if !(def ? name) || !(builtins.isString def.name) || def.name == ""
        then
          throw ''
            mulix: invalid overlay shape
            required field 'name' must be a non-empty string
          ''
        else if !(def ? overlay) || !(lib.isFunction def.overlay)
        then
          throw ''
            mulix: invalid overlay shape
            overlay: ${context}
            field 'overlay' must be a function (final: prev: { ... }), got: ${
              if def ? overlay
              then builtins.typeOf def.overlay
              else "nothing"
            }
          ''
        else if def ? enable && !(builtins.isBool def.enable || builtins.isList def.enable)
        then
          throw ''
            mulix: invalid overlay shape
            overlay: ${context}
            field 'enable' must be a bool or a condition list, got: ${builtins.typeOf def.enable}
          ''
        else true;
    in
      builtins.seq checks (def // {_mulixKind = "overlay";});

  /*
  resolve: descriptors ([{ def; label; }] in collection order) -> the overlays
  to apply.  Rejects duplicate names, evaluates `enable`.
  */
  resolve = {
    entries,
    conditionValue,
  }: let
    names = map (e: e.def.name) entries;
    groups = builtins.groupBy (n: n) names;
    dups = lib.unique (builtins.filter (n: builtins.length groups.${n} > 1) names);
    checked = map (e: builtins.seq (descriptor e.label e.def) e) entries;
    isEnabled = e: let
      enable = e.def.enable or true;
    in
      if builtins.isBool enable
      then enable
      else conditionValue "overlay '${e.def.name}'.enable" enable;
    enabled = builtins.filter isEnabled checked;
  in
    if dups != []
    then
      throw ''
        mulix: duplicate overlay name(s): ${builtins.concatStringsSep ", " dups}
        overlays sharing a name:
          ${lib.concatStringsSep "\n  " (map (e: "- ${e.def.name} [source: ${e.label}]") (builtins.filter (e: builtins.elem e.def.name dups) entries))}
      ''
    else {
      overlays = map (e: e.def.overlay) enabled;
      byName = builtins.listToAttrs (map (e: {
          name = e.def.name;
          value = e.def.overlay;
        })
        enabled);
      names = map (e: e.def.name) enabled;
    };
}
