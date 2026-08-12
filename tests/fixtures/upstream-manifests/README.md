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

**These are LIVE-ISO manifests, not installed-system manifests, and that
caps how far R11's coverage number can ever go (GitHub issue #143).** The
`*-live-server-*` / `*-desktop-*` filenames are not a naming quirk: they are
the ONLY package inventory Canonical publishes for a 24.04.x point release.
Checked directly against both `releases.ubuntu.com/24.04.3/` and the
cdimage daily-live tree for this task — neither publishes an
installed-system manifest at all, only `*-live-server-*`, `*-desktop-*`,
and `*-wsl-*` `.manifest` files, all of which describe what the **live
boot medium** carries (the installer plus its live session), not what
ends up on disk after `install` finishes. A live medium unavoidably
carries packages an installed system never will — most concretely the
live-boot/installer stack itself (`casper`, `user-setup`,
`localechooser-data`, the installer's own pre-seeded snaps) — and pins its
own kernel ABI build number into package names
(`linux-image-6.8.0-71-generic` and similar) that will differ from
whatever ABI build ubuntnix's `archive.lock.json` snapshot happens to
resolve for the same kernel source. Neither class can ever be "fixed" by
growing the seed further. `tests/unit/210-upstream-manifest-parity.sh`
therefore enumerates both classes explicitly (search that file for "issue
#143") and reports the coverage gap net of each, informationally, right
next to the raw gap — and **the honest R11 exit target for this metric is
`gap ⊆ {live-only, kernel-ABI-skew}`, not a raw gap of zero**, because a
raw zero against a live-ISO fixture is not an achievable, or even
meaningful, target. `tests/unit/214-live-iso-gap-classification.sh` pins
that classification logic against these fixtures so it can't silently
drift out of sync with them.

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

## The residual ratchet baseline (GitHub issue #146)

`tests/unit/210-upstream-manifest-parity.sh`'s gap-classification block
(the section documented above, GitHub issue #143) nets the raw upstream
gap down to a "residual" figure — packages genuinely missing from ubuntnix
with no live-ISO or kernel-ABI-skew excuse — and, until issue #146, only
ever PRINTED that number; nothing compared it to anything, so it could
regress every single PR with CI staying green throughout.

`parity-ratchet-baseline.json` is the fix: it pins, per variant, the exact
residual package COUNT and package NAME LIST measured on `main` @
`bb3e6fb` against the manifests/base-package-list above (Server 237,
Desktop 1401 as of that commit — see the file's own `_provenance` field).
210 now fails if a variant's live residual count exceeds the pinned
`residual_count`, and names the specific packages in the live residual
that are not in the pinned `residual_packages` list as the newly-entered
regression, rather than just reporting a bigger number. A live residual
BELOW baseline still passes (an improvement is never a failure) but prints
a "ratchet may be tightened" note instead of silently absorbing the slack,
so lowering this file is always a deliberate, reviewable follow-up PR.

Refreshing this file (whether tightening after a real improvement, or
widening after refreshing the manifests above for a new Ubuntu release)
means re-running 210's gap-classification computation and recording the
new counts/package lists here with an updated `_provenance` note — never
just bumping the numbers to make a real regression disappear.

## Licensing

These manifests are factual package inventories (name + version pairs)
published freely by Canonical alongside every public Ubuntu release for
exactly this kind of downstream verification. They contain no Canonical
source or creative content — only the list of package names/versions that
make up a public release.
