# The generation model

```{admonition} Partially implemented (M2, issue #25): planner only
:class: note

`bin/ubx-generations` exists in the repository as of milestone **M2**
(`SPEC.md` §4.2, §4.3; issue #25) and everything described below is real:
it allocates generation directories, writes/reads their manifests,
maintains the `current`/`previous` pointers, and computes retention/GC
plans. It is deliberately **planner-only** — it never activates anything
(no `/etc` generation, no unit restarts, no soft-reboot, no bootloader
install) and never deletes a generation directory or a store artifact.
`prune-plan`/`gc-plan` print what a retention policy WOULD do; nothing is
removed until real activation and garbage collection land as `ubx` verbs
in a later issue (**#29**). Nix/flake wiring of `ubuntnix.generations.retain`
into this tooling is also deferred, until issue #10's GRUB renderer merges
(see "Interface with the GRUB renderer" below).
```

Every `ubx rebuild` (once implemented) produces a new numbered
**generation**: a self-contained record of the rootfs image, kernel, root
device, kernel parameters, and (as later milestones populate them) the
generated `/etc` tree and users/snap manifests that made up the machine at
that point in time. `bin/ubx-generations` is the tool that owns the
on-disk representation of that record, independent of whatever eventually
activates or deletes generations.

## On-disk layout

