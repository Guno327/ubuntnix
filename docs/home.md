# Per-user configuration (home modules)

```{admonition} Implemented and wired into ubx rebuild (M5, issue #98; live-QEMU proof, issue #105)
:class: note

`nix/home.nix`, `bin/ubx-home`, and `bin/ubx-home-apply` exist in the
repository as of milestone **M5** (`SPEC.md` §9 "Per-user configuration
(home modules)", §4.3 switching-table row "Home files, user services |
home-module activation into writable `/home` | none"; §2 G7 "Deep
per-user configuration ... first-class in the same flake"; issue #98):
declaration, eval-time validation, JSON manifest rendering, the
per-user diff-driven planner, and a thin executor are all real and
unit-tested. **Wiring this into `ubx rebuild`** is done too: `bin/ubx`'s
`execute_domains` builds and runs `bin/ubx-home-apply --plan ...
--content-dir ... --homes-dir ...` (`bin/ubx:1146`) under `--apply`/
`--dry-run` per the requested verb, driven by the `--home-manifest`,
`--home-observed`, `--homes-dir`, and `--home-content-dir` flags
(`bin/ubx:1366-1377`) — the same pattern `bin/ubx-etc-apply`/
`bin/ubx-systemd-apply` already use, one layer down: per declared user
instead of once for the whole system.

What is proven live, in CI, is a real QEMU boot: the `home-activation`
CI job builds `.#home-activation-proof` and runs
`tests/e2e/060-qemu-home-activation-e2e.sh`, which boots the image
across a real guest-initiated reboot and asserts (via serial-console
markers) that a declared user actually gets created, a declared file
lands with the right content/mode/ownership across two generations
without rewriting an unchanged file, and — bus permitting — a declared
per-user `systemctl --user` service gets enabled, restarted on content
change, and survives a real reboot via `loginctl enable-linger`. That
proof runs against a dedicated `home-activation-proof` fixture image,
**not** any `profiles.server`/`profiles.desktop` production image — see
"Where this is proven" below for exactly what that does and doesn't
cover.
```

## Why this exists

`SPEC.md` §2's goal G7 is explicit: "Deep per-user configuration (dotfiles,
XDG configs, per-user services) is first-class in the same flake" — not a
bolt-on dotfiles manager, not a separate tool a user runs by hand. §9 gives
it the same convergent-activation shape as every other primitive in this
project: a **compile step** (`nix/home.nix`, declaration -> a
content-hashed manifest), a pure **planner** (`bin/ubx-home`, manifest diff
-> an ordered action plan), and a thin **executor** (`bin/ubx-home-apply`,
action plan -> real filesystem/`systemctl --user` calls) — kept separate so
every actual decision (what changed, what needs restarting, how many
`daemon-reload`s) is testable in total isolation, with hand-crafted fixture
manifests, no root, and no live user session required.

As `nix/home.nix`'s own header puts it, this file is "`nix/etc.nix`'s
file-entry primitive and `nix/systemd.nix`'s unit-entry primitive, each
re-scoped per declared user": a home file is exactly an `ubuntnix.etc`
entry, and a home service is exactly an `ubuntnix.systemd.units` entry,
minus the knobs that only make sense at the whole-system level (see
"What's deliberately narrower than `/etc`/systemd" below).

Per-user *software* is explicitly **out of scope**: `SPEC.md` §9 is
unambiguous that "per-user software is system-level (snaps/debs) selected
per-user via modules; no per-user binary installation exists in this
model." This primitive only ever materializes **files** and **service
units** into a user's own `$HOME` — it has no notion of installing a
package for a user.

## The declaration surface

`SPEC.md` §9 gives one primitive, keyed by declared username, under
`ubuntnix.home`:

```nix
ubuntnix.home.gunnar.files.".bashrc" = {
  text = ''
    export EDITOR=vim
  '';
  # source = ./files/bashrc;   # exactly one of text/source
  mode  = "0644";               # default "0644"
};

ubuntnix.home.gunnar.files.".config/foo/config.toml" = {
  text = ''
    greeting = "hi"
  '';
};

