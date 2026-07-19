# nix/stdenv.nix — the Ubuntu-native stdenv bootstrap (SPEC.md §4.1;
# GitHub issue #6, milestone M1).
#
# Per SPEC.md §1.3 / §3, ubuntnix consumes nixpkgs as a pure source library
# ONLY — no nixpkgs package, builder, or fetcher, ever. But composing Ubuntu
# itself needs build tools (dpkg, tar, bash, coreutils, ...), and those must
# themselves be Canonical's, not nixpkgs'. This file is the ONE place in the
# whole tree that reaches outside pinned flake inputs to fetch third-party
# bytes: Canonical's `ubuntu-base` rootfs tarball, "the only trust root
# besides Nix itself" (SPEC.md §4.1 step 1).
#
# -- Trust root --------------------------------------------------------------
#
# Retrieved 2026-07-19 by browsing the official Ubuntu cdimage release
# listing (plain `wget`, no browser/JS involved):
#   https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/
# which today resolves the "24.04" alias to the 24.04.4 point-release spin
# (24.04 is periodically re-spun; this pin locks to that specific spin's
# amd64 tarball, not the "24.04" alias, so the pin never silently moves
# under us). The published `SHA256SUMS` at that same URL lists:
#   c1e67ef7b17a6300e136118bd1dc04725009cb376c1aad10abcf8cd453628d58  ubuntu-base-24.04.4-base-amd64.tar.gz
# and downloading the ~30MB tarball and running `sha256sum` on it
# independently reproduced that identical digest. That independently
# reproduced digest is `sha256` below, and it is what Nix actually verifies
# on every fetch (the published SHA256SUMS file is only corroborating
# evidence, not what we trust).
#
# -- Bootstrap: the "no tar to unpack the tarball with" problem -------------
#
# `tarball` below is a plain fixed-output fetch (`builtins.fetchurl` — a Nix
# LANGUAGE PRIMITIVE, not a nixpkgs fetcher; see tests/unit/021-flake-
# purity.sh's deliberate `builtins.fetchurl` carve-out) of the flat file,
# hash-verified against the digest derived ourselves above. It exists as the
# independently-auditable trust anchor, but nothing in a Nix sandbox can
# unpack a .tar.gz — there's no `tar`, and the only `tar` we'd be allowed to
# trust is the one INSIDE this very tarball. Chicken, meet egg.
#
# The escape hatch (SPEC.md §4.1 step 1 "escape hatches", option (a) from
# the issue #6 task notes): `builtins.fetchTarball` unpacks gzipped tarballs
# at EVAL TIME using Nix's own internal decompression/unpack code — no
# `tar`, no nixpkgs, nothing but Nix itself. `unpacked` below fetches the
# exact same URL a second time, this time through fetchTarball, giving us an
# already-unpacked store path with no external tool involved anywhere.
#
# `fetchTarball`'s `sha256` is the hash of the UNPACKED NAR — a different
# value from the flat-file `sha256` above by construction (it hashes a
# decompressed, unpacked file tree, not raw .tar.gz bytes) — and there is no
# way to compute it without a working `nix` binary, which this development
# environment does not have (see CONTRIBUTING/task notes). `unpackedSha256`
# below is therefore an intentionally-wrong 64-zero placeholder.
#
# PM ACTION REQUIRED (first CI run only): CI's "flake" job will fail
# evaluating `packages.x86_64-linux.stdenv-proof` (which forces `unpacked`)
# with a Nix hash-mismatch error of the shape
#   error: hash mismatch in fixed-output derivation ...
#     specified: sha256:0000000000000000000000000000000000000000000000000000000000000000
#     got:       sha256:<the real hash>
# Copy the "got:" hash into `unpackedSha256` below (either form Nix accepts
# — plain 64-hex or the `sha256:...`/SRI form — works) and push. From then
# on this pin is permanent; it only moves again if `version`/`arch`/`url`
# above change (e.g. a future point-release bump).
{ ... }:
let
  ubuntuBase = rec {
    version = "24.04.4";
    arch = "amd64";
    fileName = "ubuntu-base-${version}-base-${arch}.tar.gz";
    url = "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/${fileName}";

    # Flat-file sha256 (hex, as emitted by `sha256sum`) — see "Trust root"
    # above. Independently verified against Canonical's own published
    # SHA256SUMS at the same URL.
    sha256 = "c1e67ef7b17a6300e136118bd1dc04725009cb376c1aad10abcf8cd453628d58";

    # The audited trust-root fetch. Nothing downstream consumes it directly
    # (see "Bootstrap" above for why the tarball itself is unusable as a
    # build input in-sandbox) — its purpose is to be the independently
    # hash-verifiable artifact that provenance-matches `unpacked` below
    # (identical `url`, hence necessarily identical bytes).
    tarball = builtins.fetchurl { inherit url sha256; };

    # PLACEHOLDER — see "PM ACTION REQUIRED" above. Deliberately wrong so
    # CI's first run reports the real value in its error message.
    unpackedSha256 = "0000000000000000000000000000000000000000000000000000000000000000";

    # The actual bootstrap primitive: an unpacked ubuntu-base rootfs tree,
    # obtained with no external tools whatsoever (see "Bootstrap" above).
    unpacked = builtins.fetchTarball { inherit url; sha256 = unpackedSha256; };
  };

  # Verified against this tarball's own listing (`tar tzvf`, 2026-07-19):
  #   - `/lib`, `/lib64`, `/bin`, `/sbin` are top-level *symlinks* into
  #     `usr/`, e.g. `lib64 -> usr/lib64`. They're RELATIVE symlinks, so
  #     they survive the unpack (Nix's store preserves symlinks verbatim;
  #     it's only relative targets that are guaranteed safe here, and every
  #     one of ubuntu-base's top-level symlinks is relative).
  #   - The dynamic loader is nonetheless referenced below by its REAL path
  #     rather than through the `/lib64` symlink chain, to avoid depending
  #     on that resolution at all:
  #       usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2   (real file)
  #     (`usr/lib64/ld-linux-x86-64.so.2` is itself only a symlink to the
  #     above; `usr/bin/ld.so` a symlink to lib64's copy.)
  #   - `bash` and `dpkg` both link only against libs present directly in
  #     `usr/lib/x86_64-linux-gnu/` (`libc.so.6`, `libtinfo.so.6` for bash;
  #     `libc.so.6`, `libmd.so.0`, `libselinux.so.1` for dpkg) — checked
  #     with `readelf -d`. A single `--library-path` directory covers both,
  #     and this exact sequence (direct ld.so invocation, `--library-path`
  #     into this one directory, then `bash <script>`) was smoke-tested
  #     outside Nix against the downloaded+unpacked tarball before being
  #     encoded here, and both `bash --version` and `dpkg --version` ran
  #     successfully.
  ld = "${ubuntuBase.unpacked}/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2";
  libraryPath = "${ubuntuBase.unpacked}/usr/lib/x86_64-linux-gnu";
  bashPath = "${ubuntuBase.unpacked}/usr/bin/bash";
  binPath = "${ubuntuBase.unpacked}/usr/bin:${ubuntuBase.unpacked}/usr/sbin";

  # runInUbuntuBase — the builder abstraction (issue #6 task item 2).
  #
  # Produces a `builtins.derivation` (never nixpkgs' stdenv-based derivation
  # helper — see tests/unit/021-flake-purity.sh) whose builder is
  # ubuntu-base's own dynamic loader (`ld-linux-x86-64.so.2`), invoked
  # directly with `--library-path` pointed into the unpacked tree, which in
  # turn execs `bash <script>`. This sidesteps the Nix build sandbox having
  # no `/lib`, `/lib64`, or ld cache of its own, and ubuntu-base's binaries
  # being dynamically linked against absolute FHS paths that don't exist in
  # the sandbox: nothing here relies on the sandbox root at all — every
  # path involved is an explicit absolute Nix store path.
  #
  # `PATH` is set into the unpacked tree so `script` can call ubuntu-base
  # binaries (dpkg, coreutils, ...) by bare name.
  #
  # HARDENING NOTE (documented per issue #6 task item 2; follow-up is issue
  # #9): this is a raw ld.so invocation, not a chroot/namespace sandbox —
  # the script can still see the outer filesystem beyond whatever isolation
  # Nix's own build sandbox already provides; nothing here additionally
  # confines it to the ubuntu-base tree as `/`. A proper `unshare`-based
  # chroot into `ubuntuBase.unpacked` is the follow-up hardening step for
  # the composition work in issue #9. This bootstrap derivation only needs
  # to prove ubuntu-base binaries can run at all under Nix, which it does.
  runInUbuntuBase =
    { name
    , script
    , system ? "x86_64-linux"
    , env ? { }
    }:
    let
      scriptFile = builtins.toFile "${name}.sh" ''
        set -euo pipefail
        ${script}
      '';
    in
    builtins.derivation (env // {
      inherit name system;
      builder = ld;
      args = [ "--library-path" libraryPath bashPath scriptFile ];
      PATH = binPath;
    });
