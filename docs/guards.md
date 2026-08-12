# Mutation guards: apt, dpkg, snap

```{admonition} Implemented standalone (M2); wired and proven in the switch-loop proof image only
:class: note

`bin/ubx-guard-apt`, `bin/ubx-guard-dpkg`, and `bin/ubx-guard-snap` exist in
the repository as of milestone **M2** (`SPEC.md` §7, issue #31): each is a
real, unit-tested script (`tests/unit/090-guard-lib.sh` through
`093-guard-snap.sh`) that decides block-vs-pass for a given command line.
**Installing them into a composed runtime image — diverting the real
binaries aside and putting a guard in their place — is real**, but so far
only inside `nix/boot.nix`'s switch-loop proof image
(`switchLoopExtraFilesScript`, which diverts `apt`/`apt-get`/`dpkg` to
`*.ubx-real` and installs the `ubx-guard-*` scripts in their place — issue
#10's file-injection mechanism this depended on has landed, since
`bootRootfs`'s own file-writing pattern turned out to be that mechanism).
**No server or desktop profile image installs the guards yet** — see
["What is deferred"](#what-is-deferred) below for exactly what is still
missing.
```

## Why guards exist

`SPEC.md` §7 ("Drift prevention") requires that imperative package
mutation on a running system be **blocked, not merely reverted**: the
flake is the complete source of truth, and a human running `apt install`
or `snap remove` by hand on a live machine is exactly the kind of drift the
whole project exists to prevent (§3, "No imperative package operations").

A read-only rootfs already makes `dpkg`-level mutation impossible by
construction once an image is composed (§4.2) — but that alone still lets
a mutating command *start*, acquire a lock, and fail confusingly deep
inside `dpkg`/`snapd` (partial state, `EROFS` mid-transaction) instead of
failing fast with an explanation of what to do instead. The three guards
intercept at the command layer instead: a wrapped `apt`/`apt-get`/`dpkg`
refuses mutating operations immediately with a pointer to the real fix
(edit `/flake`, run `ubx rebuild switch`); a wrapped `snap` does the same
for snap mutations. Read/query operations — `apt search`, `dpkg -l`, `snap
list`, and friends — pass straight through to the real binary, untouched,
so they keep working exactly as they always have.

Each guard has **no override**. This is deliberate, not an oversight: an
escape hatch would just move the drift-prevention problem to "whoever
knows the magic flag", not remove it. The fix for a legitimate need is
always the same — declare it in the flake and rebuild.

## What each guard blocks and passes

Every verb/action decision is enumerated **in the wrapper script itself**
(not duplicated here) — see each script's own header comment for the full
matrix, the reasoning behind every non-obvious call, and exactly how
option parsing finds the verb/action in the first place:

- `bin/ubx-guard-apt` — fronts both `apt` and `apt-get` (their
  mutating/query surfaces overlap almost entirely from this guard's point
  of view). Blocks `install`, `remove`, `purge`, `autoremove`, `upgrade`,
  `full-upgrade`, `dist-upgrade`, `dselect-upgrade`, `reinstall`,
  `build-dep`, `satisfy`, `edit-sources`, and `source` (blocked outright,
  since detecting its mutating `--build` flag would mean reimplementing
  option parsing for a rarely-used verb). Passes `list`, `search`, `show`,
  `showpkg`, `policy`, `madison`, `depends`, `rdepends`, `download`,
  `changelog`, `moo`, `help`, `check`, `indextargets`, plus `update`,
  `clean`, and `autoclean` (index/cache maintenance under `/var`, never a
  change to the installed package set).
