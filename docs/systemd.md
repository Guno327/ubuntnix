# Systemd units and services: declaration, planning, execution

```{admonition} Implemented standalone (M2, issue #27); activation wiring deferred
:class: note

`nix/systemd.nix`, `bin/ubx-systemd`, and `bin/ubx-systemd-apply` exist in
the repository as of milestone **M2** (`SPEC.md` §4.3 switching-table row
1 "`/etc`, systemd units/services | generate + diff + restart changed
units (switch-to-configuration equivalent)", §6, §7; issue #27):
declaration, eval-time validation, JSON manifest rendering, the ordered
unit-activation planner, and the thin executor are all real and
unit-tested (`tests/unit/120-systemd-plan-basic.sh` through
`124-systemd-observe-report-apply.sh`). **Wiring this into a real running
system's `ubx rebuild switch`** is explicitly deferred, the same way
issue #26's `bin/ubx-etc-apply` and issue #28's `ubx-users execute` were
each unit-tested standalone with real activation-path wiring left for
later (see {doc}`users`'s own "Scope" section). Nothing on this page
describes a behavior observable on a running ubuntnix system yet.
```

## Why this exists

`SPEC.md` §4.3's switching table gives `/etc` and systemd units/services a
combined row with a downtime budget of **none**: activation must generate
+ diff + restart only what changed — the "switch-to-configuration"
equivalent this project's whole live-switch story (G3) depends on. That
requires the same split every other convergent primitive in this project
uses: a **compile step** (`nix/systemd.nix`, declaration -> content-hashed
manifest), a pure **planner** (`bin/ubx-systemd`, manifest diff -> ordered
action plan), and a thin **executor** (`bin/ubx-systemd-apply`, action
plan -> real `systemctl` calls) — kept separate so the planner (every
actual decision: what changed, whether a restart is safe, how many
`daemon-reload`s are needed) is testable in total isolation, with
hand-crafted fixture manifests, no root, no live systemd, and no `nix`
binary required.

## The declaration surface

`SPEC.md` §6 gives two primitives, both under `ubuntnix.systemd`:

```nix
ubuntnix.systemd.units."myapp.service" = {
  text = ''
    [Unit]
    Description=my app

    [Service]
    ExecStart=/usr/bin/myapp

    [Install]
    WantedBy=multi-user.target
  '';
  # source = ./files/myapp.service;   # exactly one of text/source
  enable = true;                       # default true
  mask   = false;                      # default false
};

ubuntnix.systemd.services.cups = {
  enable = false;   # packaged-unit STATE ONLY -- cups.service ships with
  mask   = false;   # the cups package; no content is declared here.
};
```

`units.<name>` declares a unit whose **content this project owns** — the
attribute name is the full unit name (`"myapp.service"`, always including
its suffix), and exactly one of `text`/`source` must be set, mirroring
`ubuntnix.etc`'s own entries byte for byte (same reasoning: declared
content is routed through a real Nix store object, never spliced as raw
shell text, to sidestep heredoc-delimiter corruption — see
`nix/etc.nix`'s "Rendering" for the full argument, which `nix/systemd.nix`
reuses verbatim).

`services.<name>` declares **state only** for a unit some Ubuntu package
already ships — a *bare* name (`cups`, no suffix; it always resolves to
`<name>.service`) with no content fields at all. Declaring `text`/`source`
under `services` is an eval-time error — use `units` for a unit this
project fully owns.

