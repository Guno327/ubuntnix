# ubuntnix

ubuntnix is a fully declarative, immutable Ubuntu built with Nix. A single
Nix flake is the complete source of truth for a machine: its packages
(snaps and debs), system configuration, services, users, and every declared
file in home directories. The running system is genuine Ubuntu — the real
archive, the real kernel, snapd with both strict and classic snaps — composed
into read-only, atomically-switchable generations by Nix.

Three principles anchor the design (see the project's `SPEC.md` at the
repository root for the full specification):

1. **ubuntnix is a shim — a pure function** `f(upstream Canonical artifacts,
   user configuration) -> a fully immutable Ubuntu system`. It never
   repackages software or invents its own artifacts.
2. **Maximum reuse of upstream Canonical engineering.** Upstream mechanisms
   (netplan, GRUB, subiquity, systemd, snapd) remain the implementation
   substrate; ubuntnix adds composition, immutability, and declarativeness.
3. **All software comes from Canonical**, sourced from the Ubuntu archive or
   the Snap Store. The Nix ecosystem contributes pure source-code libraries
   only (the module system, flake-parts, `nixpkgs.lib`) — never a binary.

```{admonition} Project status
:class: important

**M1 through M6 have shipped; M7 (installer & ISOs) is in progress** (see
{doc}`install`). The flake skeleton, the Ubuntu-native stdenv bootstrap,
the archive lockfile with snapshot-pinned deb fetching, generated `/etc`
(`nix/etc.nix`), systemd unit declaration/planning/execution
(`nix/systemd.nix`), snap convergence, secrets + Ubuntu Pro, the base
module set plus `profiles.server`/`profiles.desktop`, and rootfs/disk-image
composition (`nix/compose.nix`, `nix/boot.nix`) all exist, are unit-tested,
and are proven in CI (the `etc-proof`, `systemd-proof`,
`compose-image-proof`, and `boot-image-proof` jobs, plus the QEMU e2e jobs
in `.github/workflows/ci.yml`). `ubx rebuild switch|boot|test`,
`rollback`, `list-generations`, and `diff` ARE real, orchestrating
already-implemented domain planners against caller-supplied manifests (see
{doc}`ubx`). The guides below are explicit, page by page, about what is
implemented today versus what is planned for a future milestone (M1
through M7). See `SPEC.md` §11 for the milestone plan.
```

## Guides

- {doc}`install` — the planned ISO/installer flow.
- {doc}`modules` — how module authoring is designed to work: primitives vs.
  modules, and the dendritic flake-parts layout.
- {doc}`workflows` — the planned day-to-day operational workflows: `ubx`
  verbs, generations and rollback, secrets, and updates.
- {doc}`archive` — the archive lockfile: two-tier pinning of the deb
  universe and snapshot-pinned fetching (implemented in M1).
- {doc}`snap` — the declared snap surface, snap lockfile, resolver, and
  vendoring: revision pins, interface connections, `snap set` config, and
  the verified-publisher-by-default policy (implemented in M3).
- {doc}`guards` — the apt/dpkg/snap mutation guards: what they block, what
  they pass through, and why (guard scripts implemented and unit-tested in
  M2; wiring them into the composed image is separate, deferred work).
- {doc}`generations` — the generation model: on-disk layout, numbering,
  retention, and GC planning (planner implemented in M2; activation and
  deletion land later).
- {doc}`users` — declared users, groups, and secret-backed password
  hashes: the convergence planner and thin executor (declaration + plan +
  executor implemented and unit-tested in M2; wiring `ubx-users execute`'s
  output into a real running system's activation path lands later).
- {doc}`etc` — the generated `/etc`: declared-entry compilation, the
  machine-local mutable exceptions, and the diff-driven activation planner
  (compile + plan implemented in M2; applying a plan to a real `/etc` lands
  later).
- {doc}`networking` — the netplan/hostname/hosts showcase module:
  interfaces, wifi (with the Wi-Fi PSK rendered-config escape), and the
  netplan v2 render contract, composed straight onto the `/etc` primitive
  (implemented in M5; no live network-activation proof yet).
- {doc}`filesystems` — the `fileSystems`/`swapDevices` showcase module:
  `/etc/fstab` plus matching systemd `.mount`/`.swap` units, including the
  `/dev/mapper/<name>` crypttab-interop wiring (implemented in M5, baked
  into the server/desktop parity images; no live mount/swap activation
  proof yet).
- {doc}`localization` — the `i18n`/`console`/`time` showcase module:
  locale/keyboard/timezone debconf preseed answers plus plain `/etc`
  files (implemented in M5, baked into the server/desktop parity images,
  including a real `debconf-set-selections` pass at compose time; no live
  booted-guest content assertion yet).
- {doc}`secrets` — the git-crypt encryption boundary for `secrets/`,
  per-machine and per-user GPG identity onboarding, and the revocation path
  (mechanism implemented and unit-tested in M4; real installer-flow wiring
  is M7).
- {doc}`pro` — declarative Ubuntu Pro: attach, esm-apps, and Livepatch,
  converged against a fixture/real `pro status` (planner + executor
  implemented and unit-tested behind a mock `pro` client in M4; a real
  attach needs a real owned subscription token, tracked separately).
- {doc}`crypttab` — passphrase-LUKS groundwork: declared volumes compiled
  to `/etc/crypttab` plus matching systemd `.mount` units, with a
  diff-driven planner and thin executor (mechanism implemented and
  unit-tested in M4; unwired — not in `ubx rebuild`, no example config, no
  e2e coverage; the real guided-install LUKS flow is M7).
- {doc}`boot` — kernel selection, GRUB generation machinery, and the
  bootable disk image (implemented in M1).
- {doc}`systemd` — systemd units/services: declaration, the refuse-restart
  class rules, and the ordered unit-activation planner (declaration + plan
  + a thin executor implemented in M2; wiring into a real running system's
  `ubx rebuild switch` lands later).
- {doc}`home` — per-user configuration (home modules): declared `$HOME`
  files and per-user `systemctl --user` services, the diff-driven
  activation planner, and the thin executor, wired into `ubx rebuild` and
  proven live in CI by a real QEMU boot (implemented and wired in M5,
  issue #98; live-QEMU activation proof, issue #105).
- {doc}`ubx` — the `rebuild switch|boot|test`/`rollback`/`list-generations`/
  `diff` orchestrator: the GRUB-default matrix, the touched-domains report,
  and exactly how far each domain's live activation goes today
  (implemented and unit-tested in M2; on-device Nix evaluation and
  soft-reboot into a changed image are separate, deferred work).
- {doc}`reference/index` — the auto-generated options and modules reference,
  regenerated in CI from the current state of the tree.

```{toctree}
:maxdepth: 2
:caption: Contents
:hidden:

install
modules
workflows
archive
snap
guards
generations
users
etc
networking
filesystems
localization
secrets
pro
crypttab
boot
systemd
home
ubx
reference/index
```
