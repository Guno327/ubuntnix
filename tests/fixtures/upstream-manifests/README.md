# Upstream Ubuntu release manifests (parity ground truth)

These are verbatim, committed copies of the `.manifest` files Canonical
publishes beside each Ubuntu release ISO. Each is a plain
`<package>\t<version>` list of every binary package present on the shipped
image — the authoritative upstream package set for that release + variant.

They exist so the R11 seed/manifest-parity check (SPEC.md §12 R11, §11 M7;
GitHub issue #118) can diff ubuntnix's declared seed closure against **real
upstream ground truth** reproducibly, with **no CI network dependency** and
**no live-fetch flakiness** — exactly the "committed per-release manifest
fixtures" approach recorded as the decided source on #118.

## Provenance

Fetched from `https://releases.ubuntu.com/24.04/` (the canonical release
mirror) and committed byte-for-byte. Integrity is pinned by
`tests/unit/210-upstream-manifest-parity.sh`, which fails if either file's
SHA-256 drifts from the value recorded below.

| File | Release | SHA-256 |
|---|---|---|
| `ubuntu-24.04.3-live-server-amd64.manifest` | 24.04.3 LTS (Server) | `a530142e61ad1cc73b3845d20ed65bdb8d0ff2ca18b71a6250d10981069a5c67` |
| `ubuntu-24.04.3-desktop-amd64.manifest` | 24.04.3 LTS (Desktop) | `d4265ebd3bd7d2679ef050761d0fa60b3f77e1e1e7d809ab01c8c190c742ed0b` |

## Refreshing for a new Ubuntu release

Fetch the new `.manifest` beside the target ISO on `releases.ubuntu.com`,
drop it here under its exact upstream filename, update the table above with
its SHA-256, and update the pins + variant list in
`tests/unit/210-upstream-manifest-parity.sh`. Keep older releases so parity
stays versioned per Ubuntu release as R11 prescribes.

## The `ubuntu-base` base-layer package list (GitHub issue #140)

The two `.manifest` files above are Server/Desktop ISO manifests — the full
package set an *installed* system has. But `nix/compose.nix`'s
`composeRootfs` does not build a composed ubuntnix rootfs from the locked
closure alone: it unpacks the `ubuntu-base` tarball FIRST and layers the
locked closure on top (`nix/compose.nix`, the "ubuntu-base plus every
declared package" language at both its `composeRootfs` header and its
`composeRootfs` implementation). Every package already inside `ubuntu-base`
— `bash`, `dash`, `grep`, `gzip`, `util-linux`, `base-files`, `login`, and
so on — is therefore present on every real composed system whether or not
`archive.lock.json` also lists it, and diffing the locked closure alone
against the Server/Desktop manifests (as `tests/unit/210-upstream-manifest-
parity.sh` used to) overstates the R11 coverage gap by exactly that many
packages.

`ubuntu-base-24.04.4-base-amd64.packages` is the fix: the plain
sorted, one-name-per-line list of every package dpkg considers installed
inside the *same* `ubuntu-base-24.04.4-base-amd64.tar.gz` tarball that
`nix/stdenv.nix` fetches and hash-pins (not a separately-chosen version —
see that file's own "Trust root" comment for the pin's provenance). Unlike
the two `.manifest` files, this is not itself a Canonical-published
artifact; it's derived from the tarball's own `var/lib/dpkg/status`, as
documented in the fixture's own header comment. `tests/unit/210-upstream-
manifest-parity.sh` unions it with the locked closure when reporting R11
coverage, and `tests/unit/213-ubuntu-base-fixture-pin.sh` asserts this
fixture's recorded provenance SHA-256 still matches `nix/stdenv.nix`'s live
pin, sorted order, and no duplicates — so it cannot silently drift onto a
different `ubuntu-base` spin than the one actually fetched at build time.

If `nix/stdenv.nix`'s pin ever moves to a new `ubuntu-base` point release,
regenerate this fixture from the new tarball (see the fixture's own header
for the exact extraction command) and update both this section and
`tests/unit/213-ubuntu-base-fixture-pin.sh`'s expectations accordingly.

## Licensing

These manifests are factual package inventories (name + version pairs)
published freely by Canonical alongside every public Ubuntu release for
exactly this kind of downstream verification. They contain no Canonical
source or creative content — only the list of package names/versions that
make up a public release.
