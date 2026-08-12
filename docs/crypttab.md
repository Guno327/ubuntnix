# Passphrase-LUKS groundwork: crypttab and mount units

```{admonition} Mechanism only, unwired (M4, issue #83); the installer LUKS flow is M7
:class: note

`nix/crypttab.nix`, `bin/ubx-crypttab`, and `bin/ubx-crypttab-apply` exist
in the repository as of milestone **M4** (`SPEC.md` §11 M4 "passphrase-LUKS
groundwork (crypttab/fileSystems)", §4.2 "generated /etc", §8.3 "Full-disk
encryption: passphrase LUKS in v1... groundwork M4, installer flow M7";
GitHub issue #83): declaration, eval-time validation, JSON manifest
rendering, the diff-driven planner, and a thin executor are all real and
unit-tested (`tests/unit/175-crypttab-flake-wiring.sh`,
`tests/unit/176-ubx-crypttab-plan.sh`,
`tests/unit/177-ubx-crypttab-apply-executor.sh`,
`tests/unit/233-ubx-crypttab-apply-idempotent.sh`).

What this page describes is **groundwork only**: given a declared LUKS
volume, it compiles a correct `/etc/crypttab` entry and matching systemd
`.mount` unit. It does **not** decide which real disk to encrypt, prompt
for a passphrase, or run `cryptsetup luksFormat` — that is the guided-
install LUKS flow, separate M7 scope (`SPEC.md` §11 lists it apart from
this groundwork). It is also **not currently wired into anything**: unlike
{doc}`home`/{doc}`etc`/{doc}`systemd`, `bin/ubx`'s `execute_domains` does
not invoke `bin/ubx-crypttab-apply`, and unlike {doc}`filesystems`/
{doc}`localization`, no example config (`examples/server.nix`/
`examples/desktop.nix`) or `nix/profiles.nix` parity image declares a
`ubuntnix.crypttab` volume — this domain has no flake-evaluated proof
target and no QEMU e2e coverage today. Every claim on this page is backed
only by the unit tests named above, run against hand-crafted fixtures with
no root and no real block device.
```

## Why this exists

`SPEC.md` §8.3 commits to "passphrase LUKS in v1" for full-disk encryption
(matching upstream installer parity) and splits that commitment into two
pieces: the **mechanism** — given a declared LUKS volume, generate the
right `/etc/crypttab` entry and the mount unit that waits on it — lands at
M4 as groundwork; the **guided-install flow** that actually formats a real
disk and prompts for a passphrase is M7 work. This module and its two
`bin/ubx-crypttab*` scripts are entirely that M4 groundwork: they compile a
declaration to correct on-disk artifacts and know how to converge those
artifacts against observed state, but they never touch a real disk or
passphrase.

`nix/crypttab.nix` is `nix/etc.nix`'s and `nix/pro.nix`'s direct sibling in
shape: a `validate` function (eval-boundary enforcement) and a `render`
function (pure, JSON-ready manifest) exposed under `flake.lib.crypttab`,
ready for a future `ubuntnix.crypttab` module option once a real module
tree exists (see {doc}`modules`).

## The declaration surface

```nix
ubuntnix.crypttab."data" = {
  device = "/dev/disk/by-uuid/1234-5678-9abc-def0";  # required; absolute
                                  # path (a UUID/by-id/by-partuuid path is
                                  # strongly preferred, but not enforced)
  keyFile = "none";               # default "none"; "-" also accepted
                                  # (both mean "prompt for a passphrase at
                                  # boot" -- the only mode this groundwork
                                  # covers)
  options = "luks,discard";       # default ""; opaque, passed through
                                  # verbatim
  mountPoint = "/mnt/data";       # optional; when set, a matching
                                  # systemd .mount unit is also rendered
  fsType = "ext4";                # default "ext4"; only consulted when
                                  # mountPoint is set
  mountOptions = "defaults";      # default "defaults"; only consulted
                                  # when mountPoint is set
};
```

The attribute name (`"data"` above) is the crypttab mapper name —
crypttab(5) column 1, and (per systemd-cryptsetup-generator(8)) also the
instance name of the `systemd-cryptsetup@<name>.service` unit systemd
synthesizes at boot from a real `/etc/crypttab`.

### Options (all verified against `nix/crypttab.nix`)

| Option | Type | Default | Renders to |
|---|---|---|---|
| `ubuntnix.crypttab.<name>` (attr name) | `[a-z][a-z0-9_]*` (no `-`) | *(required key)* | crypttab(5) column 1; `systemd-cryptsetup@<name>.service` |
| `device` | absolute path string | *(required)* | crypttab(5) column 2 |
| `keyFile` | `"none"` or `"-"` only | `"none"` | crypttab(5) column 3 |
| `options` | string | `""` | crypttab(5) column 4 (omitted entirely, not left blank, when empty) |
| `mountPoint` | nullable absolute path | `null` | `.mount` unit's `Where=`, if set |
| `fsType` | non-empty string | `"ext4"` | `.mount` unit's `Type=`, if `mountPoint` set |
| `mountOptions` | string | `"defaults"` | `.mount` unit's `Options=`, if `mountPoint` set |