ubuntnix.home.gunnar.services."backup.service" = {
  text = ''
    [Unit]
    Description=example per-user backup timer target

    [Service]
    ExecStart=/usr/bin/true
  '';
  enable = true;    # default true
  mask   = false;   # default false
};
```

`files.<path>` materializes a file at `$HOME/<path>`; `services.<name>`
materializes a `systemctl --user`-managed unit. `ubuntnix.home` is
deliberately independent of `nix/users.nix`'s own `userType` — like every
dendritic file in this project, it does not cross-import another file's
internals (`nix/home.nix`'s own header, "The declaration surface"), so a
username declared under `ubuntnix.home` is not currently cross-checked
against `nix/users.nix`'s own declared users at evaluation time.

### What's deliberately narrower than `/etc`/systemd

- **No owner/group knob on files.** A home file is *always* owned by the
  user whose namespace declared it — the same reasoning `nix/etc.nix`
  gives for its `owner`/`group` fields doesn't apply here, because there
  is only ever one correct value, and "a knob that could only ever safely
  be set to one value is not a knob worth having" (`nix/home.nix`'s own
  header).
- **Services are always fully-owned content**, never `nix/systemd.nix`'s
  packaged-state-only `services.<name>` shape — a user has no "packaged
  unit" analog to toggle state on, since per-user binary installation
  doesn't exist in this model.
- **Only three restart-safe unit classes**: `.service`, `.timer`,
  `.path` — the only classes both meaningful under `systemctl --user` and
  already restart-safe in {doc}`systemd`'s own class table. There is
  consequently **no `refuse-restart` action anywhere in this domain** —
  every home service is restart-safe by construction (a user session has
  no mount/swap/device units, and a bare user target/slice has no
  executable state a home declaration would ever author directly).

## Eval-boundary validation

Every declared user's `files`/`services` entries are checked at evaluation
time (`nix/home.nix`'s `validate`), collecting **every** violation across
the whole declaration into one `throw` — the same "never just the first"
posture every validator in this project takes:

- the username itself must look like a real username (mirrors
  `nix/users.nix`'s own username grammar);
- `files.<path>`: relative, no empty/`.`/`..` segment, safe character
  class (identical rule to `nix/etc.nix`'s own path check);
- `files.<path>`: exactly one of `text`/`source`;
- `files.<path>`: `mode` is 4 octal digits as a string (e.g. `"0644"`);
- `services.<name>`: a valid unit name ending in `.service`, `.timer`, or
  `.path`;
- `services.<name>`: exactly one of `text`/`source`;
- `services.<name>`: `enable`/`mask` are booleans.

## Compiling: `nix/home.nix`'s `render`

`render { system; name; users; }` validates `users`, then routes every
declared entry's bytes through a real Nix store object — never spliced as
raw shell text, identical reasoning to {doc}`etc`'s own "Rendering"
section. The result:

```text
$out/manifest.json                the JSON manifest (schema below)
$out/tree/<user>/files/<path>     one regular file per files entry
$out/tree/<user>/services/<name>  one regular file per services entry
```

```json
{
  "version": 1,
  "users": [
    {
      "name": "gunnar",
      "files": [
        { "path": ".bashrc", "sha256": "<64 hex>", "mode": "0644" }
      ],
      "services": [
        { "name": "backup.service", "class": "service", "sha256": "<64 hex>",
          "enable": true, "mask": false }
      ]
    }
  ]
}
```

Every array is sorted (by username, then by path/unit name) with no
explicit sort step — Nix attribute sets are already kept in
sorted-by-name order.

`perSystem.packages.home-proof` exercises `render` end to end against a
small fixture declaration (one user, one file, one service), the same
role `etc-proof`/`systemd-proof` play for their own files.

## Planning: `bin/ubx-home plan`

```
ubx-home plan --old-manifest FILE --new-manifest FILE \
              --observed-manifest FILE [--out FILE|-]
