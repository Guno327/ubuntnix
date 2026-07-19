# nix/ubx.nix — flake-facing metadata for the on-device `ubx` CLI
# (SPEC.md §4.5; §2 G8 dendritic layout: one file per feature).
#
# Pure attribute data only, kept in lockstep with bin/ubx: the subcommand
# list here is checked against `ubx --help`'s output by
# tests/unit/020-ubx-cli.sh, so the flake and the CLI script can't
# silently drift apart.
#
# What is deliberately NOT declared here (issue #5 is skeleton-only):
#   - a "system modules" / "home modules" output class (SPEC.md §6
#     primitives, §9 home config) — these land with the milestones that
#     give them something real to compose (M2 onward). An empty
#     placeholder attrset today would be a fake output with nothing
#     behind it.
#   - any packages output — this project builds nothing via the ordinary
#     Nix package-building path; a from-scratch, Ubuntu-native build
#     mechanism is issue #6's job, not this one's.
#   - a formatter output — same reasoning: nothing to format things with
#     yet that isn't the very thing we're forbidden from using.
{ ... }:
{
  flake.lib.ubx = {
    subcommands = [ "rebuild" "rollback" "list-generations" "diff" "update" ];
    rebuildVerbs = [ "switch" "boot" "test" ];
  };
}