### Why `keyFile` is restricted to `none`/`-`

A real keyfile-backed volume is a materially different secret-handling
story — the keyfile's own bytes would need {doc}`secrets` wired in as a
third consumer, which `SPEC.md`'s "passphrase LUKS in v1" scope does not
ask for. Restricting `keyFile` to the two crypttab(5) spellings that both
mean "prompt at boot" keeps the declaration surface honest about what it
actually supports today; a real keyfile mode is a natural, additive
extension for a later issue.

### Why mapper names can't contain `-`

systemd's unit-name escaping (`systemd-escape(1)`) maps a literal `-` to
`\x2d`, so a mapper name containing `-` would make the real
`systemd-cryptsetup@<name>.service` instance name not equal the mapper
name written verbatim — silently breaking the `Requires=`/`After=` wiring
below unless this module also implemented full systemd escaping.
Restricting names to `[a-z][a-z0-9_]*` sidesteps that whole bug class for
this groundwork's scope.

## Validation

`checkVolume` collects **every** violation across the whole declaration
into one `throw` (never just the first — the same posture every validator
in this project takes): mapper-name grammar, `device` must be an absolute
path, `keyFile` must be `"none"`/`"-"`, `options` must be a string,
`mountPoint` (when set) must be an absolute path with no empty/`.`/`..`
segment, `fsType` must be a non-empty string, `mountOptions` must be a
string.

## Rendering: `nix/crypttab.nix`'s `render`

`render entries` first calls `validate`, then for every volume, in
sorted-by-name order (`builtins.attrNames`), composes its crypttab(5) line
and, when `mountPoint` is set, its `.mount` unit name and content. The
returned manifest is a plain JSON-ready attrset — there is no store object
to build here: every string this module emits is built from validated,
punctuation-light fields it already controls, unlike `nix/etc.nix`'s
arbitrary user-declared `text` bytes.

```json
{
  "version": 1,
  "crypttabContent": "data /dev/disk/by-uuid/... none luks,discard\n",
  "volumes": [
    {
      "name": "data",
      "device": "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000",
      "keyFile": "none",
      "options": "luks,discard",
      "crypttabLine": "data /dev/disk/by-uuid/... none luks,discard",
      "mountPoint": "/mnt/data",
      "fsType": "ext4",
      "mountOptions": "defaults",
      "mountUnitName": "mnt-data.mount",
      "mountUnitContent": "[Unit]\n...\n"
    }
  ]
}
```

### Mount unit naming and content

Mount unit filenames follow `nix/boot.nix`'s own documented rule verbatim:
drop the leading `/`, turn every remaining `/` into `-`, append `.mount`
(so `/mnt/data` → `mnt-data.mount`). A `mountPoint` whose own path
segments contain a literal `-` is not specially escaped — the same
documented, narrower limitation `nix/boot.nix`'s own writable-state mounts
accept.

```ini
[Unit]
Description=ubuntnix LUKS-backed mount for "<name>" (...)
After=systemd-cryptsetup@<name>.service
Requires=systemd-cryptsetup@<name>.service

[Mount]
What=/dev/mapper/<name>
Where=<mountPoint>
Type=<fsType>
Options=<mountOptions>

[Install]
WantedBy=local-fs.target
```

`systemd-cryptsetup@<name>.service` is never declared or rendered by this
module — systemd's own `systemd-cryptsetup-generator(8)` synthesizes it
automatically at boot from a real `/etc/crypttab`. `<name>` is used
literally in `Requires=`/`After=`, never escaped, which is safe for every
name `validate` accepts (see "Why mapper names can't contain `-`" above).

### Interop with `nix/filesystems.nix`

A LUKS volume's content can be mounted either of two ways — not mutually
exclusive designs, just two attribute names to write to:

1. This module's own `mountPoint` field (renders its own `.mount` unit
   with the `Requires=`/`After=` wiring already baked in), or
