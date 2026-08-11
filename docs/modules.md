# Module authoring

```{admonition} Planned (M1..M5)
:class: warning

There is no flake and no `modules/` tree in this repository yet — another
engineering track is standing up the flake-parts skeleton in parallel. This
page describes the *design* for the configuration surface and module
system from `SPEC.md` §6 and G8, so that authors have an accurate mental
model to build against. It is not a tutorial against working code yet, and
it will be updated as primitives (roughly M1-M4) and the base module set
(M5) land.
```

## Primitives vs. modules

The configuration surface is deliberately layered:

- **Primitives** are the minimal, irreducible levers of the output system —
  the domains that cannot be expressed any other way. The closed,
  parity-audited primitive set is: **packages** (debs; snaps including
  connections/config), **files** (`/etc`, systemd units and packaged-unit
  enable/disable/mask state, home files), **users** (including hashed
  passwords sourced from the secrets index), **debconf preseeds** (a
  compose-time input to maintainer scripts, not expressible as files after
  the fact), **boot** (kernel package and kernel command line), and
  **secrets**.
- **Modules** are nothing but compositions of primitives. The bar for
  adding a new primitive is that its domain cannot be expressed through
  existing ones; anything expressible as composition must be a module
  instead. Showcase modules for v1 cover the base-system domains every
  machine needs — bootloader, networking, filesystems/mounts, locale,
  console, timezone, users — plus `profiles.desktop` and `profiles.server`.

Example primitive usage, from `SPEC.md` §6:

```nix
ubuntnix.debs = [ "htop" "postgresql-16" ];
ubuntnix.snaps.firefox = {
  revision = 4090;                 # pinned; vendored + sideloaded
  connections = [ "camera" ];
  config = { ... };                # snap set values
};
ubuntnix.etc."ssh/sshd_config".text = ''...'';
ubuntnix.systemd.units."myapp.service" = { ... };
ubuntnix.systemd.services.cups.enable = false;   # packaged-unit state
ubuntnix.users.gunnar = {
  groups = [ "sudo" ]; shell = "/usr/bin/bash";
  hashedPasswordSecret = "gunnarPassword";       # -> secrets index
};
ubuntnix.debconf."keyboard-configuration" = { "kb/layout" = "us"; };
ubuntnix.boot = { kernel = "linux-generic";
                  kernelParams = [ "quiet" "splash" ]; };
```

Example showcase-module usage, compiling down onto upstream mechanisms:

```nix
boot.grub = { ... };               # -> GRUB config + generations menu
networking = { ... };              # -> netplan YAML
fileSystems."/data" = { ... };     # -> fstab / systemd mount units + swap
i18n.locale = "en_US.UTF-8";       # -> locales debconf/gen
console.keymap = "us";             # -> console-setup
time.timeZone = "Europe/Oslo";     # -> /etc/localtime + timesyncd
profiles.desktop.enable = true;    # -> upstream desktop seed (or .server)
```

**Implementation philosophy:** modules compile declarations into upstream
Ubuntu concepts (netplan for networking, GRUB for boot, fstab/systemd for
mounts) rather than bypassing them. The module layer is a compiler onto
stock Ubuntu, not a replacement for it.

## Dendritic composition (G8)

ubuntnix targets a **dendritic** flake-parts organization: one file per
feature, each contributing to both the system and home configuration
classes, rather than one monolithic module tree. Concretely, once the
flake skeleton lands:

- each file under `modules/` declares one coherent piece of functionality
  (a primitive, a showcase module, a home module) using flake-parts to
  register itself against the relevant configuration class(es);
- system and home modules share the same underlying module machinery, so a
  feature that needs both a system-level and a per-user piece can express
  both from adjacent files instead of a separate subsystem;
- the auto-generated {doc}`reference/index` is intended to reflect exactly
  this tree — every `mkOption` declared anywhere under `modules/` shows up
  there, regenerated in CI so the reference can never drift from the code.

## The module ecosystem

