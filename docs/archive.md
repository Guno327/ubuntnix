# The archive lockfile

```{admonition} Implemented (M1); esm tier lands at M4
:class: note

`archive.lock.json` and `nix/archive.nix` exist in the repository as of
milestone **M1** (`SPEC.md` §4.4, issue #7): the schema below is real and
the fetch mechanics described here actually run in CI (`.#archive-fetch-
proof`). The `esm` tier's *shape* is part of the schema today but is
intentionally left empty until milestone **M4** wires up fetching against
an Ubuntu Pro token (`SPEC.md` §8.2). Rootfs composition — turning fetched
`.deb`s into a bootable image — is separate, later M1 work, not described
here.
```

ubuntnix pins the entire deb universe it can declare against, so that a
flake evaluated today and a flake evaluated a year from now resolve to
byte-identical packages (`SPEC.md` §4.4, G6). The archive lockfile is how
that pin is recorded.

## Two tiers

Per `SPEC.md` §4.4, the snapshot service Canonical operates
(`snapshot.ubuntu.com`) only covers the **public** archive pockets
(`archive.ubuntu.com`, `security.ubuntu.com`) — it does not cover
**esm** (`esm.ubuntu.com`), which is subscription-gated and has no
snapshot history at all. The lockfile therefore pins the two tiers
differently:

- **`public`** — a single `snapshot.ubuntu.com` timestamp plus a list of
  resolved `(name, version, arch, component, path, sha256, size)` tuples.
  Upstream retains snapshots for "at least 2 years", so the pinned
  **hash** is the durable trust root; the timestamp only drives
  *resolution* against the snapshot service the first time a package is
  fetched.
- **`esm`** — the identical per-package shape, pinned directly by
  `(name, version, sha256, ...)` with no snapshot timestamp (none exists
  for esm), fetched at build/rebuild time using the machine's or CI's own
  Ubuntu Pro token. This tier is present in the schema but **empty until
  M4** (`SPEC.md` §8.2); esm content is never redistributed publicly, so a
  populated `esm` tier could not ship in the public project cache or ISOs
  even once M4 lands.

## Entry schema

`archive.lock.json` lives at the repository root (not under `nix/`) as
plain JSON — readable by Nix's `builtins.fromJSON` **and** by ordinary
tooling that has no `nix` binary at hand (a future `ubx update`, CI
scripts, this documentation). Its shape:

```json
{
  "version": 1,
  "public": {
    "snapshot": "20260715T000000Z",
    "series": "noble",
    "packages": [
      {
        "name": "htop",
        "version": "3.3.0-4build1",
        "arch": "amd64",
        "component": "main",
        "path": "pool/main/h/htop/htop_3.3.0-4build1_amd64.deb",
        "sha256": "ee0e9cffc789788164214bac9b6e285a5127c07be1815129875c6c538ba849c6",
        "size": 170528
      }
    ]
  },
  "esm": {
    "packages": []
  }
}
```

- **`version`** — the lockfile format's own schema version (an integer;
  `1` today), bumped by hand if the shape above ever needs to change
  incompatibly.
- **`public.snapshot`** — the `snapshot.ubuntu.com` timestamp
  (`YYYYMMDDTHHMMSSZ`) every public-tier package was resolved against.
- **`public.series`** — the Ubuntu series the snapshot was resolved for
  (`"noble"`, i.e. 24.04 LTS — `SPEC.md`'s pinned base series).
- **`public.packages[]`** — one entry per pinned package: `name`,
  `version` (the full Debian version string, including any epoch),
  `arch`, `component` (`main`/`universe`/`restricted`/`multiverse`),
  `path` (the pool-relative path exactly as the archive's own `Packages`
  index gives it, e.g. `pool/main/h/htop/...`), `sha256` (64 lowercase
  hex characters), and `size` in bytes.
- **`esm.packages[]`** — the same per-package shape; empty until M4.

Every `sha256` committed to the lockfile is independently verified before
being pinned: the archive's own `Packages` index is corroborating
evidence, not the trust root — the `.deb` is downloaded and hashed
locally, and the locally-recomputed digest is what gets recorded (the same
methodology `nix/stdenv.nix` documents for the `ubuntu-base` trust root).

## How fetching resolves

`nix/archive.nix` parses the lockfile and turns each public-tier entry
into a fixed-output derivation:

```text
https://snapshot.ubuntu.com/ubuntu/<public.snapshot>/<entry.path>
```

fetched via Nix's own internal `<nix/fetchurl.nix>` expression (not a
nixpkgs fetcher — `SPEC.md` §1.3/§3 forbids those entirely) and verified
against `entry.sha256` by Nix itself at build time. A mismatch — a
tampered download, a corrupted mirror, or an accidentally wrong pin —
fails the build outright with Nix's own "hash mismatch in fixed-output
derivation" error; CI exercises this path deliberately
(`.#archive-hash-mismatch-proof`) as a negative test, so the guarantee
itself stays under test.

Because the snapshot timestamp only drives *resolution* and the sha256 is
the actual trust root, a fetch remains reproducible for as long as
Canonical retains the referenced snapshot content — which upstream commits
to for "at least 2 years" (`SPEC.md` §4.4, R4).

## Where to track progress

The archive lockfile and public-tier fetching land at milestone **M1**
(`SPEC.md` §11, issue #7); turning fetched `.deb`s into a composed rootfs
image is separate M1 work tracked elsewhere. The `esm` tier's fetching
logic, backed by a declarative Ubuntu Pro attachment, lands at milestone
**M4** alongside secrets (`SPEC.md` §8.2). `ubx update`'s archive-pin
refresh flow — re-resolving `public.snapshot` and rewriting the pinned
tuples — is described in {doc}`workflows`.
