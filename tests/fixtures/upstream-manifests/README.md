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

## Licensing

These manifests are factual package inventories (name + version pairs)
published freely by Canonical alongside every public Ubuntu release for
exactly this kind of downstream verification. They contain no Canonical
source or creative content — only the list of package names/versions that
make up a public release.
