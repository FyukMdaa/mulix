# Shared constants and pure helpers for host fragment processing.
#
# This file owns the original `let` scope of `lib/hosts.nix`:
#   - field classification (`singleFields`, `listFields`, `listAliases`,
#     `configFields`, `allowedHostFields`);
#   - the `errors` import and small pure helpers used by every other
#     host sub-module (`parseSystem`, `systemFlags`, `typeNamesOf`,
#     `generatedIsNames`, `unionAcross`, `mkBoolUniverse`,
#     `fragmentLabel`, `quote`, `checkSendShape`).
#
# Splitting these into one self-contained file means the validation,
# composition, view, and sources sub-modules can each import exactly
# the names they need without re-deriving them.
{lib}: let
  errors = import ../errors.nix {inherit lib;};
  inherit (builtins) elem;

  # `type`, `feat`, and `role` names are intentionally unrestricted.  They are
  # separate input namespaces, while `host.is` is the generated flat condition
  # view.  A name may therefore legitimately occur in more than one namespace.

  # ---- host field classification --------------------------------------
  singleFields = ["system" "type"];
  listFields = ["feat" "role"];
  listAliases = {
    feat = ["feat" "features"];
    role = ["role" "roles"];
  };
  # Target fragments remain host-local configuration.  Cross-module values
  # are sent through the configName graph via `send`.  `shared` is therefore
  # intentionally not a host field anymore.
  configFields = ["os" "home" "darwin"];
  allowedHostFields =
    ["name"] ++ singleFields ++ listFields ++ ["features" "roles" "send"] ++ configFields;

  checkSendShape = context: position: value:
    if builtins.isAttrs value
    then value
    else
      throw ''
        mulix: invalid host definition
        location: ${context}${errors.formatLocation position}
        'send' must be an attrset mapping configName -> contribution,
        got: ${builtins.typeOf value}
      '';

  parseSystem = system: let
    parts = lib.splitString "-" system;
  in
    if builtins.length parts < 2
    then {
      arch = system;
      os = null;
    }
    else {
      arch = builtins.head parts;
      os = builtins.concatStringsSep "-" (builtins.tail parts);
    };

  systemFlags = host: let
    sys = parseSystem (host.system or "");
  in
    (lib.optional (sys.os == "linux") "linux")
    ++ (lib.optional (sys.os == "darwin") "darwin")
    ++ (lib.optional (sys.arch != "") sys.arch);

  typeNamesOf = host:
    if (host.type or null) != null
    then [host.type]
    else [];

  generatedIsNames = host:
    systemFlags host ++ typeNamesOf host ++ (host.roles or []) ++ (host.features or []);

  unionAcross = extract: hosts:
    lib.unique (lib.concatMap extract (builtins.attrValues hosts));

  mkBoolUniverse = universe: owned:
    builtins.listToAttrs (map
      (n: {
        name = n;
        value = elem n owned;
      })
      universe);

  # ---- source labels ---------------------------------------------------
  fragmentLabel = f:
    if (f.label or null) != null
    then f.label
    else if (f.source or null) != null
    then f.source
    else "(in-memory definition)";

  quote = v: builtins.toJSON v;
in rec {
  inherit
    errors
    singleFields
    listFields
    listAliases
    configFields
    allowedHostFields
    checkSendShape
    parseSystem
    systemFlags
    typeNamesOf
    generatedIsNames
    unionAcross
    mkBoolUniverse
    fragmentLabel
    quote
    ;
}
