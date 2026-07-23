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

This repository is **partway through milestone M2**. The flake skeleton,
the Ubuntu-native stdenv bootstrap, and the archive lockfile with
snapshot-pinned deb fetching exist; there are no modules and no real Nix
evaluation/composition for `/etc`, systemd units, or a rootfs image yet.
`ubx rebuild switch|boot|test`, `rollback`, `list-generations`, and `diff`
ARE real, orchestrating already-implemented domain planners against
caller-supplied manifests (see {doc}`ubx`). The guides below are explicit,
page by page, about what is implemented today versus what is planned for a
future milestone (M1 through M7). See `SPEC.md` §11 for the milestone
plan.
```

## Guides

- {doc}`install` — the planned ISO/installer flow.
- {doc}`modules` — how module authoring is designed to work: primitives vs.
  modules, and the dendritic flake-parts layout.
- {doc}`workflows` — the planned day-to-day operational workflows: `ubx`
  verbs, generations and rollback, secrets, and updates.
- {doc}`archive` — the archive lockfile: two-tier pinning of the deb
  universe and snapshot-pinned fetching (implemented in M1).
- {doc}`guards` — the apt/dpkg/snap mutation guards: what they block, what
  they pass through, and why (guard scripts implemented and unit-tested in
  M2; wiring them into the composed image is separate, deferred work).
- {doc}`generations` — the generation model: on-disk layout, numbering,
  retention, and GC planning (planner implemented in M2; activation and
  deletion land later).
- {doc}`etc` — the generated `/etc`: declared-entry compilation, the
  machine-local mutable exceptions, and the diff-driven activation planner
  (compile + plan implemented in M2; applying a plan to a real `/etc` lands
  later).
- {doc}`systemd` — systemd units/services: declaration, the refuse-restart
  class rules, and the ordered unit-activation planner (declaration + plan
  + a thin executor implemented in M2; wiring into a real running system's
  `ubx rebuild switch` lands later).
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
guards
generations
users
etc
systemd
ubx
reference/index
```