The project ships and grows a base module set over time (see `SPEC.md`
§11's milestones M1-M6); it deliberately does **not** aim to ship an
exhaustive module library. Complex service modules are ecosystem territory
the project encourages: because the primitives are audited to be sufficient
for arbitrarily complex compositions, anything richer than the base set —
databases, HA services, and so on — can be authored as ordinary modules
without needing new primitives.

## `profiles.server` / `profiles.desktop` (landed)

Both profiles live in `nix/profiles.nix` and share one shape:

```nix
profiles.server.enable = true;     # -> upstream Server seed (GitHub #99, M5)
profiles.desktop.enable = true;    # -> upstream Desktop seed (GitHub #107, M6)
# optional on either:
profiles.server.extraPackages = [ "postgresql-16" ];
profiles.desktop.extraPackages = [ "some-other-locked-deb" ];
```

Each exposes a `validateDecl`/`render`/`renderJSON` triple under
`flake.lib.profiles.server` / `flake.lib.profiles.desktop`
(`validateDecl` throws — collecting every violation, not just the first —
on a non-boolean `enable`, a non-list `extraPackages`, or an
`extraPackages` entry not present in the locked archive set,
`archive.lock.json`; `enable = false` always renders an inert, empty
manifest with no packages and no `etc` entries).

**Seed derivation posture (read before touching either `*SeedPackages`
list).** Neither `serverSeedPackages` nor `desktopSeedPackages` is a
hand-curated list. Both are computed identically: every package name in
the project's own locked archive set (`archive.lock.json`, via
`config.flake.lib.archive.lockfile`), minus a small explicitly-enumerated
`*SeedExceptions` list (`hello` — the M1 stdenv/archive-fetch proof
fixture, not a real member of any upstream seed. `htop`, `ed`, and `jq`
used to be in this list too, on the same theory, but GitHub issue #118's
reconciliation against the committed upstream Server manifest
(`tests/fixtures/upstream-manifests/`) proved all three ARE genuine
upstream Server-seed packages — and excluding `ed` was actively breaking
`ubuntu-standard`'s dpkg configuration once that metapackage was declared,
so they were removed from both exception lists). This is deliberate: a
real apt-solver resolve against a live
Ubuntu archive mirror is the only way to know the true upstream Server/
Desktop task-set closure, and this dev/CI environment has no outbound
network to do that resolve. Rather than fake a second, hand-typed package
list that would silently drift from reality, both seeds are defined as
this project's own already-resolved, already-hash-verified closure — a
real, if narrower, stand-in — with the gap against the true upstream
seed tracked explicitly (see `nix/profiles.nix`'s own header, "PM ACTION
REQUIRED") until the real resolver is re-run with network access and the
lockfile regenerated. The eventual CI parity diff against upstream's own
published seed manifests is M7/R11 scope, not this module's.

As of GitHub issue #107, `archive.lock.json` carries **no GNOME/gdm
packages at all** — `desktopSeedPackages` is therefore currently identical
in content to `serverSeedPackages` (both drawn from the one shared,
base-system-only lockfile). `nix/profiles.nix`'s header enumerates the
real GNOME/gdm package names a fuller Desktop seed needs (`gdm3`,
`gnome-shell`, `gnome-session`, `xserver-xorg`, `network-manager`, the
`ubuntu-desktop` meta-package, and others) that must be resolved and
pinned via `bin/ubx-resolve` before the seed can grow to match them.

**Desktop-specific: display manager + graphical target.** `profiles.
desktop`'s `render` additionally carries a `graphicalSession` field (only
when `enable = true`) describing the intended `default.target ->
graphical.target` and `display-manager.service -> gdm.service` wiring —
what a real `systemctl set-default graphical.target` plus a display
manager package's own postinst would each write. This is pure declarative
data in `render`; `packages.desktop-parity-image` (below) is what
materializes it into real (today, deliberately dangling — see above)
symlinks on a built image.

**Parity example configs + build-time proof targets.** `examples/
server.nix` / `examples/desktop.nix` are the parity example configs
(SPEC.md §10): plain attrsets wiring the landed base modules
(`networking`, `fileSystems`/`swapDevices`, `i18n`/`console`/`time`,
`users`) together with the relevant `profiles.*.enable = true;`.
`nix/profiles.nix`'s own `perSystem` block compiles each through every
owning base module's `render`/`validate` and bakes the result onto the
M1 boot pipeline, exposed as `packages.server-parity-image` /
`packages.desktop-parity-image` — real, `nix flake check`/build-forced
targets so CI evaluates the whole pipeline even before a QEMU e2e boots
either image. Both images now have a live QEMU e2e proof:
`tests/e2e/050-qemu-server-parity-e2e.sh` (SPEC.md §11 M5 exit criterion,
issue #99) and `tests/e2e/070-qemu-desktop-parity-e2e.sh` (SPEC.md §11 M6
exit criterion, issue #108) each boot their image headless, capture the
serial console, and assert the image's own baked-in
`ubx-server-parity-assert.service` / `ubx-desktop-parity-assert.service`
emitted its `-PASS` marker — see `.github/workflows/ci.yml`'s
`server-parity` / `desktop-parity` jobs.

## Where to track progress

Primitives land incrementally across milestones **M1** (boot, debconf,
archive), **M2** (users, files/`/etc`), **M3** (snaps), and **M4**
(secrets); the v1 base module set and home-module namespace land at **M5**;
`profiles.desktop` lands at **M6**. See `SPEC.md` §11 for exit criteria per
milestone.