```

`bin/ubx-home` consumes exactly `nix/home.nix`'s manifest shape for both
`--old-manifest`/`--new-manifest`, plus a third, **observed**-state
manifest (see `bin/ubx-home observe` below) — the same
two-generations-plus-observed contract `bin/ubx-etc`/`bin/ubx-systemd`
use, and the same reasoning: comparisons are always against **reality**,
not against the last generation's own record of itself, so a file
hand-edited or a service hand-toggled outside `ubx` since the last switch
still converges correctly on the next switch. `--old-manifest` is
consulted only to know which paths/units were previously *managed*, so
`remove-file`/`stop`/`disable` only ever targets something this project
itself declared before.

This planner runs **both** algorithms — a `nix/etc.nix`-shaped file diff
and a `nix/systemd.nix`-shaped service diff (minus the refuse-restart
classes) — once per declared user, producing one combined, per-user-grouped
action list.

### Files

Identical shape to {doc}`etc`'s own algorithm, scoped to one user's files
array and with no owner/group in the diff (a home file entry carries none —
see "The declaration surface" above; drift toward a wrong owner is still
observed and reported as `drift-file` metadata, informational only):

| Condition | Action |
|---|---|
| path in new, absent from observed | `install-file` (create) |
| path in new, present, sha256 differs | `install-file` (update-content) |
| path in new, present, sha256+mode match | *(no action — converged)* |
| path in new, present, sha256 matches, mode differs | `update-file-metadata` |
| path in old but not new, present in observed | `remove-file` |
| path in observed, in neither old nor new | `drift-file` |

### Services

Identical shape to {doc}`systemd`'s own algorithm, restricted to the three
restart-safe classes (no `refuse-restart` branch exists in this domain at
all):

- absent/`null` observed sha256 -> `write-service-file` (create); differing
  sha256 -> `write-service-file` (update-content);
- `mask` differs -> `mask`/`unmask`;
- `enable` differs (and not masked) -> `enable`/`disable` (`disable` also
  plans `stop` first if observed active);
- content change -> `start` (newly created + enabled + unmasked) or
  `restart` (pre-existing + (active or (enabled and unmasked)));
- content unchanged, disabled -> enabled while inactive -> `start`;
- dropped from new (was in old): `stop` if active, `disable` if enabled,
  `remove-service-file` if old had content and observed still shows one;
- exactly one `daemon-reload` **per user** IFF that user had at least one
  `write-service-file`/`remove-service-file` action — scoped per user since
  `systemctl --user daemon-reload` is itself a per-user-session operation.

### Ordering and output

Users are processed in sorted-name order. Within a user: file actions
first (grouped create/update-content/update-metadata/remove/drift, each
group sorted by path), then service actions in
`write -> remove -> daemon-reload -> stop -> disable -> mask -> unmask ->
enable -> start -> restart` order, each group sorted by unit name.

```text
{ "version": 1, "actions": [ {"op": "...", "user": "...", ...}, ... ] }
```

An empty (fully converged) input produces `"actions": []` and exit `0`.

## Observing real (or fixture) state: `bin/ubx-home observe`

```
ubx-home observe --homes-dir DIR --user NAME [--user NAME ...] \
                  [--state FILE] [--out FILE|-]
