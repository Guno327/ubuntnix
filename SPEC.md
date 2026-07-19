# ubuntnix — Specification (Draft 3)

> **Status:** draft under active discussion — nothing here is frozen until the
> owner marks it accepted. Draft 2 superseded the Ubuntu-Core architecture
> (see §14 for superseded decisions); Draft 3 resolves most open questions
> (secrets, showcase modules, bootloader, installer, artifact caching).
> **License:** GPL-3.0 · **Hosting:** GitHub (CI: GitHub Actions) · **Base:** Ubuntu 24.04 LTS (classic)

## 1. Vision

ubuntnix is a fully declarative, immutable Ubuntu. A single Nix flake is the
complete source of truth for a machine: its packages (snaps and debs), system
configuration, services, users, and every declared file in their home
directories. The running system is genuine Ubuntu — the real archive, the
real kernel, snapd with both strict and classic snaps, server and desktop
workloads alike — composed into read-only, atomically-switchable generations
by Nix.

Three principles anchor every decision:

1. **ubuntnix is a shim — a pure function.** The entire project exists as
   one transformation: **f(upstream Canonical artifacts, user
   configuration) → a fully immutable Ubuntu system.** ubuntnix is never an
   artifact source or a service of its own; it is the shim between
   Canonical's outputs and a running machine. Consequences: the core
   exposes **only the necessary primitives** for expressing that
   transformation; everything higher lives in **modules** that compose
   primitives; and the bar for adding a primitive is that its domain cannot
   be expressed through existing ones — anything expressible as composition
   must be a module.
2. **Maximum reuse of upstream Canonical engineering.** The Ubuntu archive
   (main + universe, security-patched under Ubuntu Pro) is the software
   universe, and upstream Ubuntu *mechanisms* (netplan, GRUB, subiquity,
   systemd) are the implementation substrate our modules drive. ubuntnix
   adds composition, immutability, and declarativeness — it does not
   repackage software or reinvent Ubuntu's plumbing.
3. **All software comes from Canonical.** Runtime packages, build tools,
   everything — sourced from the Ubuntu archive or the Snap Store. The Nix
   ecosystem contributes *pure source-code libraries only* (the module
   system, flake-parts, `nixpkgs.lib`): never a binary, build-time or
   runtime. This keeps the entire security-patching story in Canonical's
   hands.

## 2. Goals

- **G1 — Fully declarative.** One flake describes the entire system and every
  user environment; flake + lockfiles reproduce the machine.
- **G2 — Immutable.** The root filesystem is a read-only, Nix-built image.
  No live mutation by package managers; drift is blocked, not just reverted.
- **G3 — Live switching.** `ubx rebuild switch` applies config, service,
  user, home, and snap changes live; base-image (deb-set) changes activate
  via a seconds-long soft-reboot; only kernel changes need a full reboot
  (softened by Livepatch for security fixes).
- **G4 — Generations and rollback.** Every switch produces a numbered
  generation selectable at the bootloader and revertible live where the
  domain allows. All package artifacts are retained locally, so rollback
  never depends on the network.
- **G5 — Full archive compatibility.** Everything in main + universe is
  declarable. Server and desktop workloads are both first-class targets, and
  ubuntnix's example configurations mirror stock Ubuntu Desktop/Server.
- **G6 — Reproducible inputs and outputs.** Archive state is pinned via
  snapshot service + lockfiles; snap revisions pinned with assertions; all
  fetches fixed-output; builds hermetic in an Ubuntu-native sandbox.
- **G7 — Deep per-user configuration.** Home-manager-style declarative
  dotfiles, user services, and per-user modules, first-class in the same
  flake.
- **G8 — Dendritic composition.** flake-parts organization: one file per
  feature, contributing to system and home configuration classes.
- **G9 — Canonical-backed security.** Ubuntu Pro is required (free personal
  tokens exist, so this does not gate adoption): esm-apps patch coverage for
  universe, Livepatch for the kernel.
- **G10 — Documentation as a first-class deliverable.** A Read the Docs
  (Sphinx-based) site — hosting via GitHub Pages, provisioned by the owner —
  documenting the installation process, module authoring, and operational
  workflows, plus an **auto-generated reference of all available options and
  modules reflecting the current state of the tree**, regenerated in CI so
  it can never drift from the code. The PM owns standing this up and keeping
  it current from early in the project.

## 3. Non-goals