- `bin/ubx-guard-dpkg` — fronts `dpkg` itself, action-flag based rather
  than verb based. Blocks `-i`/`--install`, `--unpack`, `--configure`,
  `-r`/`--remove`, `-P`/`--purge`, `--set-selections`,
  `--clear-selections`, `--update-avail`, `--merge-avail`, `--clear-avail`,
  `-A`/`--record-avail`, `--add-architecture`, `--remove-architecture`, and
  `--triggers-only`. Passes the read/query actions (`-l`/`--list`,
  `-s`/`--status`, `-S`/`--search`, `--compare-versions`, `--version`,
  ...) and the `dpkg-deb`-passthrough actions (`-c`/`--contents`,
  `-x`/`--extract`, `-b`/`--build`, ...), which read an existing `.deb` (or
  build one) and write only to a path the caller names explicitly — never
  to dpkg's own status database, the same "read of the archive, not a
  mutation of the managed system" reasoning `apt download` gets.

  The same script also fronts **`dpkg-divert`** and **`dpkg-statoverride`**
  (selected by `basename "$0"`, i.e. whichever name it was diverted to) —
  the issue's matrix explicitly calls out blocking diversion and
  statoverride *additions*, since both mutate parts of dpkg's own database
  that persist independently of any package install/remove and that a
  rebuilt image wouldn't know to reproduce. Both block `--add`/`--remove`
  and pass `--list`/`--help`/`--version`
  (plus `--truename` for `dpkg-divert`). `dpkg-divert` additionally treats
  an entirely action-flag-free invocation as an **implicit `--add`** and
  blocks it too, since `--add` is `dpkg-divert(1)`'s own documented default
  action when none is given explicitly; `dpkg-statoverride` has no such
  default, so a bare invocation there is simply unparseable and fails
  closed.
- `bin/ubx-guard-snap` — blocks `install`, `remove`, `refresh`, `revert`,
  `enable`, `disable`, `set`, `unset`, `connect`, `disconnect`, `ack`,
  `alias`, `unalias`, `prefer`, `switch`, and `try` (installing a local
  directory as a snap in try-mode — exactly as mutating as `install`).
  Passes `list`, `info`, `find`, `version`, `connections`, `interfaces`,
  `services`, `changes`, `tasks`, `warnings`, `get`, `known`, `model`,
  `whoami`, `help`. `start`/`stop`/`restart` are **conditional**: plain
  service start/stop/restart is transient (like `systemctl start` on an
  already-enabled unit) and passes, but the same three subcommands accept
  a `--enable`/`--disable` flag that changes what starts on boot going
  forward — a real, persistent mutation — so its presence anywhere in the
  arguments forces a block for that invocation, the one place this guard
  looks past the verb itself.

**Unknown/unrecognized input always fails closed** — an unlisted verb, an
unrecognized global option before the verb, or anything this guard "can't
confidently classify" is refused with the same message a known-mutating
verb gets. `SPEC.md` §7 draws no distinction between "known-bad" and
"unknown, so assumed bad": guessing that unfamiliar input is safe is
exactly the failure mode a drift-prevention guard exists to avoid. This is
why, for example, `snap run` — plausible-sounding, since it just launches
an already-installed snap's app — is deliberately left unlisted rather
than reasoned about hastily; it can be added later with its own documented
rationale, the same way `try` and the `start`/`stop`/`restart`
persistence carve-out were.

## Shared plumbing

All three wrappers `source` one shared file, `bin/ubx-guard-lib` (not
itself executable — it is never run directly), for the two pieces of
behavior that are genuinely identical across all three commands:

- **The refusal message** — printed to stderr, names the command and the
  specific reason, and always points at the same fix: edit `/flake`, run
  `ubx rebuild switch` (or `boot`/`test`). No two guards word this
  differently, and no invocation gets an override.
