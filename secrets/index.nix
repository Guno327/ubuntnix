# secrets/index.nix — TEMPLATE, matching SPEC.md §8.1's own declared-index
# example almost verbatim (GitHub issue #79, milestone M4 groundwork). Left
# CLEAR (not git-crypt-encrypted) by secrets/.gitattributes — see that
# file's own comment, and docs/secrets.md's "Why index.nix is left clear",
# for the full rationale.
#
# This is a TEMPLATE, not this repository's own consumed declaration: a
# real installer-materialized `/flake/secrets/index.nix` (installer flow is
# milestone M7, out of scope for this issue) is imported by a real machine
# flake's own module, which feeds it to `nix/secrets.nix`'s
# `flake.lib.secrets.mkManifest` (see that file's header for the full
# declaration-surface contract this shape must satisfy: every referenced
# `src` file must actually exist as a sibling under `secrets/`, decrypted,
# by the time evaluation forces it). Nothing in the ubuntnix project's own
# flake imports this specific file today — `nix/secrets.nix`'s own
# `exampleManifest` continues to exercise the SAME declaration surface
# against its own fixture files under nix/example-secrets/ independently
# of this template (see that file's header) — so this file is free to stay
# a documentation-and-test fixture without adding a hidden dependency
# nix/secrets.nix or CI would need to satisfy.
#
# The three material files this template's own `src` fields name
# (pro-token, gunnar.key, api-token — SPEC.md §8.1's own example, minus
# wgKey for brevity) do NOT exist alongside this file in this repository:
# real secret material is never committed here, encrypted or otherwise
# (see docs/secrets.md — this is a TEMPLATE, not a working example with
# real bytes behind it). A real machine's own `/flake/secrets/` holds both
# this index AND the real (git-crypt-encrypted) material files it names.
{
  proToken = {
    src = ./pro-token;
    owner = "root";
    mode = "0400";
  };

  gunnarKey = {
    src = ./gunnar.key;
    owner = "gunnar";
    mode = "0400";
  };

  apiToken = {
    src = ./api-token;
    owner = "root";
    mode = "0400";
    environmentVariable = "API_TOKEN";
  };
}
