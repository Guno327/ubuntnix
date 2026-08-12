# Installation

```{admonition} Partially implemented — no bootable ISO yet (M7 in progress)
:class: warning

This is **not** a pre-M1 project and this page is **not** all-future-tense:
M1 through M6 have shipped, and two of the installer's core mechanisms
already exist as real, unit-tested code you can run today —

- the subiquity-answers→config **compiler** (`nix/installer.nix`;
  `validateAnswers`/`compileAnswers`; tests/unit/200–203), and
- the real **`/flake` bootstrap** (`bin/ubx-flake-init`: `git init` +
  materialize config + `secrets/.gitattributes`/`index.nix` + `git-crypt
  init` + initial commit + `ubx-secrets-key machine-init`; tests/unit/205),
  plus install-time **Ubuntu Pro token capture and attach**
  (`bin/ubx-pro-token`; tests/unit/206).

What genuinely does **not** exist yet is a **bootable installer ISO that
runs this flow unattended** on real hardware — that is blocked on GitHub
issues **#117** (ISO build + publish pipeline) and **#119** (installer
end-to-end ISO-boot proof), both still owner-blocked. Until those land,
this page describes the flow as designed in `SPEC.md` §10, targeted for
milestone **M7 — Installer & ISOs**; each step below is marked with what is
actually implemented-and-tested today versus what is still only designed.
It will be rewritten again once the ISO itself boots and runs the flow
unattended.
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

Each step is marked with what actually exists today. "Implemented and
unit-tested" means real code with a passing test proves it; it does **not**
mean it is yet wired to run unattended from an ISO — that wiring is the
remaining M7 work, gated on issues #117/#119 above.

1. **Not built.** Partition the disk (accommodating `/ubx`, `/flake`, and
   the writable paths; optional full-disk encryption once M5 lands). No
   code exists for this step; it is subiquity's own storage-flow UI,
   unmodified, and nothing here drives it yet.
2. **Not built.** Write the initial generation, built from the parity
   example configuration matching the user's choices (`examples/
   server.nix` or `examples/desktop.nix`, per the Desktop-vs-Server choice
   above). `nix/installer.nix`'s `compileAnswers` (step-3-adjacent, below)
   already produces a validated config attrset from answers and
   `tests/unit/202-installer-roundtrip-validate.sh` proves that output is
   accepted by every downstream module's own validation — but nothing yet
   takes that attrset and actually builds/writes a real generation from
   it on a machine.
3. **Implemented and unit-tested.** Initialize `/flake` as a git
   repository containing that example configuration, with git-crypt set
   up for the `secrets/` folder and a generated per-machine GPG identity
   added as a collaborator. `bin/ubx-flake-init` (GitHub issue #114) is
   this step's real mechanism today — a single idempotent flow that
   composes `git init`, materializing the compiled config and the
   `secrets/.gitattributes`/`index.nix` git-crypt template, `git-crypt
   init`, an initial commit, and `ubx-secrets-key machine-init --repo`
   (issue #79's machine-identity/collaborator onboarding) into one
   command, proven end-to-end with a real throwaway GPG key and git repo
   by `tests/unit/205-ubx-flake-init.sh`. Wiring it to run unattended at
   real install time — invoked automatically from a booted ISO instead of
   by hand — is still milestone **M7**.
4. **Implemented and unit-tested.** Prompt for an Ubuntu Pro token
   (required; free personal tokens exist), store it via the secrets
   mechanism, and attach the machine. `bin/ubx-pro-token` (GitHub issue
   #115) is this step's real mechanism today — it captures a token
   (`--token`/`--token-file`/an interactive echo-off `/dev/tty` prompt),
   writes it to the flake's own `secrets/pro-token` (git-crypt-encrypted
   at rest by the template step 3 already materialized) and commits it
   idempotently, then drives the already-landed `bin/ubx-pro-apply`
   executor's real `attach` action with it — see {doc}`pro`'s own
   "Install-time attach: `bin/ubx-pro-token`" section for the full flow,
   and `tests/unit/206-ubx-pro-token.sh` for the proof (including that the
   token value never leaks into the git object store or this test's own
   captured output). Wiring it to run unattended at real install time is
   still milestone **M7**.
5. **Not built.** Finish by encouraging the user to add a git remote for
   `/flake` so the machine's definition is durably backed up off-device.
   This is a UX prompt, not yet written.

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

The M7 exit proof itself — a QEMU end-to-end test that boots the installer
ISO, drives it non-interactively through compiled autoinstall answers,
reboots into the freshly installed system, and asserts it matches an
upstream install (package-set parity per `SPEC.md` §11 R11, `/flake` present
as a git-crypt-protected git repo carrying the machine's generated GPG key,
Ubuntu Pro attached when a token is supplied, a generation marker and GRUB
present, and a re-run `ubx rebuild switch` converging cleanly) — lives in
`tests/e2e/080-qemu-installer-parity-e2e.sh` (GitHub issue #119). The host-
side harness and its skip logic are already landed and exercised in CI by
`tests/unit/207-qemu-installer-parity-e2e-cli.sh`; the full boot-and-assert
proof self-skips until issue #117 produces a bootable `.#installer-iso`.

Full-disk encryption groundwork begins at M4/M5; TPM-backed auto-unlock is
a post-v1 stretch goal.
