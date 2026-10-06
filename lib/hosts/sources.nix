# Source attribution and graph edges for hosts.
#
# This file owns the parts of `lib/hosts.nix` that surface where each
# piece of a composed host came from:
#   - `formatSources`  - the diagnostics text block (used by `lib/diagnostics.nix`)
#   - `sourceEdges`    - DOT/Mermaid edges from fragment files to the host
#
# Dependency injection: needs `quote` from `./constants.nix`.
{lib}: let
  constants = import ./constants.nix {inherit lib;};
  inherit (constants) quote;
in rec {
  formatSources = host: let
    line = c: "      ${quote c.value}  <-  ${c.source}";
    section = title: cs:
      if cs == []
      then []
      else ["    ${title}:"] ++ map line cs;
  in
    lib.concatStringsSep "\n"
    ([
        "  ${host.name}"
        "    fragments:"
      ]
      ++ map (f: "      ${f.source}") host.sources.fragments
      ++ section "system" host.sources.system
      ++ section "type" host.sources.type
      ++ section "feat" host.sources.feat
      ++ section "role" host.sources.role);

  # Edges (fragment file --field--> host) for graphLib.toMermaid / toDot.
  sourceEdges = composed:
    lib.concatMap
    (name: let
      host = composed.${name};
      fieldEdges = field:
        map
        (c: {
          from = c.source;
          to = host.name;
          via = "${field}:${toString c.value}";
          kind = "host-source";
        })
        host.sources.${field};
      fragmentEdges =
        map
        (f: {
          from = f.source;
          to = host.name;
          via = "fragment";
          kind = "host-source";
        })
        host.sources.fragments;
    in
      fragmentEdges ++ lib.concatMap fieldEdges ["system" "type" "feat" "role"])
    (builtins.attrNames composed);

}
