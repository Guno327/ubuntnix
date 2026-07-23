# Operational workflows

```{admonition} Partially real as of M2 — see {doc}`ubx` for the details
:class: warning

`ubx rebuild switch|boot|test`, `rollback`, `list-generations`, and `diff`
are real and unit-tested (issue #29) — see {doc}`ubx` for exactly what
each does today, the GRUB-default matrix, and what's still deferred
(on-device Nix evaluation, soft-reboot into a changed image, snaps, home).
This page still describes the FULL day-to-day picture as designed in
`SPEC.md` §4.3, §4.4, §4.5, and §8.1, including pieces (snaps, home,
secrets, `ubx update`) that remain planned rather than implemented.
```

## `ubx` verbs

`ubx` (full name `ubuntnix`) is the single on-device tool. Everything it
does runs natively on the machine being managed: evaluation, composition,
and convergence all happen locally, with no build server in the loop.

### `ubx rebuild switch|boot|test`

The three rebuild verbs mirror NixOS's semantics:

- **`switch`** — applies the new generation now (config, services, users,
  home, snaps live; a changed base image via `systemctl soft-reboot`) *and*
  sets it as the GRUB default, so it is what boots on the next full reboot
  too.
- **`boot`** — only sets the new generation as the GRUB default. Nothing is
  applied to the running machine; the new generation takes effect on the
  next full reboot.
- **`test`** — applies the new generation now, exactly like `switch`
  (including a soft-reboot into a changed image where needed), but **never**
  touches the GRUB default. A plain reboot after `test` returns to the last
  good generation. This is the safe way to try a change: if it turns out
  bad, powering off and on again reverts it without any explicit rollback
  step.

Per domain, `switch`/`test` activation is diff-driven (§4.3): every
generation carries manifests, and activation computes the delta against
observed system state so only what actually changed is touched — unchanged
snaps are never re-sideloaded, unchanged systemd units are never restarted,
and an unchanged base image is never rebuilt.

| Domain | Mechanism | Downtime |
|---|---|---|
| `/etc`, systemd units/services | generate + diff + restart changed units | none |
| Users | converge passwd/groups state | none |
| Home files, user services | home-module activation into writable `/home` | none |
| Snaps | converge snapd via its API; vendored, signed sideload | none |
| Deb set (base image) | build new image, `systemctl soft-reboot` into it | seconds |
| Kernel | new GRUB entry, full reboot (Livepatch covers security fixes meanwhile) | reboot |

### Other verbs

- **`ubx rollback`** — re-converges live domains to the previous
  generation's manifests from retained artifacts, and can also move the
  GRUB default back.
- **`ubx list-generations`** — lists the numbered generations kept on the
  machine, each retaining every `.deb`/`.snap`/`.assert` artifact it
  references.
- **`ubx diff`** — shows the delta a rebuild would apply, without applying
  it — the same diff activation would compute.
