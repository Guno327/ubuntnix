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
# independently-auditable trust anchor, but nothing in the Nix build sandbox
# can unpack a .tar.gz — there's no `tar` in there, and the only `tar` we'd
# be allowed to trust is the one INSIDE this very tarball. Chicken, meet egg.
#
# FIRST ATTEMPT, RULED OUT: `builtins.fetchTarball` unpacks gzipped tarballs
# at eval time with no external `tar` — but it turns out to REQUIRE a single
# top-level directory (the GitHub-tarball-style shape). `ubuntu-base`'s
# tarball is a bare rootfs (`bin`, `etc`, `usr`, ... all at the top level),
# which fails eval with "tarball ... contains an unexpected number of
# top-level files" (confirmed against real CI: GitHub Actions run
# 29705143141). This primitive is therefore structurally unusable for this
# specific tarball shape, however useful it is elsewhere.
#
# THE APPROACH USED INSTEAD: `unpacked` below is a derivation whose builder
# is the HOST's own `/bin/sh` (+ `tar`), run with `__noChroot = true` so it
# can see the outer filesystem, and pinned as a fixed-output derivation
# (`outputHashMode = "recursive"`, a NAR-style hash of the whole unpacked
# tree — the same *kind* of hash `fetchTarball` would have produced, just
# computed by our own tiny derivation instead of a builtin). This is the
# ONE deliberate, contained crossing of "no non-Canonical build tools": the
# host `sh`/`tar` doing the unpacking come from the Ubuntu archive on every
# environment this is ever built in (the CI runner is `ubuntu-24.04`; `nix`
# itself is installed from the archive per SPEC.md §1.3; a future on-device
# build per SPEC.md §4.5 runs on Ubuntu natively too) — so in every case
# that host `tar` is itself Canonical's, same as everything else in this
# project. And because the OUTPUT is hash-pinned exactly like any other
# fixed-output fetch, whatever produced it is irrelevant to reproducibility
# after the fact: a hash mismatch fails the build the same way a corrupted
# download would. The impurity is contained exactly like a fetch, not
# smuggled in as an ordinary (unpinned) build step.
#
# `outputHash` is that recursive NAR-style hash of the unpacked tree — a
# different value from the flat-file `sha256` above by construction (it
# hashes a decompressed, unpacked file tree, not raw .tar.gz bytes) — and
# there is no way to compute it without a working `nix` binary, which this
# development environment does not have (see CONTRIBUTING/task notes).
# `unpackedSha256` below is therefore an intentionally-wrong 64-zero
# placeholder.
#
# PM ACTION REQUIRED (first CI run only): nothing forces `unpacked` to be
# built during plain evaluation any more (it's an ordinary derivation, not
# an eval-time fetch), so `flake check --no-build` should now pass cleanly.
# The hash mismatch instead surfaces when CI's "flake" job actually BUILDS
# the proof (the "Build stdenv-proof" step, `nix build .#stdenv-proof`),
# with an error of the shape:
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

    # The audited trust-root fetch: a plain fixed-output fetch of the flat
    # tarball bytes, hash-verified above. This is the sole input `unpacked`
    # below unpacks (see "Bootstrap" above for why the unpacking itself
    # can't happen inside the ordinary Nix build sandbox).
    tarball = builtins.fetchurl { inherit url sha256; };

    # PLACEHOLDER — see "PM ACTION REQUIRED" above. Deliberately wrong so
    # CI's first build reports the real value in its error message.
    # Filled from the first CI run's fixed-output hash-mismatch error
    # (run 29705333709, "Build stdenv-proof": got sha256-/M1f0hVn4Hbslk
    # UVHEgKAYMHMkL8bCAg7+4Z+0ztefo=, converted SRI→hex). Permanent for
    # this url/version/arch pin.
    unpackedSha256 = "fccd5fd21567e076ec9645151c480a0183073242fc6c2020efee19fb4ced79fa";

    # The actual bootstrap primitive: an unpacked ubuntu-base rootfs tree.
    # `__noChroot = true` lets this one derivation's builder see the host
    # filesystem (needed to reach the host's own `/bin/sh` and `tar` — see
    # "Bootstrap" above for why that's the deliberate, contained crossing
    # point rather than a violation of it); `outputHash`/`outputHashMode`
    # make it a fixed-output derivation regardless, so the result is
    # verified byte-for-byte just like any other pinned fetch. CI must pass
    # `--option sandbox relaxed` when building anything that depends on
    # this (see .github/workflows/ci.yml) — Nix refuses `__noChroot`
    # otherwise.
    unpacked = builtins.derivation {
      name = "ubuntu-base-${version}-${arch}-unpacked";
      system = "x86_64-linux";
      builder = "/bin/sh";
      args = [
        "-c"
        ''
          set -eu
          export PATH=/usr/bin:/bin
          mkdir -p "$out"
          # --no-same-owner: we may be running as root (CI's `sudo nix
          # build`); without it tar would try to restore the archive's
          # recorded uid/gid (root's, since ubuntu-base ships as root-owned
          # throughout) onto files it extracts as itself anyway, which is a
          # harmless no-op as root but is disabled explicitly rather than
          # relied upon, since the resulting tree's ownership bits are not
          # meant to be a meaningful part of what's pinned (NIX_STORE
          # content is; the recursive hash below covers exactly the bytes
          # NAR-serializes, which for a store path is names/contents/
          # executable-bit/symlink-targets, not uid/gid).
          tar -xzf ${tarball} -C "$out" --no-same-owner
        ''
      ];
      __noChroot = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = unpackedSha256;
    };
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
  # path involved is an explicit absolute Nix store path. Unlike `unpacked`
  # above, this derivation runs fully sandboxed (no `__noChroot` needed):
  # every path it touches is already a Nix store input.
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
      # BOOTSTRAP CAVEAT (CI run 29705389052): the loader trick above only
      # covers the ENTRY binary (bash). When the script execs another
      # dynamically-linked ubuntu-base binary by bare name, the kernel
      # looks for that binary's hardcoded ELF interpreter
      # (/lib64/ld-linux-x86-64.so.2), which does not exist inside the Nix
      # sandbox — "cannot execute: required file not found". Until #9's
      # chroot/namespace builder provides a real FHS root, scripts must
      # invoke dynamically-linked children through the loader explicitly:
      #   "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" <abs path> <args>
      # (Shell builtins, bash scripts, and static binaries are unaffected.)
      UBX_LD = ld;
      UBX_LIBRARY_PATH = libraryPath;
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
          "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" \
            "${ubuntuBase.unpacked}/usr/bin/dpkg" --version
          echo "== bash --version =="
          "$UBX_LD" --library-path "$UBX_LIBRARY_PATH" \
            "${ubuntuBase.unpacked}/usr/bin/bash" --version
        } > "$out"
      '';
    };
  };
}
