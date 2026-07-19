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

## Where to track progress

Primitives land incrementally across milestones **M1** (boot, debconf,
archive), **M2** (users, files/`/etc`), **M3** (snaps), and **M4**
(secrets); the v1 base module set and home-module namespace land at **M5**;
`profiles.desktop` lands at **M6**. See `SPEC.md` §11 for exit criteria per
milestone.