Every declared entry is validated at evaluation time
(`nix/systemd.nix`'s `validate`, collecting *every* violation into one
`throw`, mirroring `nix/etc.nix`'s own posture): unit names must match a
recognized class suffix (below); bare service names must be a safe,
suffix-free identifier; `enable`/`mask` must be booleans; and a name may
not be declared by both `units` and `services` at once (e.g.
`units."cups.service"` and `services.cups` colliding).

## Unit classes and the refuse-restart rule

Every unit name's suffix maps to a **class**, and every class is either
**restart-safe** or a **refuse-restart** class. This is the load-bearing
rule issue #27 exists to enforce: a *content* change to a refuse-restart
unit is still installed and reloaded, but this project **never** issues an
automatic restart for it — only a diagnostic action naming the unit and
class, left for a human to act on deliberately.

| Class | Restart posture | Why |
|---|---|---|
| `.service` | restart-safe | the ordinary case: stop + start converges it to the new definition, exactly what "switch-to-configuration" means for a service. |
| `.timer` | restart-safe | same convergence model as a service — restarting re-arms it against the new schedule. |
| `.path` | restart-safe | same — restarting re-establishes the watched path. |
| `.scope` | restart-safe | transient, process-tracking only; nothing about restarting one is unsafe by construction. |
| `.socket` | **refuse-restart** | restarting a listening socket can drop already-accepted, in-flight connections and briefly unbind the address — the safe idiom is to leave a changed socket unit's running instance alone until the next deliberate restart/reboot. |
| `.mount` | **refuse-restart** | remounting can fail outright with `EBUSY` while anything holds the mountpoint open; unmounting live storage out from under running processes is destructive by construction. |
| `.swap` | **refuse-restart** | toggling swap live changes memory-pressure characteristics — not a switch-to-configuration decision to make unattended. |
| `.target` | **refuse-restart** | a target has no executable state of its own (no `ExecStart`); "restarting" one only re-fires whatever depends on it, never what a content-only change (e.g. a reordered `Wants=`) should trigger by itself. |
| `.device` | **refuse-restart** | kernel/udev-managed; not something this tool starts or stops at all. |
| `.slice` | **refuse-restart** | a pure cgroup grouping node, like a target — no executable state to restart. |

This table is kept as data in **two** places — `nix/systemd.nix`'s
`unitClasses` and `bin/ubx-systemd`'s own mirrored `UNIT_CLASSES` — the
same dual-enforcement posture `nix/etc.nix`/`bin/ubx-etc` already take for
machine-local mutable exceptions. `bin/ubx-systemd plan` re-derives a
unit's class from its own name and **refuses outright** (fail-closed, no
plan printed) if a manifest's own `refuseRestart` flag ever disagrees with
what the name's suffix implies — that should never happen from a manifest
`nix/systemd.nix` produced, so disagreement means a bug or a hand-tampered
file.

## The manifest schema

`nix/systemd.nix`'s `render { system; name; entries; }` validates
`entries` (`{ units; services; }`), then produces:

```text
$out/manifest.json     { version = 1; units = [ { name; class; refuseRestart;
                          hasContent; sha256; enable; mask; }, ... ] }
$out/tree/<name>       one regular file per units.<name> entry with content
                        (services entries have no tree/ file)
```

```json
{
  "version": 1,
  "units": [
    { "name": "myapp.service", "class": "service", "refuseRestart": false,
      "hasContent": true, "sha256": "<64 hex>", "enable": true, "mask": false },
    { "name": "cups.service", "class": "service", "refuseRestart": false,
      "hasContent": false, "sha256": null, "enable": false, "mask": false }
  ]
}
```

`bin/ubx-systemd plan` consumes exactly this shape for both
`--old-manifest`/`--new-manifest`. `--observed-manifest` is the analogous
*observed* shape — what a real machine (or `bin/ubx-systemd observe`)
reports right now:

```json
{
  "version": 1,
  "units": [
    { "name": "myapp.service", "sha256": "<64 hex | null>",
      "enabled": true, "masked": false, "active": true }
  ]
}
```

`sha256: null` means "no managed file is currently on disk for this unit"
(the fresh/never-installed case, or a `services.*`-only packaged unit that
this project only ever toggles state on).

## Planning: `bin/ubx-systemd plan`

```
ubx-systemd plan --old-manifest FILE --new-manifest FILE \
                  --observed-manifest FILE [--out FILE|-]
```

A pure function of its three inputs — never touches a real system.
Basing content/state comparisons on `--observed-manifest` (not
`--old-manifest`) matches `SPEC.md` §4.3's activation model exactly: a
unit hand-edited or hand-`systemctl enable`d outside `ubx` since the last
switch still converges correctly on the next switch, because the
comparison is always against reality. `--old-manifest` is consulted for
exactly one thing: which unit names were previously *managed*, so
`remove-unit-file`/`stop`/`disable` on a dropped unit only ever targets a
name this project itself declared before (mirrors `bin/ubx-etc`'s own
"Removal scope" rule).

### The plan algorithm

For every unit in the **new** manifest (`obs` defaults to
`{sha256: null, enabled: false, masked: false, active: false}` if absent
from observed):