```

For each `--user`, walks `HOMES_DIR/<user>` recursively for regular files
(relative paths, sha256+mode observed — never descending into
`.config/systemd/user`, which is observed separately as service units)
and `HOMES_DIR/<user>/.config/systemd/user` (flat, one regular file per
unit) for service units. `--state FILE` (optional) supplies the
`enabled`/`masked`/`active` booleans a real, per-user `systemctl --user
is-enabled`/`is-active` query would report, keyed by `<user>` then
`<unit-name>`.

## Reporting: `bin/ubx-home report`

```
ubx-home report --plan FILE [--out FILE|-]
```

Renders an already-computed plan as human-readable text — feeds `ubx
diff` — kept separate from `plan` itself so the machine-readable plan
stays inspectable/diffable on its own.

## Executing: `bin/ubx-home-apply`

```
ubx-home-apply --plan FILE [--content-dir DIR] [--homes-dir DIR] [--apply | --dry-run]
```

A thin executor: it issues the plan's own actions, in the plan's own
order, with no independent judgment. Real content is read from
`--content-dir/<user>/files/<path>` or
`--content-dir/<user>/services/<name>` — exactly `nix/home.nix`'s own
`$out/tree/<user>/files|services/...` layout — since the plan itself only
ever carries a target sha256, never raw bytes.

| Action | What `bin/ubx-home-apply` does |
|---|---|
| `install-file` (create/update-content) | atomically `install -D -m MODE [-o user -g user]` into `--homes-dir/<user>/<path>`, creating parent directories |
| `update-file-metadata` | `chmod` (+ `chown` when root) an already-content-correct file; never rewrites its bytes |
| `remove-file` | `rm -f` — idempotent |
| `drift-file` | informational only, printed to stderr, never a filesystem call |
| `write-service-file` (create/update-content) | installs into `--homes-dir/<user>/.config/systemd/user/<name>`, same install + ownership posture as `install-file` |
| `remove-service-file` | `rm -f` |
| `daemon-reload` | `runuser -u USER -- systemctl --user daemon-reload` |
| `stop` / `disable` | best-effort (`|| :`) — a unit that may already be gone/not loaded must not fail the run |
| `mask` / `unmask` / `enable` / `start` / `restart` | fatal-if-they-fail, via `runuser -u USER -- systemctl --user <verb> <unit>` |

**Ownership**: exactly `bin/ubx-etc-apply`'s own posture applied to a
fixed target instead of a declared one — every install/chown call targets
`<user>:<user>` unconditionally whenever the caller's effective uid is 0;
when not running as root, ownership flags/calls are simply never emitted
(not attempted-then-swallowed), so this script stays exercisable by this
project's own unprivileged unit tests. `mode` (`chmod`) is always applied
regardless of privilege.

**Dry-run by default.** `--dry-run` (the default) prints every command it
would run and touches nothing. `--apply` with a service action present
but no `runuser`/`systemctl` on `PATH` refuses outright — a real "apply my
home services" request with no way to reach a user session is a hard
misconfiguration, never silently downgraded. `--apply` with only file
actions never requires either binary.

## Wired into `ubx rebuild`

`bin/ubx`'s `execute_domains` builds and runs `bin/ubx-home-apply --plan
... --content-dir ... --homes-dir ...` (`bin/ubx:1146`) under
`--apply`/`--dry-run` exactly like `bin/ubx-etc-apply`/
`bin/ubx-systemd-apply` are invoked right alongside it, independently of
secrets/pro/users (a home declaration never reads a secret or needs a
users cross-check). `ubx rebuild --help` exposes the knobs
(`bin/ubx:1366-1377`):

| Flag | Meaning |
|---|---|
| `--home-manifest PATH` | the new generation's declared per-user home manifest (`nix/home.nix`'s `render` output). Omitted entirely means "nothing declared for this domain". |
| `--home-observed FILE` | (default: synthesized from the OLD generation's own declared home manifest, assuming it is already fully converged) |
| `--homes-dir DIR` | the real (or, for tests, temp) `/home` root `bin/ubx-home-apply` targets (default `/home`) |
| `--home-content-dir DIR` | (default: alongside the new home manifest, its own `tree/` subdirectory — `nix/home.nix`'s `render`'s own `$out/tree` layout) |

## Where this is proven

`tests/unit/182-home-flake-wiring.sh` statically greps `nix/home.nix` for
its real `throw` (a negative eval-boundary proof is deliberately not
wired up as a `packages.*` output — poisoning `nix flake check` for the
whole flake — the same posture `nix/etc.nix`/`nix/systemd.nix` take).
`bin/ubx-home`'s `plan`/`observe`/`report` and `bin/ubx-home-apply`'s
executor logic are covered by their own `tests/unit/` scripts.

The live, running-system proof is `tests/e2e/060-qemu-home-activation-e2e.sh`,
run by the `home-activation` CI job: it boots `.#home-activation-proof`
(a dedicated fixture disk image — see `nix/boot.nix`'s
`homeActivationDiskImageDrv`) in QEMU, across one real guest-initiated
reboot, and asserts five ordered serial-console markers — a declared user
really gets created, a declared file's content survives an unrelated
second generation unchanged (mtime+inode asserted stable, not merely
"content still matches"), and, bus permitting, a per-user
`systemctl --user` service gets enabled/restarted/auto-started across a
real reboot via `loginctl enable-linger`. This proof runs **only** against
that dedicated fixture image — no `profiles.server`/`profiles.desktop`
production image declares an `ubuntnix.home` user today, so this whole
domain's live-activation guarantee currently exists **only** in that
fixture, not in a shipping profile.

## Where to track progress

`nix/home.nix`, `bin/ubx-home`, and `bin/ubx-home-apply` land at milestone
**M5** (`SPEC.md` §11, issue #98), wired into `ubx rebuild switch|boot|
test` the same milestone. The live-QEMU activation proof (issue #105)
lands alongside. What is not yet true: no shipping `profiles.server`/
`profiles.desktop` module declares any `ubuntnix.home` users, and
per-user software installation remains explicitly out of scope per
`SPEC.md` §9.