Generations live under a root directory, `$ROOT` — `/ubx/var/generations`
by default (`SPEC.md` §4.2's "writable state ... /ubx"), overridable via
`--root` or `UBX_GEN_ROOT` (`--root` wins) so the tool is fully testable
against a throwaway fixture directory with no privileges and no `/ubx`
present at all:

```text
$ROOT/
  <N>/
    manifest        one directory per generation; N a plain, non-padded
                     non-negative integer (see "Numbering" below)
  .next-index        persistent allocation counter
  current -> <N>      symlink: the generation the tooling last created
  previous -> <N>      symlink: whatever `current` pointed at just before
                        the most recent `create`
```

Directory names are plain integers ("3", not "003") — a zero-padded scheme
needs a width decided up front and either wraps or needs a migration once
generation numbers exceed it. Nothing in the tool relies on lexicographic
directory ordering: every listing is numerically re-sorted (`sort -n`)
before use.

## Numbering

Generation numbers come from a **persistent monotonic counter**
(`.next-index`), not `max(existing dirs) + 1`. The two agree in the common
case, but a future garbage collector (issue #29) is allowed, per the
retention rule below, to delete the *highest-numbered* generation while a
lower-numbered one survives — a machine can be booted into an old
generation after a rollback while a newer, never-booted generation is
neither booted nor previous, and so is a valid prune candidate even though
its number is the highest on disk. `max(existing)+1` would then reuse a
number that already existed; the persistent counter never does.

## current vs. booted

`current` and `previous` are bookkeeping pointers `bin/ubx-generations`
maintains itself: `current` is "the generation the last `create` produced",
`previous` is "whatever `current` pointed at right before that". They are
**not** the same thing as "the generation the running kernel actually
booted" — this tool has no privileged way to determine that (reading
`/proc/cmdline` or a GRUB environment block is activation tooling's job,
issue #29) and deliberately doesn't try.

Because of that, every retention-aware subcommand (`prune-plan`, `gc-plan`,
`emit-grub-list`) takes `--booted` as an **explicit, caller-supplied**
argument rather than reading it off disk — the real booted generation is
activation's business to know and this tool's business to plan around once
told. `rollback-target` defaults `--booted`/`--previous` to the on-disk
`current`/`previous` pointers only as a convenience for ad hoc/manual use;
a real `ubx rollback` is expected to pass its own observed booted
generation explicitly.

## Manifest format

Each generation's `manifest` file is flat `KEY=value`, one field per line —
no JSON, no `jq` — chosen because these files must also be readable later
by on-device activation tooling running in a minimal environment where a
JSON parser is a dependency to justify. Values are unquoted and must be
single-line; `create` validates this at write time.

| Field | Meaning |
|---|---|
| `GEN_INDEX` | the generation number (redundant with the directory name, kept so a manifest is self-describing out of context) |
| `GEN_TITLE` | human label, e.g. "generation 3" or a caller-given one |
| `GEN_CREATED` | ISO-8601 UTC creation timestamp |
| `GEN_ROOTFS_IMAGE` | store path of the rootfs image (`SPEC.md` §4.2) |
| `GEN_KERNEL_PATH` | store path of the kernel |
| `GEN_INITRD_PATH` | store path of the initrd |
| `GEN_ROOT_DEVICE` | root device spec passed to the kernel |
| `GEN_KERNEL_PARAMS` | kernel command line, verbatim |
| `GEN_ETC_REF` | store path of the generated `/etc` tree (extension point; populated once `/etc` generation lands, issue #29) |
| `GEN_USERS_MANIFEST` | store path of the users/passwd manifest (extension point; interim/SSH-key-only per `SPEC.md` §11 until fully populated) |
| `GEN_SNAP_MANIFEST` | store path of the snap manifest (extension point; snaps land at M3) |

The last three fields are legally empty today (`create` defaults them to
`""`, and every consumer treats an empty value as "no reference") — a
later milestone starts populating an existing field rather than changing
the manifest shape.

Every reader parses the manifest with `sed`/`awk` (via the script's
`manifest_get` helper), never by `source`-ing it: even though the format
happens to be valid POSIX shell, a corrupted or tampered-with manifest then
can't execute arbitrary code just by existing.

## Retention (`SPEC.md` §4.3)

Retention keeps the newest `N` generations, **union** the currently-booted
generation, **union** the previous generation — booted and previous are
always exempt from collection, regardless of `N` (including `N=0`, which
still keeps booted/previous and nothing else). `N` (`--retain`) is either a
count or the literal `all`, mirroring the `ubuntnix.generations.retain`
option (a count, or `"all"`) once it is wired up.

`prune-plan --retain N --booted B [--previous P]` prints the generation
numbers this policy would drop — planning only, nothing is deleted.

## Garbage-collection planning (`SPEC.md` §4.3, G4)

A generation's manifest names several store-path references (the fields
above, minus `GEN_ROOT_DEVICE` — a device spec — and `GEN_KERNEL_PARAMS` —
a command-line string, neither of which is an artifact). `gc-plan` unions
every reference from every generation still on disk, cross-references each
against a retained set (the same selection `prune-plan` computes, or an
explicit `--select` list), and prints:

```text
STATUS<TAB>PATH<TAB>REFERRING_GENERATIONS
```

`STATUS` is `KEEP` if **any** retained generation's manifest references
`PATH` — including when a generation about to be dropped shares that path
with a retained one (an unchanged kernel across two generations, say) —
otherwise `COLLECT`. This is the offline-rollback guarantee from `SPEC.md`
G4: a store artifact is only ever a collection candidate once no retained
generation can still reach it.

## Interface with the GRUB renderer

Issue #10's GRUB config renderer, `bin/ubx-gen-grub-cfg`, consumes a plain
generation-list file: one line per generation, six TAB-separated fields —
`index`, `title`, `kernelPath`, `initrdPath`, `rootDevice`, `kernelParams`
(the last field, verbatim to the end of the line, may contain spaces or be
empty) — with `#`-prefixed and blank lines allowed, and never reorders what
it's given.

`ubx-generations emit-grub-list` is the one place that renders exactly
that shape, and therefore the one place that owns menu ordering: the
on-disk `current` generation first (if it's part of the selection), then
the rest of the selection newest-first. Selection is either an explicit
`--select N[,N...]` list or the same `--retain`/`--booted`/`--previous`
computation `prune-plan`/`gc-plan` use.

## Scope and what's next

This tool is data model plus pure planner only. Deliberately out of scope
here, tracked for later issues:

- **Activation** — generating `/etc`, restarting changed units, soft-
  rebooting into a changed image, installing GRUB entries (issue #29).
- **Real deletion** — actually removing a generation directory or a store
  artifact `gc-plan` marks `COLLECT` (issue #29).
- **Flake/Nix wiring** — surfacing `ubuntnix.generations.retain` as a real
  module option that calls into this tool (deferred until issue #10
  merges, to avoid colliding with its GRUB-renderer work landing in the
  same area).

`ubx rebuild switch|boot|test` and `ubx rollback` are expected to shell out
to `bin/ubx-generations` the same way `ubx update`'s archive-pin refresh
shells out to `bin/ubx-resolve` — see {doc}`workflows` for the day-to-day
operational picture this tool is one building block of.