- **`ubx update`** — see [Updates and lockfiles](#updates-and-lockfiles)
  below.

## Generations and rollback

Every `ubx rebuild` produces a new numbered **generation**: a read-only
base image plus a generated `/etc`, plus the users/home/snap manifests that
describe the rest of the machine at that point in time. Generations are
selectable at the GRUB menu and, for the live domains, revertible without
rebooting at all.

**Retention.** All package artifacts (`.deb`, `.snap`, `.assert`) a
generation references are kept locally in `/ubx/store` for as long as that
generation is retained, so rollback to any kept generation works fully
offline — no network fetch is ever required to go back to a previously
working state. The default retention policy keeps the **last 5
generations**; the currently-booted generation and the one immediately
before it are always exempt from collection, regardless of the count.
Retention is configurable via `ubuntnix.generations.retain` (a count, or
`"all"`). Store artifacts are only garbage-collected once no retained
generation references them any longer.

**Rolling back.** Any retained generation is bootable straight from the
GRUB menu. For the live domains (config, services, users, home, snaps),
`ubx rollback` re-converges the running machine to an older generation's
manifests using artifacts already on disk — `snap revert` is used where a
retained snapd revision allows it. A base-image (deb-set) rollback follows
the same soft-reboot path as a forward switch, just pointed at the older
image.

## Secrets workflow

Secrets are first-class, not bolted on (`SPEC.md` §8.1). The design:

- **`/flake/secrets/`** is a folder encrypted at rest with **git-crypt**
  (via `.gitattributes` patterns) — encrypted in the repository and on any
  remote, plaintext in the working tree for keyholders only.
- It holds the secret material files plus an index, **`secrets/index.nix`**,
  that declares every secret and its handling:

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

- **Delivery.** Each secret is declared by `src` (the material file inside
  `secrets/`) and an optional `dst`. By default, the decrypted secret is
  materialized at `/run/secrets/<name>` — tmpfs, never persisted, rendered
  fresh on every boot/switch from the decrypted working tree — with the
  declared owner/group/mode. Setting `dst` places the secret at a fixed
  path instead (as a symlink to the managed material) for software that
  demands one; a `dst` on a persistent filesystem is honored but loudly
  warned about, since the material then survives reboot outside tmpfs.
- **Consumption is path-based.** Every secret exposes `secrets.<name>.path`
  (always the effective `dst`); options that consume secrets take a path,
  not a value — a `0400` tmpfs file has exactly one access path, unlike
  environment variables (which leak via `/proc/*/environ`, child process
  inheritance, and logs).
- **Optional env exposure.** Setting `environmentVariable = "ENV_VAR"` on a
  secret makes activation additionally render `/run/secrets/<name>.env`
  (same owner, mode `0400`) containing `ENV_VAR=<value>`, exposed as
  `secrets.<name>.envFile` for consumption via systemd's
  `EnvironmentFile=`. Secrets without the field have no env form.
- **Keys.** The installer generates a per-machine GPG keypair (stored
  root-only, outside the store) and adds it as a git-crypt collaborator;
  a user's personal key is added too, for editing on workstations. A lost
  machine is revoked individually: remove its key, rotate the secrets it
  had access to, re-encrypt.
- **Activation-only, absolute.** No secret material ever enters a Nix store
  object — the API only ever accepts references (paths), never raw values,
  so there is no way to accidentally embed a secret in the store.

Secrets land at milestone **M4** (`SPEC.md` §11); until then, user
authentication is interim (SSH keys, from M2).

(updates-and-lockfiles)=

## Updates and lockfiles

`ubx update` refreshes the pins that make the system reproducible
(`SPEC.md` §4.4):

- **`flake.lock`** — pins all flake inputs (nixpkgs-as-lib, flake-parts,
  ubuntnix's own components).
- **The archive lockfile** — pins the deb universe, two-tier:
  - **public pockets** (`archive.ubuntu.com`, `security.ubuntu.com`): a
    `snapshot.ubuntu.com` timestamp plus resolved `(package, version,
    sha256)` tuples. Upstream retains snapshots "at least 2 years", so the
    hash plus the retained artifact is the durable trust root — the
    timestamp only drives resolution.
  - **esm pockets** (`esm.ubuntu.com`): no snapshot service exists for
    these, so they are pinned directly by `(package, version, sha256)` and
    fetched with the machine's or CI's own Ubuntu Pro token. esm content is
    subscription-gated and never redistributed — the public project cache
    and public ISOs/images contain only public-pocket packages, mirroring
    how upstream only exposes esm after `pro attach`.
- **The snap lockfile** — pins `(name, revision, assertion hashes)`;
  payloads are vendored as fixed-output derivations and installed via
  `snap ack` plus signed sideload.

Running `ubx update` re-resolves these pins against current upstream state
(archive solver, snapshot service, Store) and rewrites the lockfiles; it
does **not** itself apply anything to the running machine — a subsequent
`ubx rebuild switch|boot|test` does that, exactly like any other
configuration change. This replaces the imperative update surface of a
stock Ubuntu install: `unattended-upgrades`, update-notifier prompts, and
snap auto-refresh are all disabled in favor of this explicit, lockfile-driven
flow (`SPEC.md` §10's enumerated parity exceptions).

## Where to track progress

`ubx update` for flake/archive pins and rootfs composition land at **M1**;
generations, all three rebuild verbs, `diff`/`list-generations`/`rollback`,
and the apt/dpkg/snap guards land at **M2**; the snap lockfile and its
`ubx update` integration land at **M3**; the full secrets workflow
(`secrets/` + `index.nix` + git-crypt + per-machine keys) lands at **M4**.
See `SPEC.md` §11 for exit criteria per milestone.
