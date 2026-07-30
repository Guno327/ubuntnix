# Installation

```{admonition} Planned (M7)
:class: warning

Nothing in this page exists yet. ubuntnix is pre-M1: there is no installer,
no ISO, and no `/flake` bootstrap. This page describes the installation
flow as designed in `SPEC.md` §10, targeted for milestone **M7 — Installer
& ISOs**. It will be rewritten to describe the real, working installer as
that milestone lands.
```

## What is planned

ubuntnix ships its own installer ISOs in two variants — **Desktop** and
**Server** — based on the corresponding upstream Ubuntu ISOs, reusing
upstream installer machinery (subiquity / the desktop installer) wherever
possible.

**V1.0 acceptance target:** a user takes the ubuntnix ISO, writes it to a
USB stick, boots a machine, follows the installer, and ends with the same
Ubuntu Desktop or Server instance an upstream install with the same choices
would have produced — same software set, same defaults — except it is
configured through ubuntnix, with the generated configuration living in
`/flake`.

### Parity principle

Same software, same defaults, different management surface. The installer
reuses upstream machinery (subiquity, inheriting its storage flows: guided,
LVM, LUKS once M5 lands, manual) and compiles the user's answers into
configuration:

- storage choices become `fileSystems` declarations;
- identity (username, password) becomes a user with its password hash
  written into the secrets index;
- locale/keyboard/timezone answers become the corresponding modules;
- desktop-vs-server becomes `profiles.desktop` or `profiles.server`;
- the third-party-software checkbox becomes the restricted + multiverse
  per-machine opt-in toggle.

Server installs keep cloud-init, as upstream does. It ships present-but-inert
(the `/etc/cloud/cloud-init.disabled` marker, the same disabled-by-the-
administrator marker a stock post-install Ubuntu Server system carries), so
it never emits its own netplan config and ubuntnix's own
`/etc/netplan/01-ubuntnix.yaml` stays the single source of truth (SPEC.md
§12 R12).

### Planned installer steps

1. Partition the disk (accommodating `/ubx`, `/flake`, and the writable
   paths; optional full-disk encryption once M5 lands).
2. Write the initial generation, built from the parity example
   configuration matching the user's choices (`examples/server.nix` or
   `examples/desktop.nix`, per the Desktop-vs-Server choice above).
3. Initialize `/flake` as a git repository containing that example
   configuration, with git-crypt set up for the `secrets/` folder and a
   generated per-machine GPG identity added as a collaborator. `bin/
   ubx-flake-init` (GitHub issue #114) is this step's mechanism today —
   a single idempotent flow that composes `git init`, materializing the
   compiled config and the `secrets/.gitattributes`/`index.nix`
   git-crypt template, `git-crypt init`, an initial commit, and
   `ubx-secrets-key machine-init --repo` (issue #79's machine-identity/
   collaborator onboarding) into one command. Wiring it to run
   unattended at real install time is still milestone **M7**; the flow
   itself is real and unit-tested
   (`tests/unit/205-ubx-flake-init.sh`) ahead of that.
4. Prompt for an Ubuntu Pro token (required; free personal tokens exist),
   store it via the secrets mechanism, and attach the machine.
5. Finish by encouraging the user to add a git remote for `/flake` so the
   machine's definition is durably backed up off-device.

### Deliberate parity exceptions

A handful of things differ from a stock Ubuntu install by design:

- update machinery — `unattended-upgrades`, update-notifier prompts, and
  snap auto-refresh are replaced by the flake update flow (`ubx update`);
- the apt/dpkg/snap command guards and the read-only root filesystem;
- the presence of `/ubx`, `/flake`, and the generations/GRUB menu;
- Ubuntu Pro attachment is required at install time (upstream offers it
  optionally).

Anything else that differs from a stock install is considered a bug against
the parity target.

## Where to track progress

Installer work is scoped to milestone **M7** in `SPEC.md` §11, after the
base module set (M5) and desktop profile (M6) land. The two parity example
configurations the installer will hand off to — `examples/server.nix`
(M5, proven end-to-end in QEMU by `tests/e2e/050-qemu-server-parity-e2e.sh`)
and `examples/desktop.nix` (M6, proven by
`tests/e2e/070-qemu-desktop-parity-e2e.sh`) — already land ahead of M7.
Full-disk encryption groundwork begins at M4/M5; TPM-backed auto-unlock is
a post-v1 stretch goal.