- **Handing off to the real binary** — via `exec`, so the real binary's
  exit code and all I/O reach the caller completely unmodified; a
  passthrough is indistinguishable from calling the real binary directly.
  This requires the `UBX_GUARD_REAL_BIN` environment variable to be set to
  the real binary's absolute path; a guard with it unset or pointed at
  something non-executable **refuses to run at all** rather than guess a
  path (e.g. always assuming a `.ubx-real` suffix would risk either
  silently doing nothing, or recursing into the guard itself if an install
  mechanism ever reused the guard's own name for something).

## Reconcile-time purge sweep (M3, issue #63)

The three guards above only ever stop a *human typing a command*; they
have no opinion about snaps that are already installed. `bin/ubx-snap-purge`
is the other half of `SPEC.md` §7's drift-prevention bullet list — "the
converge report surfaces and removes any drift found (undeclared snaps,
...)" — a separate, standalone script (not more code in
`bin/ubx-guard-snap`: see that script's own header, "Why this is a SIBLING
script") intended to run as part of `ubx rebuild switch/boot/test`
convergence rather than as an installed command interceptor.

It takes two inputs — a declared-snap manifest (`--manifest FILE`, JSON: a
top-level object keyed by snap name, per issue #60's manifest shape, e.g.
`{"firefox": {"channel": ..., "classic": ..., "connections": ..., "config": ...}}`
— only the top-level KEYS are read; see the script's header,
"Declared-input contract") and the live installed-snap set (`$UBX_SNAP_BIN
list`, default binary name `snap`) — and
purges (`remove --purge`) every installed snap that is in neither the
manifest nor the fixed, documented protected-base-snap set (`snapd`,
`core`/`core16`/`core18`/`core20`/`core22`/`core24`, `bare` — snapd's own
prerequisites, never something a declared manifest is expected to name).
Like `bin/ubx-systemd-apply`/`bin/ubx-etc-apply`, it defaults to
`--dry-run` (print the plan, purge nothing) and only mutates under
`--apply`. `tests/unit/094-ubx-snap-purge.sh` exercises all of this with a
recording stub in place of `UBX_SNAP_BIN` — no real snapd involved.

Wiring this sweep into `ubx rebuild`'s actual convergence sequence is
deferred separately from the three guards' own image installation above:
it needs issue #60's manifest shape to land first (this script's
`--manifest` contract is written to consume whatever that turns out to
be, without needing a follow-up edit here).

(what-is-deferred)=

## What is deferred

This issue (#31) is scope-limited to the guard scripts themselves,
unit-tested standalone with a stubbed "real" binary. Wiring them into an
actual running system needed a file-injection mechanism into the composed
image (issue #10); that mechanism has landed — it turned out to be
`nix/boot.nix`'s own `bootRootfs`/`extraFilesScript` file-writing pattern
— and `nix/boot.nix`'s `switchLoopExtraFilesScript` (used only by the
switch-loop proof image) already installs guards against it:

- Guards apply **inside the composed runtime image only**. The
  compose-time `dpkg` that runs in the build sandbox (`SPEC.md` §4.1's
  Ubuntu-native stdenv) stays unguarded — it has to unpack `.deb`s and run
  maintainer scripts to build the image in the first place.
- The real `apt`/`apt-get`/`dpkg` binaries get moved aside
  (`ubx_m2_install_guard` in `nix/boot.nix`: `mv /usr/bin/<cmd>
  /usr/bin/<cmd>.ubx-real`, falling back to installing the guard
  un-diverted at `/usr/local/bin` if the real binary isn't present in that
  image), and the matching guard script is installed in their place under
  the original name. `snap` is M3 scope and is never composed into the
  switch-loop proof image at all, so its guard is always installed
  un-diverted, with `UBX_GUARD_REAL_BIN=/bin/true`.
- Each installed guard is told where the real binary ended up via the
  `UBX_GUARD_REAL_BIN` environment variable, set at install time — never
  hard-coded, for the reasons above.

**What is still missing:** `nix/profiles.nix`'s `server-parity-image` and
`desktop-parity-image` — the images a real machine would actually boot —
do not install these guards yet (`grep -rn "ubx-guard" nix/*.nix` hits
only `nix/boot.nix`'s switch-loop proof). Until that lands, the guards are
proven end-to-end only in the switch-loop proof image, not in any
production profile image.