in
{
  # Exposed under flake.lib (option declared once, in nix/lib.nix; every
  # dendritic file just contributes its own named attribute — same pattern
  # nix/ubx.nix uses for flake.lib.ubx).
  flake.lib.stdenv = { inherit ubuntuBase runInUbuntuBase; };

  # A real derivation now exists, so the per-system wiring issue #5 left
  # unwired (nix/ubx.nix's header comment) is minimally switched on: one
  # system, no more, no less than the amd64 tarball we pinned above covers.
  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }: {
    # Proof derivation (issue #6 task item 3): runs `dpkg --version` and
    # `bash --version` from inside the bootstrapped ubuntu-base
    # environment and writes both, plus a fixed marker, into $out.
    # Deterministic by construction — no timestamps, no host-dependent
    # data: just a literal marker plus two Canonical binaries' own
    # `--version` output, which is fixed for a fixed ubuntu-base pin.
    # CI's "flake" job (.github/workflows/ci.yml) builds this and asserts
    # on both the marker and a dpkg version string appearing in $out; that
    # build IS the end-to-end test for this bootstrap (tests/unit/030
    # only checks the static wiring, since this harness has no `nix`).
    packages.stdenv-proof = runInUbuntuBase {
      inherit system;
      name = "stdenv-proof";
      script = ''
        {
          echo "MARKER=ubuntnix-stdenv-proof-v1"
          echo "ubuntu-base=${ubuntuBase.version}-${ubuntuBase.arch}"
          echo "== dpkg --version =="
          dpkg --version
          echo "== bash --version =="
          bash --version
        } > "$out"
      '';
    };
  };
}
