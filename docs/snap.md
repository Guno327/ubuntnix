# Snaps: declared surface, lockfile, and vendoring

```{admonition} Contracts implemented (M3); real on-device convergence is later work
:class: note

`snaps.packages.json`, `snaps.lock.json`, `bin/ubx-snap-resolve`, and
`nix/snap.nix` exist in the repository as of milestone **M3** (`SPEC.md`
§4.3, §4.4, §4.5, §5, §6; issue #60): the declared-surface validation,
lockfile schema, resolver, and fixed-output vendoring described below are
real. What is **not** implemented yet: a real `ubuntnix.snaps.<name>`
module option (`nix/snap.nix`'s `validate`/`compileManifest` are ready for
one to call once real module evaluation exists — the same "no `modules/`
tree yet" caveat `nix/etc.nix`'s and `nix/systemd.nix`'s own docs describe),
converging a running system's snapd against the compiled manifest (a future
on-device planner/executor, by analogy with `bin/ubx-etc`/
`bin/ubx-etc-apply`), and wiring `bin/ubx-snap-resolve` into `ubx update`
(SPEC.md §4.5's three pin sources — flake inputs, archive, snap — are
expected to be wired together in one later issue; see
`bin/ubx-snap-resolve`'s own header for why `ubx update` deliberately stays
a stub until then, mirroring the identical precedent
`bin/ubx-resolve` already set for the archive-pins portion).
```

ubuntnix prefers snaps over debs where a good one exists (`SPEC.md` §5:
"snap preferred, deb fallback"). Like the archive lockfile, the snap
universe a machine can declare against is pinned so that resolving today and
resolving a year from now yields the same bytes.

## The declared surface

`snaps.packages.json` (repository root) is the committed, interim stand-in
for `SPEC.md` §6's `ubuntnix.snaps.<name>` primitive:

```json
{
  "allowUnverifiedPublishers": false,
  "snaps": {
    "hello-world": {
      "channel": "stable",
      "revision": null,
      "classic": false,
      "connections": [],
      "config": {},
      "unverifiedPublisher": false
    }
  }
}
```

- **`channel`** — required; always drives resolution (`track/risk/branch`,
  e.g. `"stable"`, `"latest/edge"`).