2. {doc}`filesystems`'s `ubuntnix.fileSystems."<mp>".device =
   "/dev/mapper/<name>";`, which recognizes the `/dev/mapper/<name>` shape
   structurally and renders the identical dependency wiring into its own
   mount unit.

See {doc}`filesystems`'s own "Interop with `nix/crypttab.nix`" section for
the full reasoning — neither file has cross-domain visibility into the
other's declarations at eval time, so this composes without either module
importing the other.

`perSystem.packages.crypttab-manifest-proof` forces `validate`/`render`
against a fixed example declaration at eval time, the same role
`etc-proof`/`pro-manifest-proof` play for their own files.

## Planning: `bin/ubx-crypttab plan`

```
ubx-crypttab plan --manifest FILE [--old-manifest FILE] [--observed FILE] [--out FILE]
```

Two resources, planned independently:

- **`/etc/crypttab`** — one shared file, diffed as a single whole-file
  unit against `observed.crypttabContent`. A `write-crypttab` action is
  emitted iff the desired content differs.
- **Per-volume `.mount` units** — diffed exactly like `nix/etc.nix`'s own
  per-path entries: absent → `create-mount`, present-but-different →
  `update-mount`, present-and-identical → no action. A volume's mount unit
  present in `--old-manifest` but dropped from the new manifest and still
  observed on disk → `remove-mount` (mirrors `bin/ubx-etc`'s own "removal
  only applies to previously-managed entries" scope rule).

Actions are always emitted in a fixed order: `write-crypttab` first (if
needed), then `create-mount`/`update-mount` for each volume in the new
manifest's own declaration order, then `remove-mount` for each dropped,
still-observed unit in the old manifest's own declaration order. Content
bytes are never embedded in the plan — only a target sha256; `--out`
writes to a file (default: stdout).

### Observing state: `bin/ubx-crypttab observe`

```
ubx-crypttab observe --crypttab-file FILE --units-dir DIR [--out FILE]
```

Reads a real (or fixture) `/etc/crypttab` path plus a real (or fixture)
mount-units directory and emits the observed-state JSON `plan` consumes —
`plan` itself never touches a filesystem.

## Executing: `bin/ubx-crypttab-apply`

```
ubx-crypttab-apply --plan FILE --manifest FILE [--crypttab-file FILE] [--units-dir DIR] [--apply | --dry-run]
```

A thin executor: it issues the plan's own actions, in the plan's own
order, with no independent judgment. Real content is re-read from
`--manifest` — the same file `bin/ubx-crypttab plan` was given — never
from the plan itself, which carries only a target sha256.

| Action | What `bin/ubx-crypttab-apply` does |
|---|---|
| `write-crypttab` | atomically `install -D -m 0600` the manifest's `crypttabContent` to `--crypttab-file` (default `/etc/crypttab`) |
| `create-mount` / `update-mount` | atomically `install -D -m 0644` the matching volume's `mountUnitContent` to `--units-dir/<unitName>` (default `/etc/systemd/system`) |
| `remove-mount` | `rm -f` the target unit file — idempotent |

Mode `0600` on `/etc/crypttab` matches every real distro's own packaged
permissions (crypttab(5) may carry a keyfile path in a real deployment
even though this groundwork's declared entries never do); `0644` on a
mount unit, since it is not secret material.

This executor deliberately never runs `systemctl daemon-reload` or
restarts a mount unit itself — that belongs to whatever orchestrates the
whole rebuild/switch, once a later issue wires this domain into
`bin/ubx`'s `execute_domains` the way {doc}`etc`/{doc}`systemd`/{doc}`home`
already are.

**Dry-run by default.** `--dry-run` (the default) prints the `install`/
`rm` calls it would run; `--apply` actually runs them. Fully exercisable
unprivileged against a temp `--crypttab-file`/`--units-dir` — writing
there never needs root; a real `/etc/crypttab`/`/etc/systemd/system` write
in production does, but that privilege requirement is the caller's
problem, not something this script checks.

## Where this is proven

- `tests/unit/175-crypttab-flake-wiring.sh` statically greps
  `nix/crypttab.nix` for its real `throw` and `flake.lib.crypttab`
  wiring — this harness has no `nix` binary, so it cannot evaluate the
  module itself.
- `tests/unit/176-ubx-crypttab-plan.sh` exercises `bin/ubx-crypttab plan`/
  `observe` against hand-crafted manifest/observed fixtures.
- `tests/unit/177-ubx-crypttab-apply-executor.sh` and
  `tests/unit/233-ubx-crypttab-apply-idempotent.sh` exercise
  `bin/ubx-crypttab-apply`'s dry-run/apply output and its idempotency
  (re-applying an already-converged plan is a no-op) against temp
  `--crypttab-file`/`--units-dir` fixtures.

What this does **not** yet prove: there is no flake-evaluated proof target
(no `packages.crypttab-manifest-proof` build assertion beyond eval-time
forcing), no example config declares a `ubuntnix.crypttab` volume, and
there is no QEMU/e2e test that boots an image with a real LUKS volume and
asserts it unlocks and mounts — unlike {doc}`home` or the {doc}`filesystems`/
{doc}`localization` parity images, this domain's proof stops at the
planner/executor's own unit tests.

## Where to track progress

`nix/crypttab.nix`, `bin/ubx-crypttab`, and `bin/ubx-crypttab-apply` land at
milestone **M4** (`SPEC.md` §11, issue #83) as groundwork only. Wiring this
domain into `bin/ubx`'s `execute_domains` the way {doc}`etc`/{doc}`systemd`/
{doc}`home` already are, and the real guided-install LUKS flow (formatting
a disk, prompting for a passphrase, `cryptsetup luksFormat`) are both
separate, not-yet-scheduled M7 work per `SPEC.md` §8.3/§11.
