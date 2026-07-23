# `ubx`: the rebuild/rollback/diff orchestrator

```{admonition} Real orchestration, two pieces deliberately deferred
:class: note

`bin/ubx`'s `rebuild switch|boot|test`, `rollback`, `list-generations`, and
`diff` are implemented and unit-tested as of milestone **M2** (`SPEC.md`
§4.3, §4.5; issue #29): they register generations via `bin/ubx-generations`,
compute each domain's plan via `bin/ubx-etc` / `bin/ubx-systemd` /
`bin/ubx-users`, and own the GRUB-default record (`switch`/`boot` set it,
`test` never does). `ubx update` remains the pre-M1 stub described in
{doc}`workflows`. Two things this page is explicit about are still
deferred: **on-device Nix evaluation** (building a rootfs image, an `/etc`
tree, or a systemd unit tree from the flake does not exist yet — `rebuild`
takes already-built store paths/manifest files as flags instead) and
**soft-reboot into a changed rootfs image** (issue #30 — `switch`/`test`
print a "pending #30" notice and never attempt it). See "What's real, what
isn't" below for the full breakdown, domain by domain.
```

## What `ubx rebuild` does

Three verbs, mirroring NixOS's `nixos-rebuild`:

- **`switch`** — registers a new generation, activates all three live
  domains (etc, systemd, users — see below for how far each one's
  activation actually goes), and sets the GRUB default.
- **`boot`** — registers a new generation and sets the GRUB default. No
  live activation at all.
- **`test`** — activates all three live domains, exactly like `switch`,
  but **never** touches the GRUB default — a plain reboot returns to
  whatever generation was already the default.

Every verb computes the same domain-level plan first (etc, then systemd,
then users — a fixed order mirroring `SPEC.md` §4.3's switching table) and
prints a deterministic touched-domains report before doing anything else:

```text
ubx rebuild switch: generation 3 (from generation 2)
domains:
  etc: 2 action(s) touched (0 drift)
  systemd: 1 action(s) touched
  users: nothing declared (no old or new users manifest)
```

A domain is reported as **"nothing declared"**, not planned at all, only
when *neither* the old nor the new generation names anything for it —
exactly `bin/ubx-generations`' own "legally empty fields" posture. Any
other combination (including a generation that *drops* a previously
declared domain entirely) is planned and reported normally.

## `--dry-run`: a true, side-effect-free preview

`--dry-run` computes and prints the exact same touched-domains report
without registering a generation, without writing the GRUB-default marker,
and without attempting any execution — needs no root, no live systemd, and
touches nothing at all under `--root`. This is what
`tests/unit/131-ubx-rebuild-dry-run-planning.sh` exercises directly.

Without `--dry-run`, a generation IS registered (a plain filesystem
operation — no root required), and the GRUB-default marker IS written per
the matrix below — only the optional `--apply` flag (real `systemctl`
calls, gated exactly like `bin/ubx-systemd-apply` already gates it) needs
anything privileged.

## The GRUB-default matrix

The single most load-bearing behavior this issue adds, and the one
`tests/unit/132-ubx-grub-default-matrix.sh` asserts explicitly:

| Verb | Sets the GRUB default? |
|---|---|
| `switch` | yes |
| `boot` | yes |
| `test` | **never** |
| `rollback` | yes (moves it back to the resolved target) |

The record itself is `$ROOT/grub-default` — a bare generation number,
written atomically (temp file + rename, the same posture every other
writer in this project uses). Real bootloader programming (calling
`grub-editenv`/`grub-set-default` or an equivalent) is soft-reboot/image-
swap-adjacent activation work explicitly deferred to **issue #30** — this
marker is the durable, testable record a later issue's real bootloader
step is expected to read, the same way `bin/ubx-generations`' own
`current`/`previous` symlinks are read today.

## `ubx rollback [N]`

Resolves `N` (default: `previous`) via `ubx-generations rollback-target`,
re-converges the live domains from the resolved generation to it, and
moves the GRUB default back. The generation rolled back *from* is this
orchestrator's own **`booted`** marker (`$ROOT/booted`), not
`bin/ubx-generations`' `current` pointer — those are different concepts:
`current` only ever moves when a NEW generation is registered
(`bin/ubx-generations create`), so it goes stale exactly when you'd
expect it to (after a `rollback`, or after a `boot` that only registered a
generation without activating it). `switch`, `test`, and `rollback` each
update the `booted` marker after they actually converge live domains;
`boot` never does, matching its own "no live activation" scope.

## `ubx diff [A] [B]`

A read-only, domain-level diff between two generations' manifests, reusing
each domain's own `plan`/`report` machinery:

- no args — `previous` -> `current`
- one arg `A` — the `booted` generation -> `A`
- two args `A B` — `A` -> `B`

Observed state for the diff defaults to the FIRST generation's own
declared manifest — i.e. "assume it is exactly converged, show only what
moving to the second would change." Passing `--etc-observed`,
`--systemd-observed`, or `--passwd`/`--group`/`--shadow` overrides that
with a real, live-drift-aware comparison instead (the same override flags
`rebuild`/`rollback` accept).

## What's real, what isn't, per domain

Activation of each of the three domains is only as complete as that
domain's OWN issue left it — this orchestrator calls exactly as much of
each as exists and prints a clear notice for the rest, never inventing
execution machinery that belongs to another issue:

- **etc** — plan only. `bin/ubx-etc-apply`, referenced in `bin/ubx-etc`'s
  own header as future work, does not exist in this repository yet;
  `ubx rebuild switch|test` prints a "plan only, nothing written" notice
  for this domain instead of attempting anything.
- **systemd** — real, dry-run-by-default execution via
  `bin/ubx-systemd-apply` (see {doc}`systemd`). `--apply` attempts the
  real thing and requires `systemctl` on `PATH`, exactly as that script's
  own `--help` documents.
- **users** — `bin/ubx-users execute` only ever EMITS a shell script (see
  {doc}`users`'s own scope note); it never runs anything itself. `ubx
  rebuild switch|test` writes that script to disk and prints where, for a
  human (or later tooling) to run as root.

## The systemd-manifest seam

`bin/ubx-generations`' manifest schema (issue #25) carries `GEN_ETC_REF`
and `GEN_USERS_MANIFEST` fields, but no `GEN_SYSTEMD_REF` — `nix/systemd.nix`
was never wired into `nix/compose.nix` or that tool's `create` flags.
Rather than extend `bin/ubx-generations`' already-committed, already-tested
manifest schema, `bin/ubx` owns a small, separate, sibling file per
generation, `$ROOT/<N>/ubx-extra` (flat `KEY=value`, same format as that
tool's own manifest), recording the systemd manifest reference. If
`bin/ubx-generations` ever grows a real `GEN_SYSTEMD_REF` field, this
sidecar simply stops being read or written; nothing else in the
orchestrator's logic needs to change.

## Where to track progress

See {doc}`workflows` for the day-to-day operational picture and
`SPEC.md` §11 for the milestone plan; `SPEC.md` §4.3 and §4.5 are the
sections this page implements.