- **`revision`** — optional (`null` by default). When set, it additionally
  **pins** the exact revision `channel` is expected to resolve to (`SPEC.md`
  §6's own `ubuntnix.snaps.firefox = { revision = 4090; ... };` example) —
  `bin/ubx-snap-resolve` hard-fails if the Store's current channel revision
  disagrees, and `nix/snap.nix`'s `compileManifest` re-checks the same pin
  against the committed lockfile independently at eval time.
- **`classic`** — whether the snap needs classic (unconfined) confinement.
- **`connections`** — interface plug/slot names to connect.
- **`config`** — `snap set` key/value pairs.
- **`unverifiedPublisher`** — per-snap opt-in to the verified-publisher
  policy below.
- **`allowUnverifiedPublishers`** (top level) — the per-**system** default
  for the same policy (`SPEC.md` §4.5: "a per-system (and per-snap) toggle
  opts in to unverified publishers").

## Verified provenance by default

`SPEC.md` §5: "only Canonical-published or verified-publisher snaps are
eligible by default." `bin/ubx-snap-resolve` enforces this at **resolve**
time (a snap whose Store-reported publisher is not verified is refused
unless its own `unverifiedPublisher` or the declaration's
`allowUnverifiedPublishers` says otherwise), and `nix/snap.nix`'s
`compileManifest` re-derives and re-enforces the identical policy
independently at **eval** time against the committed lockfile — the same
dual-enforcement posture `nix/systemd.nix`/`bin/ubx-systemd` take for the
refuse-restart class table.

## The snap lockfile

`snaps.lock.json` (repository root, plain JSON — same "readable with no
`nix` binary" reasoning `archive.lock.json` gives) pins `(name, revision,
assertion hashes)` per `SPEC.md` §4.4:

```json
{
  "version": 1,
  "snaps": [
    {
      "name": "hello-world",
      "channel": "stable",
      "revision": 29,
      "classic": false,
      "publisher": "Canonical",
      "publisherVerified": true,
      "snap": {
        "url": "https://api.snapcraft.io/api/v1/snaps/download/<snap-id>_29.snap",
        "sha256": "<64 hex>",
        "size": 20480
      },
      "assert": {
        "url": "https://api.snapcraft.io/api/v1/snaps/assertions/snap-declaration/16/<snap-id>",
        "sha256": "<64 hex>"
      },
      "connections": [],
      "config": {}
    }
  ]
}
```

Every `snap.sha256`/`assert.sha256` is recomputed locally from bytes
actually fetched from the live Snap Store — the Store's own self-reported
metadata (its JSON API's `sha3-384` field) is corroborating evidence, not
the trust root, mirroring `archive.lock.json`'s own methodology.

### A scoped simplification: which assertion is pinned

A real `snap ack` needs a full assertion chain (account, account-key,
snap-declaration, snap-revision) before a sideloaded payload can be
installed fully offline. That chain has no single stable HTTP URL a
`<nix/fetchurl.nix>` fixed-output derivation could deterministically re-GET.
`assert.url`/`assert.sha256` above therefore pin specifically the
**snap-declaration** assertion, fetched from its own stable,
independently-re-fetchable endpoint
(`api.snapcraft.io/v1/snaps/assertions/snap-declaration/16/<snap-id>`) —
enough to bind a snap name to its `snap-id` and publisher identity (what
`nix/snap.nix`'s policy re-enforcement needs), but **not** enough for a
fully offline `snap ack` of the sideloaded payload by itself. This is a
deliberate, tracked scope reduction, not an oversight — see
`bin/ubx-snap-resolve`'s `_ubx_snap_resolve_real` header for the full
reasoning, and the real on-device converge step (not yet implemented) is
where a full assertion chain will need to be sourced properly.

## Resolving: `bin/ubx-snap-resolve`

`bin/ubx-snap-resolve` mirrors `bin/ubx-resolve`'s own producer/consumer
split: it resolves `snaps.packages.json` against the Snap Store and writes
`snaps.lock.json`, which `nix/snap.nix` only ever **consumes**
(`builtins.fromJSON` + fetch-and-verify), never regenerates.

Real Store access is gated behind exactly one injectable seam,
`UBX_SNAP_RESOLVE_CMD` (or `--resolve-cmd`) — the same `UBX_*_CMD`
convention `bin/ubx`'s `UBX_SOFT_REBOOT_CMD`/`UBX_NEXTROOT_STAGE_CMD` and
`bin/ubx-etc-apply` already establish. It is invoked once per declared snap
as `CMD NAME CHANNEL REVISION_PIN` and must print one JSON object
(`revision`, `publisher`, `publisherVerified`, `snapUrl`, `snapSha256`,
`snapSize`, `assertUrl`, `assertSha256`) to stdout. The default
implementation shells out to the host's own `snap` client (present on every
supported host, the same "reuse Canonical's own tooling" posture
`bin/ubx-resolve` takes for `apt-get`); unit tests instead point the seam at
a small recording stub, so the whole declared-set → lockfile pipeline —
including the verified-publisher policy and the revision-pin cross-check —
is exercisable fully offline (`tests/unit/143-snap-resolver-seam.sh`; see
`tests/README.md`'s "unit tests must not require root, network, or KVM"
rule).

`--emit-lockfile FILE` is the pure half (no network, no `snap` client):
takes an already-resolved JSON array of tuples and runs them through the
exact validate/policy/sort/format logic real resolution uses — schema
conformance, stable (sort-by-name) ordering, and byte-stable/idempotent
formatting are all directly testable through this hook
(`tests/unit/141-snap-resolve-emit.sh`), exactly like `bin/ubx-resolve`'s
own `--emit-lockfile`.

## Vendoring: fixed-output derivations

`nix/snap.nix` turns each `snaps.lock.json` entry into fixed-output
derivations via Nix's own `<nix/fetchurl.nix>` (never a nixpkgs fetcher —
`SPEC.md` §1.3), verified against the pinned `sha256` by Nix itself at
build time — the identical mechanism `nix/archive.nix` uses for debs.
`packages.snap-fetch-proof` forces every pinned payload/assertion to
actually fetch and re-hashes each one inside the sandbox as an independent
check; `packages.snap-hash-mismatch-proof` is the deliberate negative case
(a real URL, a deliberately wrong pinned hash) that must fail to build with
Nix's own "hash mismatch" error — mirroring `nix/archive.nix`'s
`archive-fetch-proof`/`archive-hash-mismatch-proof` pair exactly. Per
`SPEC.md` §4.3, the fetched `.snap`/`.assert` bytes belong in the
generation's retained-artifact set (`/ubx/store`) once real on-device
composition exists.

## The per-generation snap manifest

`nix/snap.nix`'s `compileManifest` is a pure function
(`entries`/`lockfile`/policy data in, manifest data out) that cross-checks
every declared name against the lockfile, re-enforces the verified-publisher
and revision-pin policies, and produces:

```json
{
  "version": 1,
  "snaps": [
    {
      "name": "hello-world",
      "channel": "stable",
      "revision": 29,
      "classic": false,
      "publisher": "Canonical",
      "publisherVerified": true,
      "connections": [],
      "config": {}
    }
  ]
}
```

`renderManifest` wraps this in a real, `nix build`-able derivation
(`packages.snap-proof`) for CI to exercise end to end without live
root/network/snapd. This manifest is exactly the artifact a future
on-device snap-domain planner (`bin/ubx-snap`, by analogy with
`bin/ubx-etc`/`bin/ubx-systemd`) would diff against observed `snap list`/
`snap connections` state — `bin/ubx-generations`' `GEN_SNAP_MANIFEST` field
is already reserved for exactly this.

## Where to track progress

The snap lockfile and resolver land at milestone **M3** (`SPEC.md` §11,
issue #60). Real on-device snapd convergence (`snap ack` + signed
sideload, interface connection, `snap set` config) and wiring
`bin/ubx-snap-resolve` into `ubx update`'s snap-pins portion are separate,
later work — see {doc}`workflows` for the planned `ubx update` flow across
all three pin sources.