- **No nixpkgs packages, ever** — runtime or build-time. nixpkgs is a source
  library, not a software source. Upstream home-manager is consequently out
  (its modules install from nixpkgs); ubuntnix ships its own home modules.
- **No repackaging.** ubuntnix does not fork, rebuild, or convert Canonical
  packages; it composes them.
- **No imperative package operations.** `apt install` / `snap install` by
  hand are blocked on a running system (§7).
- **Not NixOS.** No compatibility with NixOS modules or nixpkgs overlays is
  promised; idioms are mirrored where they help.
- **No exhaustive module library from the project.** v1 ships the
  base-system modules and parity configs a functional system requires;
  complex service modules are ecosystem territory the project encourages
  and will grow into over time, not v1 scope.
- **No non-upstream system mechanisms in v1.** Modules drive what stock
  Ubuntu ships: netplan for networking, GRUB for boot (the upstream default —
  alternatives like systemd-boot wait until/unless upstream ships them),
  fstab/systemd for mounts.

## 4. Architecture

The architecture realizes the pure function of §1.1 in two halves: the build
side **computes** the output system from the inputs; activation
**reconciles** the running machine to that computed output. No ubuntnix
component does anything else.

### 4.1 The Ubuntu-native stdenv

The foundational build system. Nix derivations that compose Ubuntu need
build tools (dpkg, apt, tar, chroot helpers); per §1.3 these must themselves
be Canonical's. Bootstrap chain:

1. Fetch Canonical's `ubuntu-base` rootfs tarball as a fixed-output
   derivation (the only trust root besides Nix itself, which is installed
   from the Ubuntu archive's `nix` package).
2. Use it as the build environment (sandboxed chroot/namespace builder) for
   all subsequent derivations: fetching debs, running dpkg/maintainer
   scripts, composing rootfs images.
3. All archive fetches go through the pinned snapshot state (§4.4).

### 4.2 System composition

A **system generation** is built as:

- a **read-only rootfs image** (baked from the declared deb set: base system
  + kernel + snapd + all declared debs, maintainer scripts run at compose
  time inside the stdenv sandbox);
- a **generated `/etc`** overlaying machine configuration (NixOS-style),
  with an enumerated short list of **machine-local mutable exceptions**
  that belong to neither store nor `/flake` (`machine-id`, SSH host keys,
  `adjtime`, …) — created at install/first boot, preserved across
  generations, never world-readable when sensitive;
- **writable state partitions/paths**: `/var`, `/home`, `/ubx`, `/flake`,
  snapd's state;
- a **snap manifest**: pinned revisions + assertions + connections + config;
- **user/home manifests** for the home modules;
- a **GRUB menu entry** (kernel + initrd + rootfs image reference) per
  generation — GRUB because it is upstream Ubuntu's default bootloader.

The store lives at **`/ubx`** (`/ubx/store`, with state under `/ubx/var`),
not `/nix` — ubuntnix diverges from upstream Nix conventions deliberately,
and since no nixpkgs binaries are ever consumed, no cache compatibility is
lost by moving. It exists on-device and holds generations, fetched debs,
vendored snaps, and evaluation state — but never third-party software.
Configured via `NIX_STORE_DIR`/`NIX_STATE_DIR` set system-wide for the
archive-packaged `nix`; our project cache is built against the same prefix.

The machine's configuration flake lives at **`/flake`** — a git repository
(initialized by the installer, §10) with git-crypt protecting the secrets
file (§8). Users are encouraged to add a remote and treat it as the durable
definition of their machine.

### 4.3 Switching and convergence

| Domain | Mechanism | Downtime |
|---|---|---|
| `/etc`, systemd units/services | generate + diff + restart changed units (switch-to-configuration equivalent) | none |
| Users | converge passwd/groups state | none |
| Home files, user services | home-module activation into writable `/home` | none |
| Snaps (add/remove/pin/connect/config) | converge snapd via its API; vendored payloads signed-sideloaded; auto-refresh held permanently | none |
| Deb set (rootfs image change) | build new image → `systemctl soft-reboot` into it | seconds |
| Kernel | new GRUB entry → full reboot; security patches via Livepatch meanwhile | reboot |

**Diff-driven activation.** Every generation carries manifests; activation
computes the delta against observed system state and touches only what
changed: unchanged snaps are never re-sideloaded, unchanged units never
restarted, unchanged images never rebuilt. Incremental rootfs composition
(building generation N+1 from N plus the deb delta, rather than from
scratch) is a planned optimization of the same machinery (custom tooling;
see §13).

**Local artifact retention.** Every `.deb`, `.snap`, and `.assert` a
generation references is kept in `/ubx/store` for as long as that generation
is retained — rollback to any kept generation works fully offline.
**Retention default: the last 5 generations**, with the currently-booted and
the previous generation always exempt from collection regardless of count;
configurable via `ubuntnix.generations.retain` (a count, or `"all"`). Store
artifacts are GC'd only when no retained generation references them.

**v1 bakes all debs into the rootfs image** (confirmed decision): "install
on activation" means compose-then-swap — a new image built from locally
cached `.deb`s, incrementally where possible, activated by soft-reboot. The
rootfs is never mutated in place. A live per-package deb overlay tier is a
post-v1 milestone designed-for but not blocking (§11, §14).

Rollback: any generation bootable from GRUB; live domains roll back by
re-converging to the older manifests from retained artifacts; `snap revert`
used where retained snapd revisions allow.

### 4.4 Reproducibility model

- `flake.lock` pins all flake inputs (nixpkgs-as-lib, flake-parts, our own
  components).
- An **archive lockfile** pins the deb universe, two-tier (research
  outcome — the snapshot service covers `archive.ubuntu.com` +
  `security.ubuntu.com` only, esm pockets are excluded):
  - **public pockets**: pinned to a `snapshot.ubuntu.com` timestamp plus
    resolved `(package, version, sha256)` tuples; snapshots are retained
    upstream "at least 2 years", so the hash + retained artifact is the
    durable trust root and the timestamp only drives resolution;
  - **esm pockets** (`esm.ubuntu.com`): no snapshot service; pinned by
    `(package, version, sha256)` and fetched with the machine's/CI's own
    Pro token. Reproducible by hash; if upstream prunes an old version,
    retained local artifacts cover existing machines (§12 R4).
  **esm content is subscription-gated and is never redistributed**: the
  public project cache and public ISOs/images contain only public-pocket
  packages (mirroring upstream, where esm arrives only after `pro attach`).
- A **snap lockfile** pins `(name, revision, assertion hashes)`; payloads are
  vendored as fixed-output derivations and installed via `snap ack` +
  signed sideload.
- Rootfs composition aims for bit-reproducibility; maintainer-script
  nondeterminism is a tracked risk (§12 R1).

### 4.5 On-device tooling

Everything runs natively on the device:

- **`ubx`** (full name `ubuntnix`): `rebuild switch|boot|test`, `rollback`,
  `list-generations`, `diff`, and `update` (refreshes the lockfiles: flake
  inputs, archive pins, snap pins). Verb semantics mirror NixOS: `switch` applies
  now and sets the GRUB default; `boot` only sets the default; `test`
  applies now (including soft-reboot into a changed image) **without**
  touching the GRUB default, so a plain reboot returns to the last good
  generation.
- Nix (from the Ubuntu archive, pointed at the `/ubx` store) evaluates and
  builds locally: on-device rebuild is full evaluate + compose + converge —
  composition is cheap (unpack debs, no compilation).
- ubuntnix's own tools are built from this repo by the Ubuntu-native stdenv,
  using toolchains from the archive.

## 5. Package policy

- **Snap preferred, deb fallback.** Modules and defaults pick a snap when a
  good one exists (isolation as a bonus, never forced); the deb archive
  covers everything else.
- **Verified provenance by default**: only Canonical-published or
  verified-publisher snaps are eligible by default; a per-system (and
  per-snap) toggle opts in to unverified publishers.
- **Archive components**: main + universe always; **restricted + multiverse
  as a per-machine opt-in toggle** (default off), surfaced by the
  installer's third-party-software checkbox for desktop parity. Note:
  esm-apps does not cover these components — their patching follows
  upstream's own cadence.
- **Ubuntu Pro required**: esm-apps extends Canonical patching across
  universe; attachment happens at install time (§10) and is declarative
  thereafter (§8).

## 6. Configuration surface

The surface is layered per §1.1: a **minimal primitive core** — the
irreducible levers of the output system (packages as snaps and debs, files,
and the few domains inexpressible as either: users, snap
connections/config, secrets delivery) — and **modules**, which are nothing
but compositions of primitives. V1 ships primitives plus the module system
with showcase modules, organized dendritically via flake-parts:

```nix
# primitives — complete coverage, always available
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
  hashedPasswordSecret = "gunnarPassword";       # → secrets index
};
ubuntnix.debconf."keyboard-configuration" = { "kb/layout" = "us"; };
ubuntnix.boot = { kernel = "linux-generic";
                  kernelParams = [ "quiet" "splash" ]; };

# showcase modules: base-system domains, compiled to upstream mechanisms
boot.grub = { ... };               # → GRUB config + generations menu
networking = { ... };              # → netplan YAML
fileSystems."/data" = { ... };     # → fstab / systemd mount units + swap
i18n.locale = "en_US.UTF-8";       # → locales debconf/gen
console.keymap = "us";             # → console-setup
time.timeZone = "Europe/Oslo";     # → /etc/localtime + timesyncd
profiles.desktop.enable = true;    # → upstream desktop seed (or .server)
```

**Primitive completeness (parity audit).** The closed primitive set is:
**packages** (debs; snaps incl. connections/config/system config), **files**
(`/etc`, systemd units and packaged-unit enable/disable/mask state, home
files), **users** (incl. hashed passwords sourced from the secrets index),
**debconf preseeds** (compose-time input to maintainer scripts — not
expressible as files after the fact, hence a primitive), **boot**
(kernel package + kernel command line, consumed by generation machinery),
and **secrets**. This set was audited against the full contents of a stock
Ubuntu 24.04 Desktop and Server install; every domain of such a system is
expressible through it. The v1 base module set is correspondingly explicit:
boot/GRUB, networking/netplan (+hostname/hosts), fileSystems (+swap),
i18n/locale, console/keyboard, timezone, users — plus `profiles.desktop`
and `profiles.server` modules that reproduce the upstream package seeds and
form the backbone of the parity configs (§10).

**Showcase-module scope (decided): the base system.** Bootloader,
networking, filesystems/mounts, and peer domains — chosen because every
machine needs them and they set the pattern. **Implementation philosophy:
modules compile declarations into upstream Ubuntu concepts** (netplan for
networking, GRUB for boot, fstab/systemd for mounts) rather than bypassing
them — the module layer is a compiler onto stock Ubuntu, not a replacement
for it.

**Module ecosystem.** The project ships and grows modules over time; users
are encouraged to author and share modules for everything richer, and the
primitives are deliberately sufficient for arbitrarily complex
compositions. Illustrative of the expressive ceiling (not a project
target): a community MAAS module could compose snap/deb/file primitives
into a fully configured MAAS instance with its PostgreSQL backing store —
and a further module could layer community pacemaker/corosync modules on
top so that three machines with matching configs form and balance a VIP
among themselves, encapsulating an entire HA MAAS deployment in the config
language.

## 7. Drift prevention

The flake is the complete truth; imperative mutation is blocked, not merely
reverted:

- the **read-only rootfs** makes dpkg-level mutation impossible by
  construction;
- an **`apt`/`apt-get`/`dpkg` guard** (a wrapped command) refuses mutating
  operations with a pointer to the flake (read/query operations pass
  through);
- a **`snap` guard** does the same for snap mutations;
- **validation sets in enforcing mode** as a snapd-level backstop remain a
  research item (self-signing logistics);
- the converge report surfaces and removes any drift found (undeclared
  snaps, unmanaged state in managed domains).

## 8. Secrets, Ubuntu Pro, and security

### 8.1 Secrets (decided design)

Secrets are first-class citizens. The mechanism:

- **`/flake/secrets/` is a git-crypt-encrypted folder** (via
  `.gitattributes` patterns): encrypted in the repo and on any remote,
  plaintext in the working tree for keyholders. It contains the secret
  material files plus an **index, `secrets/index.nix`**, declaring every
  secret:

  ```nix
  {
    proToken   = { src = ./pro-token;   owner = "root";   mode = "0400"; };
    gunnarKey  = { src = ./gunnar.key;  owner = "gunnar"; mode = "0400"; };
    apiToken   = { src = ./api-token;   owner = "root";   mode = "0400";
                   environmentVariable = "API_TOKEN"; };
    wgKey      = { src = ./wg0.key;     owner = "root";   mode = "0400";
                   dst = "/etc/wireguard/wg0.key"; };
  }
  ```

- **Delivery**: each secret is declared by `src` (the material file inside
  `secrets/`) and an optional `dst` — the target location of the decrypted
  secret, defaulting to **`/run/secrets/<name>`** (tmpfs — never persisted,
  re-materialized each boot/switch from the decrypted working tree) with the
  declared owner/group/mode. Setting `dst` places the secret (as a symlink
  to the managed material) at a fixed path for software that demands one;
  a `dst` on a persistent filesystem is honored but loudly warned about,
  since the material then survives reboot outside tmpfs.
- **Consumption is path-based**: every secret exposes `secrets.<name>.path`
  (always the effective `dst`); all options that consume secrets take a
  path.
  Rationale (mirrors the mature NixOS secrets ecosystem): env vars leak via
  `/proc/*/environ`, child inheritance, and logs; a `0400` tmpfs file has
  one access path.
- **Env exposure is declared on the secret itself**: setting
  `environmentVariable = "ENV_VAR"` in the index makes activation
  additionally render `/run/secrets/<name>.env` (same owner, mode `0400`)
  containing `ENV_VAR=<value>`, exposed as `secrets.<name>.envFile` for
  consumption via systemd `EnvironmentFile=`. Derived from the path model,
  not a parallel API; secrets without the field have no env form.
- **Rendered-config escape**: where an upstream format cannot reference a
  path (e.g. netplan Wi-Fi PSK), the store holds only a template and
  activation renders the final file into a root-only non-store location.
- **Keys: per-machine GPG identities.** The installer generates a machine
  keypair (stored root-only outside the store) and adds it as a git-crypt
  collaborator; the user's personal key is added for editing on
  workstations. A lost machine is revoked individually (remove key,
  rotate affected secrets, re-encrypt).
- **Activation-only, absolute**: no secret material ever enters a store
  object — enforced by the API shape (references, not values). There is no
  embed-in-store escape hatch.

### 8.2 Ubuntu Pro

- **Attachment happens at install time** (§10: the installer prompts for a
  token) and the token is managed thereafter through the secrets mechanism;
  Pro enablement itself is declarative.
- **CI holds a Pro token** to build images containing esm-patched packages.
- **Livepatch** enabled by default (kernel CVEs without reboot — compounds
  with G3).

### 8.3 Hardening

- **Full-disk encryption**: passphrase LUKS in v1 (matching upstream
  installer parity; groundwork M4, installer flow M7); TPM-backed
  auto-unlock (systemd-cryptenroll) is a post-v1 stretch.
- Image signing / secure boot story: design item for M4.

## 9. Per-user configuration (home modules)

Our own HM-style namespace (upstream home-manager is excluded by the
no-nixpkgs rule):

- declarative `$HOME` files, XDG config, user systemd services, per-user
  module authorship — same module machinery as the system layer, dendritic
  files contribute to both;
- per-user *software* is system-level (snaps/debs) selected per-user via
  modules; no per-user binary installation exists in this model;
- activation is live and owned by `ubx` switch.

## 10. Installation & distribution

ubuntnix ships **its own installer ISOs** in two variants — **Desktop** and
**Server** — based on the corresponding upstream Ubuntu ISOs, reusing
upstream installer machinery (subiquity / the desktop installer) wherever
possible.

**V1.0 acceptance target:** a user takes the ubuntnix ISO, writes it to a
USB stick, boots a machine, follows the installer, and ends with the exact
same Ubuntu Desktop or Server instance an upstream install with the same
choices would have produced — same software set, same defaults — except it
is configured through ubuntnix, with the generated config living in
`/flake`.

**Parity principle:** same software, same defaults, different management
surface. The installer reuses upstream machinery (subiquity — inheriting
its storage flows: guided, LVM, LUKS once M5 lands, manual) and compiles
the user's answers into config: storage → `fileSystems`, identity → a user
with its password hash written into the secrets index, locale/keyboard/
timezone → the corresponding modules, desktop-vs-server → `profiles.*`,
and the third-party-software checkbox → the restricted+multiverse
per-machine toggle (§5). Server installs keep cloud-init, as upstream does.

**Enumerated parity exceptions** (deliberate divergences, by design):

- update machinery — `unattended-upgrades`, update-notifier prompts, and
  snap auto-refresh are replaced by the flake update flow;
- apt/dpkg/snap command guards (§7) and the read-only rootfs;
- the presence of `/ubx`, `/flake`, and generations/GRUB menu;
- Ubuntu Pro attachment is required at install (upstream offers it
  optionally).

Anything else that differs from a stock install is a bug against the
parity target.

The installer:

1. partitions (accommodating `/ubx`, `/flake`, and the writable paths;
   optional FDE once M5 lands);
2. writes the initial generation (built from the parity example config
   matching the user's choices);
3. initializes **`/flake`** as a git repository containing that example
   config, with **git-crypt** set up for the `secrets/` folder and a
   generated **per-machine GPG identity** added as collaborator (§8.1);
4. **prompts for an Ubuntu Pro token** (required; free personal tokens),
   stores it via the secrets mechanism, and attaches;
5. finishes by **encouraging the user to add a remote** for `/flake` so the
   machine's definition is durably backed up.

The parity example configs double as ubuntnix's reference configurations in
the repo and CI.

**Artifact hosting (decided): Cloudflare R2** (S3-compatible object storage;
zero egress fees) serves both the signed `/ubx` binary cache (`nix copy
--to s3://…`) and the ISOs/prebuilt images; GitHub Releases carries only
small artifacts (checksums, manifests). Public artifacts never include esm
content (§4.4).

## 11. Milestones

OSS-from-day-one: public repo, README, contributor docs, and CI from M1;
every milestone lands with QEMU-based end-to-end tests where applicable.
The documentation site (G10) is stood up early — PM-scheduled, not gated on
a milestone — with guides growing alongside features and the options/module
reference regenerated in CI from the tree.

- **M1 — Boot.** Ubuntu-native stdenv bootstrap; archive lockfile with
  apt-solver-based resolution (declared packages → pinned
  `(pkg, version, sha256)` tuples; all four components supported) +
  snapshot-pinned fetching; `ubx update` for flake/archive pins; debconf
  preseed support in composition; kernel selection + `kernelParams`; rootfs
  image composition (maintainer scripts in sandbox); GRUB generation
  machinery; boots in QEMU with the `/ubx` store, Nix, and `ubx` skeleton
  aboard. *Exit: a flake-defined Ubuntu 24.04 image boots reproducibly.*
- **M2 — Switch.** Generations; generated `/etc` (+ machine-local
  exceptions); unit diff/restart activation; users primitive (interim auth
  via SSH keys — secret-backed passwords complete in M4); soft-reboot path
  for image changes; all three verbs (`switch`/`boot`/`test`); `ubx diff`,
  `list-generations`, `rollback`; GRUB + live rollback from retained
  artifacts; apt/dpkg + snap guards. *Exit: NixOS-parity switch loop for
  config/service/user domains; image swap via soft-reboot; `test` reverts
  on reboot; demonstrated offline rollback.*
- **M3 — Snaps.** Declarative snapd convergence: pinned revisions, vendored
  payloads + signed sideload, diff-driven activation (unchanged snaps
  untouched), connections, snap config, permanent refresh hold,
  verified-publisher policy + unverified toggle; snap lockfile update
  tooling (`ubx update`). *Exit: a declared snap set converged live from
  vendored payloads; drift guard demonstrably blocks and purges undeclared
  snaps.*
- **M4 — Secrets & Pro.** `secrets/` folder + index + git-crypt workflow;
  per-machine key generation and onboarding; `/run/secrets` delivery +
  `environmentVariable`/`dst` handling; user password hashes from the
  index; declarative Pro management; esm in the build pipeline; CI token
  handling; Livepatch; passphrase-LUKS groundwork (crypttab/fileSystems);
  validation-set research (non-blocking for V1.0). *Exit: a
  secret-consuming service and password login from a secret-sourced hash
  work end-to-end; a Pro-attached machine rebuilds with esm-patched
  packages.*
- **M5 — Base modules & Home.** Module machinery hardening; the full v1
  base module set (boot/GRUB, networking/netplan, fileSystems + swap,
  i18n/locale, console/keyboard, timezone, users) + `profiles.server`;
  home-module namespace with live activation. *Exit: the server parity
  config boots in QEMU with a package set matching the upstream Server
  seed (minus enumerated exceptions), and a user's full environment is
  declared and reproduced on a fresh image.*
- **M6 — Desktop.** `profiles.desktop` (GNOME from the archive) baked,
  booted, and switchable; desktop-specific modules; restricted +
  multiverse opt-in toggle machinery. *Exit: daily-drivable desktop VM
  matching the upstream Desktop seed (minus enumerated exceptions).*
- **M7 — Installer & ISOs.** Desktop + Server ISOs built in CI from
  upstream installer machinery (subiquity); answers→config compilation
  (storage incl. the LUKS flow, identity → secrets, third-party checkbox →
  component toggle); `/flake` init with git + git-crypt + machine key; Pro
  prompt + attach; remote-setup encouragement; cloud-init coexistence
  resolution (R12); CI parity verification against upstream seeds/manifests
  (R11). *Exit: the V1.0 acceptance target — USB-booted physical install
  indistinguishable from upstream (minus enumerated exceptions), config in
  `/flake`, self-rebuildable.*
- **Post-v1 (unordered):** live per-package deb overlay tier (no-reboot deb
  changes); incremental rootfs composition; multi-machine deployment;
  generation storage dedup (§12 R5); TPM-backed FDE auto-unlock.

## 12. Risks & research items

| # | Risk / unknown | Mitigation / plan |
|---|---|---|
| R1 | Maintainer-script nondeterminism breaks rootfs reproducibility | run in normalized sandbox; record + diff outputs; document known-impure packages; upstream fixes where feasible |
| R2 | Boot machinery correctness (we own it now): a bad generation must never brick | GRUB generation menu + boot-counting/auto-fallback; QEMU e2e tests for failure paths |
| R3 | Soft-reboot semantics with snapd/desktop sessions under image swap | validate in M2; full reboot is the always-correct fallback |
| R4 | esm pockets have no snapshot service (research confirmed): upstream may prune a pinned esm version, breaking fresh builds of stale lockfiles | hash-pinned fetches + local artifact retention cover existing machines; keep lockfiles reasonably fresh; esm cannot be publicly mirrored (subscription-gated) |
| R5 | Whole-rootfs generations + full artifact retention consume significant disk | retention policy + store GC for dropped generations; dedup/chunking post-v1 |
| R6 | Old pinned snap revisions unavailable from the Store | vendored payloads are the source of truth; Store fetch is an optimization |
| R7 | Universe package quality varies despite esm patching | verified-publisher snap preference where available; module curation |
| R8 | Secret material leaking into store/logs/repo (Pro token and beyond) | central-file + reference design (§8.1); activation-time delivery to root-only paths; git-crypt for at-rest-in-repo; CI secret hygiene |
| R9 | Desktop stack (debconf, triggers, sessions) stresses compose-time script handling | M6 gated on M1's script sandbox proving out; GNOME chosen for best archive support |
| R10 | Third-party Nix tooling hardcodes `/nix/store` instead of respecting `NIX_STORE_DIR` | our own tools always honor the env; document the divergence; evaluate case-by-case whether affected tools matter to us |
| R11 | Installer parity drifts as upstream installers/defaults evolve | parity configs are versioned per Ubuntu release; CI compares against upstream seed/manifest (M7 deliverable) |
| R12 | cloud-init (kept for server parity) is a second config renderer and could fight ubuntnix-generated netplan/config | ship present-but-inert like a post-install stock system (status done / disabled marker); resolved at M7 |

## 13. Open questions

None — all tracked open questions are resolved into the ledger (§14). New
questions will be added here as they arise during implementation.

## 14. Decision ledger

### Current

| Decision | Choice | Notes |
|---|---|---|
| Design philosophy | ubuntnix is a shim — a pure function f(Canonical artifacts, user config) → immutable system; minimal primitive core, modules are compositions, ecosystem encouraged | §1.1, §6 |
| Architecture | Classic immutable base: Nix-built whole-rootfs generations from the Ubuntu archive; snapd (strict + classic) on top | confirmed after upstream-doc verification killed Core (see Superseded) |
| Base series | Ubuntu 24.04 LTS | 26.04 existed at decision time; chose maturity |
| Language | Nix — flakes, flake-parts, module system; dendritic target | nixpkgs as pure source lib only |
| Software provenance | 100% Canonical (archive + Snap Store); no nixpkgs packages ever, incl. build tools | Ubuntu-native stdenv from `ubuntu-base` |
| Package policy | Snap preferred (Canonical/verified publishers by default; toggle for unverified), deb fallback | |
| Archive components | main + universe always; restricted + multiverse per-machine opt-in (default off), wired to the installer's third-party checkbox | esm doesn't cover the opt-in components |
| Ubuntu Pro | Required; attach at install time; free personal tokens keep adoption open; esm-apps + Livepatch | |
| Snap payloads | Vendored: pinned revisions as fixed-output artifacts, signed sideload; auto-refresh held permanently | |
| Artifact retention | All .deb/.snap/.assert artifacts kept locally per retained generation; offline rollback; diff-driven activation | custom diff tooling in scope |
| Drift | Strict purge + blocking apt/dpkg/snap command guards; validation sets researched | |
| Store location | `/ubx` (store at `/ubx/store`), not `/nix` — deliberate divergence from upstream Nix | free of cache-compat cost since no nixpkgs binaries are consumed; R10 |
| Config location | `/flake` — git repo, git-crypt for secrets, remote encouraged | initialized by installer |
| Secrets | First-class: git-crypt'd `/flake/secrets/` folder with `index.nix` (`src`/optional `dst`/owner/mode per secret); delivered to `dst`, default `/run/secrets/<name>` (tmpfs); path-based consumption (`secrets.<name>.path`); per-secret `environmentVariable` opt-in rendering `secrets.<name>.envFile`; per-machine GPG identities; activation-only, absolute | §8.1 |
| Archive pinning | Two-tier: public pockets via snapshot timestamp + sha256; esm by version + sha256 with own Pro token; esm never redistributed | §4.4; R4 |
| Generation retention | Default keep 5; booted + previous always kept; `ubuntnix.generations.retain` (count or `"all"`) | §4.3 |
| Artifact hosting | Cloudflare R2: signed `/ubx` cache + ISOs/images; GitHub Releases for small artifacts only | §10 |
| Rebuild locus | Fully on-device: evaluate + compose + converge locally | composition is cheap without compilation |
| Live switch | Config/services/users/home/snaps live; deb-set changes via soft-reboot; kernel via reboot + Livepatch | |
| Deb delivery | v1 baked into rootfs image (compose-then-swap from cached artifacts); live overlay tier post-v1 | re-confirmed after artifact-retention discussion |
| Switch verbs | `switch` / `boot` / `test` all in v1; `test` never touches the GRUB default | M2 |
| Bootloader | GRUB — upstream Ubuntu's default; only upstream-default bootloaders in v1 | |
| Config UX | Primitives + module system + showcase modules | |
| Showcase modules | Base-system domains (boot, networking, filesystems/mounts), compiled to upstream mechanisms (netplan, GRUB, fstab/systemd) | |
| Home config | Own HM-style home modules (files, user services, per-user modules); software stays system-level | upstream HM excluded by no-nixpkgs |
| Example configs | Parity with upstream Ubuntu Desktop/Server installs; double as reference configs | |
| Distribution | Own Desktop + Server installer ISOs from upstream installer machinery; parity principle; /flake+git+git-crypt+Pro at install | §10 |
| First target | VMs (QEMU) for development; V1.0 acceptance is a physical USB-booted install | §10 |
| V1.0 target | ISO → USB → installer → system ≡ upstream Desktop/Server install (same software/defaults), ubuntnix-managed, config in `/flake`; divergences limited to the enumerated parity exceptions | §10 |
| Primitive set | Closed, parity-audited: packages (debs/snaps+state), files (etc/units/unit-state/home), users (+password hashes via secrets), debconf preseeds, boot (kernel+params), secrets | §6 |
| Audience | Open source from day one | docs + CI from M1 |
| Documentation | Read the Docs (Sphinx) site, GitHub Pages hosting (owner-provisioned): install guide, module authoring, workflows, plus auto-generated options/modules reference regenerated in CI | G10; PM-owned |
| License / hosting / naming | GPL-3.0 · GitHub + Actions · project `ubuntnix`, CLI alias `ubx` | |

### Superseded (traceability)

| Was | Replaced by | Why |
|---|---|---|
| Ubuntu Core 24 base, full-snap, no debs | Classic immutable base | Upstream docs confirm Core supports neither classic snaps, nor apt/debs, nor desktop workloads — incompatible with "full main+universe, server+desktop" requirement |
| nixpkgs→strict-snap converter (load-bearing) | Dropped entirely | No-nixpkgs rule; archive covers fallback natively |
| User-env converter snaps for home software | System-level snaps/debs + home modules | Same |
| Upstream home-manager at "Milestone B" | Own home modules, permanently | HM installs from nixpkgs |
| Agent-as-snap with snapd-control | Native on-device tooling | No Core constraints to work around |
| Milestone B (on-device builds via patched base) | Dissolved into v1 | store native on classic base |
| Debs declared by Nix as primary (pre-snap-discussion) | Snap preferred, deb fallback | Owner priority: isolation as bonus, compatibility first |
