# Filesystems and swap: fstab and mount/swap units

```{admonition} Implemented, baked into the server/desktop parity images (M5, issue #96)
:class: note

`nix/filesystems.nix` exists in the repository as of milestone **M5**
(`SPEC.md` §4.3 "fstab / systemd mount units + swap", §6 "showcase
modules" — `fileSystems."/data" = { ... };  # -> fstab / systemd mount
units + swap`, §11 M5 "the full v1 base module set... fileSystems + swap";
GitHub issue #96). It is a **showcase module**, not a new primitive — the
direct sibling of {doc}`crypttab`: it validates a declared
`ubuntnix.fileSystems`/`ubuntnix.swapDevices` attrset/list and renders a
pure, JSON-ready manifest of `/etc/fstab` content plus matching systemd
`.mount`/`.swap` unit files. Unlike {doc}`crypttab`, this module's output
is not merely a standalone eval-time proof: `nix/profiles.nix`'s
`server-parity-image`/`desktop-parity-image` (`examples/server.nix`/
`examples/desktop.nix`) feed this module's rendered `fstabContent`
straight into the composed rootfs's real `/etc/fstab`, and both images
boot in CI's QEMU e2e jobs — see "Where this is proven" below for exactly
what that does and does not verify (in particular: the example configs'
own `fileSystems`/`swapDevices` entries are deliberately `nofail`, since
neither QEMU fixture actually attaches the backing disks they reference,
so **no real mount or swap activation is exercised**, only that a correct
`/etc/fstab` lands and does not block boot).

`tests/unit/178-filesystems-flake-wiring.sh` and
`tests/unit/179-filesystems-render-fixtures.sh` statically pin the
declaration surface and the render contract described below. Like every
showcase module in this project (see {doc}`modules`), there is currently
**no real module tree** (`ubuntnix.fileSystems`/`ubuntnix.swapDevices` are
exposed only as `config.flake.lib.fileSystems`, not yet reachable from a
real `nixosModules`-style option), and this module is not wired into
`bin/ubx`'s `execute_domains` — its live-activation story stops at
"correctly baked into the composed rootfs image", not on-device
convergence via `ubx rebuild`.
```

## Why this exists

