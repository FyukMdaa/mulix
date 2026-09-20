{lib}: let
  # Best-effort source position. Nix does not expose source locations for every
  # evaluated value, so callers must treat null as "location unavailable".
  attrPos = attrs: name:
    if builtins.isAttrs attrs && builtins.hasAttr name attrs
    then builtins.unsafeGetAttrPos name attrs
    else null;

  formatPos = pos:
    if pos == null then null else
      let
        file = pos.file or null;
        line = pos.line or null;
        column = pos.column or null;
      in
        if file == null || line == null
        then null
        else "${toString file}:${toString line}${if column == null then "" else ":${toString column}"}";

  # Small, deterministic spelling suggestion helper. We deliberately only
  # suggest when the edit distance is unambiguously small enough.
  levenshtein = a: b: let
    aChars = lib.stringToCharacters a;
    bChars = lib.stringToCharacters b;
    bLen = builtins.length bChars;
    # `step` folds over the DP matrix built so far (a list of rows) and
    # appends the next row, computed from the previous row (`prev`).
    step = rows: i:
      let
        prev = builtins.elemAt rows (builtins.length rows - 1);
        ca = builtins.elemAt aChars i;
        row = lib.foldl'
          (
            r: j:
              let
                cb = builtins.elemAt bChars j;
                insertion = (builtins.elemAt r j) + 1;
                deletion = (builtins.elemAt prev (j + 1)) + 1;
                substitution =
                  (builtins.elemAt prev j)
                  + (if ca == cb then 0 else 1);
                cost = lib.min insertion (lib.min deletion substitution);
              in
                r ++ [cost]
          )
          [ (i + 1) ]
          (lib.range 0 (bLen - 1));
      in rows ++ [row];
    initial = [ (lib.range 0 bLen) ];
  in
    if a == b then 0
    else if aChars == [] then bLen
    else if bChars == [] then builtins.length aChars
    else
      let rows = lib.foldl' step initial (lib.range 0 (builtins.length aChars - 1));
      in
        builtins.elemAt
          (builtins.elemAt rows (builtins.length rows - 1))
          bLen;

  suggestionCandidates = value: candidates: let
    scored = map (candidate: {
      inherit candidate;
      distance = levenshtein value candidate;
    }) candidates;
    sorted = lib.sort (a: b:
      if a.distance == b.distance then a.candidate < b.candidate
      else a.distance < b.distance) scored;
  in
    if sorted == [] then []
    else let
      best = builtins.head sorted;
      limit = if builtins.stringLength value <= 4 then 1 else 2;
      nearest = builtins.filter (x: x.distance == best.distance) sorted;
      # Keep suggestions useful even when several names are equally close.
      # The result is deterministic because `sorted` uses the candidate name
      # as its tie-breaker.
    in
      if best.distance <= limit
      then map (x: x.candidate) (lib.take 3 nearest)
      else [];

  didYouMean = value: candidates: let
    suggestions = suggestionCandidates value candidates;
  in
    if suggestions == [] then ""
    else if builtins.length suggestions == 1
    then "\nhelp: did you mean `${builtins.head suggestions}`?"
    else "\nhelp: did you mean one of: ${lib.concatStringsSep ", " (map (x: "`${x}`") suggestions)}?";

  contextualHelp = lines:
    if lines == [] then ""
    else "\nhelp: ${lib.concatStringsSep "\n      " lines}";

  formatLocation = pos:
    let rendered = formatPos pos;
    in if rendered == null then "" else "\n  --> ${rendered}";

  invalidField = {module, field, allowed, position ? null, help ? []}:
    let
      suggestion = didYouMean field allowed;
    in throw ''
      mulix: invalid module definition
      module: ${module}${formatLocation position}
      unknown field: '${field}'
      allowed fields: ${lib.concatStringsSep ", " allowed}${suggestion}${contextualHelp help}
    '';

  missingField = {module, field, position ? null}:
    throw ''
      mulix: invalid module definition
      module: ${module}${formatLocation position}
      required field '${field}' is missing
    '';
in {
  inherit attrPos formatPos formatLocation didYouMean contextualHelp invalidField missingField;
}
