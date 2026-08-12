# The archive lockfile

```{admonition} Implemented: public tier (M1), esm tier (M4)
:class: note

`archive.lock.json` and `nix/archive.nix` exist in the repository as of
milestone **M1** (`SPEC.md` §4.4, issue #7): the schema below is real and
the fetch mechanics described here actually run in CI (`.#archive-fetch-
proof`). Milestone **M4** (issue #81) wires up the `esm` tier's fetching
against an Ubuntu Pro token (`SPEC.md` §8.2) — `bin/ubx-resolve-esm` and
`nix/archive.nix`'s `fetchEsmDeb`/`esmDebs`. The committed lockfile's
`esm.packages` remains `[]` today: populating it for real needs a real
Ubuntu Pro token and subscription, which is a **needs-owner item** (see
"CI Pro token" below) — the plumbing itself is real and tested against
fixtures (`tests/unit/055`–`059`). Rootfs composition — turning fetched
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
- **`esm`** — pinned directly by `(name, version, sha256)` plus `path` and
  a `source: "esm"` marker, with no snapshot timestamp (none exists for
  esm), fetched at build/rebuild time using the machine's or CI's own
  Ubuntu Pro token. Fetching is wired up as of **M4** (`SPEC.md` §8.2,
  GitHub issue #81) but the committed lockfile's `esm.packages` is still
  `[]` — populating it needs a real Pro token/subscription (a needs-owner
  item). esm content is never redistributed publicly: `bin/ubx-archive-
  public-manifest` builds the public project cache / ISO manifest from the
  `public` tier only, and never reads `esm` at all — so a populated `esm`
  tier still can't leak into anything served to the public.

## Resolving the public tier: three suites, one snapshot

`bin/ubx-resolve` resolves the public tier against **three suites** of the
one pinned `snapshot.ubuntu.com` timestamp — `noble`, `noble-updates`, and
`noble-security` — not just the plain `noble` release pocket. This closes
[GitHub issue #39](https://github.com/ubuntnix/ubuntnix/issues/39): a
resolve against `noble` alone only ever yields the *oldest* content a
snapshot carries for that series, older than the `-updates` content
already baked into the `ubuntu-base` tarball the compose step bootstraps
from — so a single-suite resolve pinned packages *older* than what the
base image already had installed, and apt/dpkg "downgraded" them
mid-compose. `SPEC.md` §4.4 already scopes the public tier as covering
both `archive.ubuntu.com` and `security.ubuntu.com`, so resolving against
all three suites honors that scope rather than expanding it. All three
suite lines share the identical snapshot timestamp, keyring, and component
set — this widens which pockets of the *one* pinned snapshot apt is
allowed to solve against, not which archive or timestamp is trusted; see
`bin/ubx-resolve`'s "Which suites get resolved" header comment and
`tests/unit/054-ubx-resolve-suites.sh` for the exact line shape/order this
pins.

## The restricted/multiverse component toggle

```{admonition} Implemented: declarative layer (GitHub issue #106)
:class: note

`bin/ubx-resolve` has supported all four archive components
(`main`/`universe`/`restricted`/`multiverse`) since milestone M1 — the gap
was that nothing declarative decided which subset a given machine actually
wants. `nix/archive.nix`'s `componentToggleType`/`effectiveComponents`
close that gap. `archive.packages.json`'s committed `components` list
stays `["main", "universe"]` — this feature adds the toggle, it does not
flip the committed default.
```

`SPEC.md` §5's package policy defaults every machine to `main` and
`universe` only; `restricted` and `multiverse` are a **per-machine
opt-in**, off by default. `nix/archive.nix` declares that toggle:

```nix
ubuntnix.archive.components = {
  restricted = false;   # default false
  multiverse = false;   # default false
};
```

`effectiveComponents` turns a declared toggle into the exact flat
`components` list `archive.packages.json`/`bin/ubx-resolve` already
consume: `main` and `universe` are always included, with `restricted`/
`multiverse` appended (in that fixed order) only when enabled. A machine
that wants, say, a restricted-only driver package sets
`ubuntnix.archive.components.restricted = true`, which yields
`["main", "universe", "restricted"]` — the same shape a human/CI would
type by hand into `archive.packages.json`'s `components` field, since that
file remains the interim, hand-maintained declaration `bin/ubx-resolve`
resolves against pre-M2 (see that script's and that JSON file's own
header comments). `bin/ubx-resolve` itself needed **no change** to honor
an enabled component: it already validates against, and resolves/pins
against, whatever subset of its `VALID_COMPONENTS` set a declaration's
`components` list carries (`tests/unit/050-archive-declaration.sh` already
covers all four components at that layer) — this toggle is purely about
**which** subset a machine declares, default off, not how the resolver
behaves once declared. With the toggle off, a restricted/multiverse-only
package is structurally unresolvable: the scratch `sources.list`
`bin/ubx-resolve` writes (see "Resolving the public tier" above) carries
only the enabled components, so apt's solver never even sees that
package's pool entries. `tests/unit/190-archive-components-toggle.sh`
exercises both the sources.list-generation level (toggle off vs. on) and
the lockfile-emission level (a resolved restricted/multiverse-component
tuple still pins its full `name`/`version`/`arch`/`component`/`path`/
`sha256`/`size` schema once resolved) — the two halves of "fails to
resolve when off, resolves and pins when on" that a unit test can exercise
without a live apt solve (`tests/README.md`'s "no network" rule).

**esm-apps does not cover restricted/multiverse.** `nix/pro.nix`'s
`esmApps` primitive (`SPEC.md` §5/§9) provides Canonical patch coverage
for `universe` once Ubuntu Pro is attached — it does **not** extend to
`restricted` or `multiverse`. Packages resolved from those two components,
when this toggle enables them, follow **upstream Canonical's own patch
cadence** for `restricted`/`multiverse`, exactly like a stock Ubuntu
install with those components enabled — attaching Pro and turning on
esm-apps changes nothing about how those packages get patched.

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

A populated `esm.packages[]` entry (once a real Pro token/subscription
exists, GitHub issue #81) looks like:

```json
{
  "name": "some-universe-pkg",
  "version": "1.2.3-1ubuntu1~esm1",
  "sha256": "…64 hex chars…",
  "path": "pool/esm-infra/main/s/some-universe-pkg/some-universe-pkg_1.2.3-1ubuntu1~esm1_amd64.deb",
  "source": "esm"
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
- **`esm.packages[]`** — `name`, `version`, `sha256`, `path` (the
  esm.ubuntu.com pool-relative path), and `source` (always the literal
  string `"esm"` — the marker that lets a consumer working from a
  flattened package list, e.g. `bin/ubx-archive-public-manifest`'s
  exclusion guard, tell an esm-tier entry apart from a public-tier one).
  Empty (`[]`) in the committed lockfile until a real Pro token/
  subscription populates it (needs-owner item, GitHub issue #81).

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

## esm-tier fetching and the Pro token (M4)

`nix/archive.nix`'s `fetchEsmDeb` turns each `esm.packages[]` entry into a
fixed-output derivation, exactly like `fetchDeb` does for the public tier
— except esm.ubuntu.com requires HTTP Basic auth (the Pro token as the
username, the literal password `bearer`, mirroring Canonical's own `pro
attach`-written apt credentials), which Nix's own internal fetchurl
expression can't express. `fetchEsmDeb` instead reads the token from the
**one** environment variable this project ever consumes a Pro token from,
`UBUNTNIX_CI_PRO_TOKEN`, via Nix's `impureEnvVars` mechanism — the same
documented pattern real-world Nix fetchers use for proxy/credential
variables: the sandboxed builder may read the named variable from the
calling process's real environment, but the value never becomes part of
the derivation's hashed inputs or its `.drv` file. Only the fetched
**output** is pinned (`outputHash`, verified against the entry's `sha256`
exactly like the public tier's hash-mismatch guarantee) — the token itself
is never printed, logged, or committed anywhere.

`bin/ubx-resolve-esm` is the resolver/emitter half: given already-resolved
`(name, version, path)` pins (esm has no apt-solvable index the way the
public tier does — see that script's header for why), it fetches each
with the same token, hashes the result locally, and emits `esm.packages[]`
entries with the `source: "esm"` marker, merging into an existing lockfile
without touching its `public` section. Its `--emit-lockfile` flag is a
pure, fixture-driven testing hook — `tests/unit/057-ubx-resolve-esm-emit.sh`
exercises the whole hash-pinned emission path with **no real network
access and no real token**, per the project's "unit tests require no
network" rule.

**CI Pro token — needs-owner item.** SPEC.md §8.2 says "CI holds a Pro
token"; `.github/workflows/ci.yml`'s "flake" job passes a repository
secret named exactly **`UBUNTNIX_CI_PRO_TOKEN`** into the environment of
its `archive-esm-fetch-proof` build step. That secret does not exist yet —
obtaining a real Ubuntu Pro token is an owner action (a Canonical
account), not something this plumbing can do for itself. Until it's
added, the proof step degrades to a deterministic, network-free **skip**
(because `archive.lock.json`'s `esm.packages` is also still empty) rather
than failing the build; `bin/ubx-resolve-esm --check-token` and
`nix/archive.nix`'s own missing-token error path are exercised directly by
`tests/unit/058-ubx-resolve-esm-token-handling.sh`, which also asserts the
token's value is never echoed by any code path, set or unset.

## The public-cache boundary

esm content is subscription-gated and must **never** reach the public
project binary cache or the public ISOs/prebuilt images (`SPEC.md` §4.4,
§10) — mirroring how upstream Ubuntu only exposes esm-patched packages to
a machine after `pro attach`. `bin/ubx-archive-public-manifest` is the one
place this boundary is enforced mechanically: it reads an archive lockfile
and emits a manifest containing the `public` tier **only** — its own
source never parses or opens the `esm` key at all, so there is no code
path through which an esm entry could end up in its output regardless of
how the input lockfile is shaped. It additionally cross-checks that no
public-tier sha256 collides with an esm-tier one, failing loudly if it
ever finds one (a defensive check against a future refactor blurring the
two lists together upstream of this script). Whatever eventually
populates the R2-hosted cache / builds the ISOs (a later milestone) is
expected to consume this script's output, not `archive.lock.json`
directly — `tests/unit/059-archive-public-cache-manifest.sh` pins the
exclusion guarantee against a fixture carrying both tiers.

## The parity model also has to account for the base layer

The archive lockfile is not the whole story of what a composed ubuntnix
system contains, and `tests/unit/210-upstream-manifest-parity.sh`'s R11
coverage accounting (SPEC.md §12 R11, §11 M7; GitHub issue #140) has to
know that. `nix/compose.nix`'s `composeRootfs` builds every rootfs by
unpacking the `ubuntu-base` tarball FIRST and layering the locked closure
on top of it (see that function's own "ubuntu-base plus every declared
package" header) — `nix/stdenv.nix` is what fetches and SHA-256-pins that
tarball, the one third-party artifact this whole project trusts outside
pinned flake inputs (see that file's "Trust root" comment). A package that
ships inside ubuntu-base itself — `bash`, `dash`, `grep`, `gzip`,
`util-linux`, `base-files`, `login`, and eight others as of this writing —
is present on every real composed system whether or not `archive.lock.json`
also lists it. Diffing the locked closure alone against upstream therefore
overstates the R11 coverage gap; the honest comparison is base ∪ closure.

That base-layer inventory is committed as `tests/fixtures/upstream-
manifests/ubuntu-base-24.04.4-base-amd64.packages` — derived from the
pinned tarball's own `var/lib/dpkg/status`, not fetched or unpacked again
at test time — and `tests/unit/213-ubuntu-base-fixture-pin.sh` is the
tripwire that keeps it from silently drifting onto a different
`ubuntu-base` spin than the one `nix/stdenv.nix` actually fetches. This
only changes how 210 *reports* the upstream coverage gap; it does not
relax the "declared ⊆ upstream + documented additions" subset assertion
that check exists to enforce, which has nothing to do with the base layer.

## Where to track progress

The archive lockfile and public-tier fetching land at milestone **M1**
(`SPEC.md` §11, issue #7); turning fetched `.deb`s into a composed rootfs
image is separate M1 work tracked elsewhere. The `esm` tier's fetching
logic lands at milestone **M4** (`SPEC.md` §8.2, GitHub issue #81),
independent of the declarative Ubuntu Pro *attachment* flow (also M4,
tracked separately) — this issue is the archive-resolver/CI-token-
handling half only. `ubx update`'s archive-pin refresh flow — re-resolving
`public.snapshot` and rewriting the pinned tuples — is described in
{doc}`workflows`.