`SPEC.md` §4.3's switching table gives `fileSystems`/swap its own row:
`/etc/fstab` regeneration compiled from `fileSystems`/`swapDevices`
declarations, with **no live remount/activation implemented today**
(the same posture this page's own admonition states). §6's worked example
is `fileSystems."/data" = { ... };  # -> fstab / systemd mount units +
swap`; `nix/filesystems.nix` is that example, made real: declared mount
points and swap devices in, `/etc/fstab` text plus matching `.mount`/
`.swap` unit files out — compiling onto upstream fstab(5)/systemd.mount(5)/
systemd.swap(5) mechanisms rather than inventing a new one, the same
module-ecosystem philosophy every showcase module in this project follows.

## The declaration surface

```nix
ubuntnix.fileSystems."/data" = {
  device = "/dev/disk/by-uuid/1234-5678-9abc-def0";  # required; absolute
                                  # path -- a UUID/by-id/by-partuuid path
                                  # is strongly preferred, but not
                                  # enforced. "/dev/mapper/<name>" (a
                                  # ubuntnix.crypttab mapper) is equally
                                  # accepted -- see "Interop" below.
  fsType = "ext4";                # default "ext4"
  options = "defaults";           # default "defaults"
  dump = 0;                       # default 0
  passno = 2;                     # default 2 -- the stock non-root value;
                                  # this module has no notion of "/"
};

ubuntnix.swapDevices = [
  {
    device = "/dev/disk/by-uuid/...";  # required; absolute path, same
                                       # posture as fileSystems' device
    options = "";                     # default ""; extra fstab(5) col-4
                                       # tokens, comma-joined with "sw"
    priority = null;                  # default null; when set, an
                                       # integer -- systemd.swap(5)'s
                                       # Priority=, fstab(5)'s "pri=<N>"
  }
];
```

The `ubuntnix.fileSystems` attribute name is the mount point (fstab(5)
column 2) — matching `SPEC.md`'s own `fileSystems."/data"` shape.
`ubuntnix.swapDevices` is a **list**, not an attrset: a swap device has no
natural Nix-attribute-safe identifier of its own (only its device path,
which is not well-formed as an attribute name), so it takes the same
"ordered list of attrsets" shape NixOS' own `swapDevices` option does.

### Options (all verified against `nix/filesystems.nix`)

| Option | Type | Default | Renders to |
|---|---|---|---|
| `ubuntnix.fileSystems.<mountPoint>` (attr name) | absolute path, no empty/`.`/`..` segment | *(required key)* | fstab(5) column 2; `.mount` unit's `Where=`/filename |
| `fileSystems.<mp>.device` | absolute path (incl. `/dev/mapper/<name>`) | *(required)* | fstab(5) column 1; `.mount` unit's `What=` |
| `fileSystems.<mp>.fsType` | non-empty string | `"ext4"` | fstab(5) column 3; `.mount` unit's `Type=` |
| `fileSystems.<mp>.options` | string | `"defaults"` | fstab(5) column 4; `.mount` unit's `Options=` |
| `fileSystems.<mp>.dump` | non-negative integer | `0` | fstab(5) column 5 |
| `fileSystems.<mp>.passno` | non-negative integer | `2` | fstab(5) column 6 |
| `swapDevices[i].device` | absolute path | *(required)* | fstab(5) `<device> none swap ...`; `.swap` unit's `What=`/filename |
| `swapDevices[i].options` | string | `""` | fstab(5) extra swap-option tokens; `.swap` unit's `Options=` (omitted if `""`) |
| `swapDevices[i].priority` | nullable integer | `null` | fstab(5) `pri=<N>` token; `.swap` unit's `Priority=` (omitted if `null`) |

## Interop with `nix/crypttab.nix`

A LUKS volume declared as `ubuntnix.crypttab."data" = { ... };` unlocks,
at boot, to `/dev/mapper/data`. That volume's content can be mounted
either of two ways, not mutually exclusive:

1. {doc}`crypttab`'s own `mountPoint` field on the crypttab entry itself
   (renders its own `.mount` unit with the `Requires=`/`After=
   systemd-cryptsetup@<name>.service` wiring already baked in), or
2. **This module**: declare `ubuntnix.crypttab."data"` with no
   `mountPoint` (decrypt-only), and separately declare
   `ubuntnix.fileSystems."/mnt/data".device = "/dev/mapper/data";` — this
   module recognizes the `/dev/mapper/<name>` device shape (`cryptDepOf`)
   structurally, duplicating `nix/crypttab.nix`'s own mapper-name grammar
   (`[a-z][a-z0-9_]*`) verbatim, and renders the identical `Requires=`/
   `After=systemd-cryptsetup@<name>.service` wiring into **its own** mount
   unit.

Any `/dev/mapper/<name>` device is assumed cryptsetup-backed and gets that
wiring; this is deliberately permissive — it does not require the named
crypttab entry to actually be declared anywhere this module can see,
because neither file has cross-domain visibility into the other's
declarations at this eval boundary (each is one dendritic module,
evaluated independently per `SPEC.md` §2 G8). A real mismatch (no such
crypttab entry actually unlocks that mapper name) surfaces the ordinary
way any dangling `Requires=` would at boot — not something this eval-time
validator can or should try to catch.

## Validation

`validate { fileSystems; swapDevices; }` collects **every** violation
across the whole declaration into one `throw` (never just the first):

- each `fileSystems` mount point (the attribute name) must be an absolute
  path with no empty/`.`/`..` segment (segments *may* contain `-`, unlike
  {doc}`crypttab`'s mapper names — a real mount point legitimately
  contains one, e.g. `/mnt/backup-data`);
- `device` must be an absolute path (either a real device path or a
  `/dev/mapper/<name>` reference — both are just absolute paths from this
  check's point of view);
- `fsType` must be a non-empty string; `options` must be a string
  (`""` allowed — a bare `defaults`-only mount with no extra tokens);
- `dump`/`passno` must be non-negative integers;
- no two `fileSystems` entries may declare the same `device` — a real
  block device cannot usefully be double-mounted by two independent fstab
  lines under this project's declarative model;
- each `swapDevices[i].device` must be an absolute path, `options` a
  string, `priority` either `null` or an integer;
- no two `swapDevices` entries may declare the same `device`.

## Rendering: `nix/filesystems.nix`'s `render`

`render { fileSystems; swapDevices; }` first calls `validate`, then for
every filesystem, in sorted-by-mount-point order, composes its fstab(5)
line and (unconditionally, unlike {doc}`crypttab`'s optional mount unit)
its `.mount` unit name/content. For every swap device, in the *list's*
own declared order but sorted by `device` for determinism, composes its
fstab(5) line and `.swap` unit name/content.

```json
{
  "version": 1,
  "fstabContent": "/dev/mapper/data /data ext4 defaults 0 2\n/dev/disk/by-uuid/... none swap sw,pri=10,discard 0 0\n...",
  "fileSystems": [
    {
      "mountPoint": "/data", "device": "/dev/mapper/data",
      "fsType": "ext4", "options": "defaults", "dump": 0, "passno": 2,
      "fstabLine": "/dev/mapper/data /data ext4 defaults 0 2",
      "cryptMapperName": "data",
      "mountUnitName": "data.mount",
      "mountUnitContent": "[Unit]\n...\nAfter=systemd-cryptsetup@data.service\n..."
    }
  ],
  "swapDevices": [
    {
      "device": "/dev/disk/by-uuid/...", "options": "discard", "priority": 10,
      "fstabLine": "/dev/disk/by-uuid/... none swap sw,pri=10,discard 0 0",
      "swapUnitName": "dev-disk-by-uuid-....swap",
      "swapUnitContent": "[Unit]\n...\n"
    }
  ]
}
```

`cryptMapperName` is `null` for any device that does not match
`/dev/mapper/<name>` (see "Interop" above).

### Mount/swap unit naming and content

Both follow the identical scheme {doc}`crypttab` uses: drop the leading
`/`, turn every remaining `/` into `-`, append `.mount`/`.swap` (applied to
the mount point for `.mount` units, to `device` for `.swap` units — a
`.swap` unit's name must equal the escaped form of its `What=` path,
exactly parallel to `.mount`'s `Where=`-must-match-filename rule). The
same documented "a `-` in the path's own segments is not specially
escaped" limitation applies here too.

```ini
# .mount unit (non-crypttab-backed device -- no extra [Unit] lines;
# systemd's own generator machinery synthesizes the right device-unit
# dependency for a real block device's What= on its own)
[Unit]
Description=ubuntnix mount for "<mountPoint>" (...)

[Mount]
What=<device>
Where=<mountPoint>
Type=<fsType>
Options=<options>

[Install]
WantedBy=local-fs.target
```

A crypttab-backed device (`/dev/mapper/<name>`) gets two extra `[Unit]`
lines — `After=`/`Requires=systemd-cryptsetup@<name>.service` — identical
to {doc}`crypttab`'s own rendered unit.

```ini
[Unit]
Description=ubuntnix swap for "<device>" (...)

[Swap]
What=<device>
Options=<options>          # omitted entirely when options == ""
Priority=<priority>        # omitted entirely when priority == null

[Install]
WantedBy=swap.target
```

Swap fstab lines render as `"<device> none swap <options> 0 0"`, where
`<options>` is `sw` plus (when set) `pri=<N>` plus any caller-supplied
extra tokens, comma-joined — e.g. `sw,pri=10,discard`.

`perSystem.packages.filesystems-manifest-proof` forces `validate`/`render`
against a fixed example declaration (which deliberately reuses
`nix/crypttab.nix`'s own `"data"` mapper name, doubling as a worked demo
of the interop wiring above) at eval time.

## Composing onto the server/desktop parity images

`nix/profiles.nix`'s `perSystem` block imports
`examples/server.nix`/`examples/desktop.nix`, calls
`config.flake.lib.fileSystems.render { inherit (exampleConfig)
fileSystems swapDevices; }`, and writes `filesystemsRendered.fstabContent`
directly into the composed rootfs's `/etc/fstab`. Both
`packages.server-parity-image` and `packages.desktop-parity-image` are
real, `nix flake check`/build-forced targets.

`examples/server.nix` declares a `/data` mount and a swap device both
pointed at UUIDs that do not exist on the throwaway QEMU disk those images
actually boot on — `nofail` plus a 1-second
`x-systemd.device-timeout` keep `local-fs.target` from blocking on them at
boot (there is no second/third disk attached in the e2e harness). This
means the example configs deliberately exercise **compilation and
boot-safety**, not real mount/swap activation.

## Where this is proven

- `tests/unit/178-filesystems-flake-wiring.sh` statically greps
  `nix/filesystems.nix` for its real `throw` and `flake.lib.fileSystems`
  wiring — this harness has no `nix` binary, so it cannot evaluate the
  module itself.
- `tests/unit/179-filesystems-render-fixtures.sh` statically pins the
  render contract described above (the fstab line shapes, the `.mount`/
  `.swap` unit naming/content, the crypttab-interop `Requires=`/`After=`
  wiring, the dedupe rules) by grepping `nix/filesystems.nix`'s own
  source — the actual rendered text can only be proven correct by CI's
  `flake` job actually building `.#filesystems-manifest-proof`.
- `nix/profiles.nix`'s `server-parity-image`/`desktop-parity-image` build
  targets force this module's `render` against the real
  `examples/server.nix`/`examples/desktop.nix` declarations and bake the
  resulting `/etc/fstab` into the composed rootfs.
  `tests/e2e/050-qemu-server-parity-e2e.sh` and
  `tests/e2e/070-qemu-desktop-parity-e2e.sh` then boot those images in
  QEMU and assert the guest reaches `multi-user.target` with the expected
  package set installed and the rendered netplan/hostname content present.

**What that e2e coverage does and does not verify**: the parity-image
assert scripts do not read `/etc/fstab` from inside the booted guest at
all — a correct `/etc/fstab` landing in the image and not blocking boot
(thanks to the deliberate `nofail` fixture entries above) is everything
this proof chain currently exercises. There is no assertion that a
declared filesystem actually mounts, that a declared swap device actually
activates, or that the crypttab-interop `Requires=`/`After=` wiring
actually orders correctly against a real `systemd-cryptsetup@` unit —
{doc}`crypttab` has no example-config declaration or e2e coverage of its
own today either, so that interop path is entirely unexercised end to end.

## Where to track progress

`nix/filesystems.nix` lands at milestone **M5** (`SPEC.md` §11, issue
#96), composed into the server/desktop parity images the same milestone.
Real module-tree wiring (a machine's own flake config setting
`ubuntnix.fileSystems`/`ubuntnix.swapDevices` through an actual
`nixosModules`-style option rather than calling
`flake.lib.fileSystems.render` directly) is the same not-yet-real module
tree {doc}`modules` describes project-wide; a live mount/swap activation
proof (a booted guest with a real attached disk actually mounted, not just
a correctly rendered and boot-safe `/etc/fstab`) is separate, not-yet-
scheduled follow-up work.