| Condition | Action |
|---|---|
| `hasContent` and no observed file (`sha256` is `null`) | `write-unit-file` (create) |
| `hasContent` and observed `sha256` differs | `write-unit-file` (update-content) |
| `mask` differs from observed `masked` | `mask` / `unmask` |
| `enable` differs from observed `enabled`, and target `mask` is false | `enable` / `disable` (a `disable` transition also plans `stop` first if observed `active`) |
| content changed, unit is a refuse-restart class | `refuse-restart` (diagnostic only — see class table above) |
| content changed, unit is brand new, enabled and unmasked | `start` |
| content changed, unit already existed, and (observed active OR target enabled+unmasked) | `restart` |
| content unchanged, but transitioning disabled→enabled while inactive | `start` |

For every unit in the **old** manifest but not the **new** one: `stop` if
observed active, `disable` if observed enabled, `remove-unit-file` if the
old entry had content and the observed entry still shows a file.

### Exactly one coalesced `daemon-reload`

Real systemd only needs `daemon-reload` after a unit *file* is added,
changed, or removed — never merely for enable/disable/mask/start/stop,
which read the already-loaded unit state directly. Exactly one
`daemon-reload` action is emitted, if and only if at least one
`write-unit-file`/`remove-unit-file` action was planned — regardless of
how many unit files actually changed.

### Output and ordering

A single JSON object:

```text
{ "version": 1, "daemonReload": true, "actions": [ { "op": "...", "unit": "...", "...": "..." }, ... ] }
```

Actions are grouped by `op` in this fixed sequence (each group sorted by
unit name): `write-unit-file` (create, then update-content) →
`remove-unit-file` → `daemon-reload` (at most one) → `stop` → `disable` →
`mask` → `unmask` → `enable` → `start` → `restart` → `refuse-restart`.
This order is itself operationally meaningful (a unit file must exist and
be reloaded before anything reads it; a stop precedes a disable) as well
as fully deterministic — an empty (fully converged) input produces
`"actions": []`, `"daemonReload": false`, and exit `0`.

## Observing real (or fixture) state: `bin/ubx-systemd observe`

```
ubx-systemd observe --dir DIR [--state FILE] [--out FILE|-]
```

Walks `DIR` (a flat directory — systemd unit directories are not
recursive — real usage points this at `/etc/systemd/system`) for regular
files, hashing each; `--state FILE` (optional) supplies the
`enabled`/`masked`/`active` booleans a real `systemctl is-enabled`/
`is-active`/`systemctl show` query would report, keyed by unit name. A
unit named in `--state` with no file on disk still appears with
`sha256: null` — exactly a `services.*`-only packaged unit's observed
shape.

## Reporting: `bin/ubx-systemd report`

```
ubx-systemd report --plan FILE [--out FILE|-]
```

Renders an already-computed plan as human-readable text — feeds `ubx
diff` / the converge report (`SPEC.md` §7). Kept as a separate subcommand
from `plan` itself (mirrors `bin/ubx-users`' own `plan`/`execute` split):
the machine-readable plan stays inspectable and diffable on its own before
anything renders prose from it.

## Executing: `bin/ubx-systemd-apply`

```
ubx-systemd-apply --plan FILE [--unit-dir DIR] [--content-dir DIR] [--apply | --dry-run]
```

A thin executor: it issues the plan's own actions, in the plan's own
order, with **no independent judgment** — every decision (what changed,
whether a restart is safe, how many `daemon-reload`s) already happened in
`bin/ubx-systemd plan`. `write-unit-file` installs
`--content-dir/<unit>` (`nix/systemd.nix`'s own `$out/tree/<name>` layout)
to `--unit-dir/<unit>` (default `/etc/systemd/system`); every other action
is a direct `systemctl <verb> <unit>` call. A `refuse-restart` action is
never translated into a command at all — it becomes a `#` comment marker,
surfaced but never executed.

**Dry-run by default.** `--dry-run` (the default) prints every command it
would run, one per line, and exits `0` without touching anything.
`--apply` actually runs them, but **refuses outright** if no `systemctl`
binary is found on `PATH` — a real "apply my systemd changes" request with
no systemd present is a hard misconfiguration, never silently downgraded
to a no-op (mirrors `bin/ubx-users`' own "`execute` never runs anything
itself" scope line, adapted: this executor *does* run commands under
`--apply`, but only ever exactly what the plan already decided).

## Where to track progress

`nix/systemd.nix`, `bin/ubx-systemd`, and `bin/ubx-systemd-apply` land at
milestone **M2** (`SPEC.md` §11, issue #27). Wiring the whole thing into
`ubx rebuild switch|boot|test` against a real running system's real
`/etc/systemd/system` and real `systemctl` is later work, tracked
alongside {doc}`etc`'s and {doc}`users`'s own activation-wiring follow-ups.
