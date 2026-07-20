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

This repository is **early in milestone M1**. The flake skeleton, the
Ubuntu-native stdenv bootstrap, and the archive lockfile with
snapshot-pinned deb fetching exist; there are no modules and no working
`ubx` tool yet. The guides below describe the *design* laid out in
`SPEC.md` and are explicit about what is implemented today versus what is
planned for a future milestone (M1 through M7). See `SPEC.md` §11 for the
milestone plan.
```

## Guides

- {doc}`install` — the planned ISO/installer flow.
- {doc}`modules` — how module authoring is designed to work: primitives vs.
  modules, and the dendritic flake-parts layout.
- {doc}`workflows` — the planned day-to-day operational workflows: `ubx`
  verbs, generations and rollback, secrets, and updates.
- {doc}`archive` — the archive lockfile: two-tier pinning of the deb
  universe and snapshot-pinned fetching (implemented in M1).
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
reference/index
```
