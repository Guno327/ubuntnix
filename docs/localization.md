# Localization: locale, keyboard, timezone

```{admonition} Implemented, baked into the server/desktop parity images (M5, issue #97)
:class: note

`nix/localization.nix` exists in the repository as of milestone **M5**
(`SPEC.md` §6 "showcase modules: base-system domains, compiled to upstream
mechanisms" — `i18n.locale`/`console.keymap`/`time.timeZone`, §11 M5 "the
full v1 base module set... i18n/locale, console/keyboard, timezone";
GitHub issue #97). It is a **showcase module**, not a new primitive: it
validates a declared `{ i18n; console; time; }` attrset, compiles it to
`ubuntnix.debconf`-shaped preseed answers (fed through
`config.flake.lib.compose.renderPreseed`) plus four plain `/etc` files,
and hands the `/etc` half straight to {doc}`etc`'s own
`config.flake.lib.etc.validate` — generation and rendering are therefore
already fully handled by this module composing onto `nix/etc.nix`'s own
contract; this file adds no parallel `/etc`-writing mechanism of its own.

Unlike {doc}`networking`, this module's output is not merely rendered and
proven at eval time: `nix/profiles.nix`'s `server-parity-image`/
`desktop-parity-image` (`examples/server.nix`/`examples/desktop.nix`) feed
this module's `render {...}.debconf` straight into `nix/compose.nix`'s
real rootfs-composition `preseed` argument, which genuinely runs
`debconf-set-selections` and lets the `locales`/`keyboard-configuration`/
`tzdata` packages' own real maintainer scripts execute inside the build
sandbox — see "Where this is proven" below for exactly what that does and
does not verify. `tests/unit/180-localization-flake-wiring.sh` and
`tests/unit/181-localization-render-fixtures.sh` statically pin the
declaration surface and the render contract described below. Like every
showcase module in this project (see {doc}`modules`), there is currently
**no real module tree** (`i18n`/`console`/`time` are exposed only as
`config.flake.lib.localization`, not yet reachable from a real
`nixosModules`-style option), and this module is not wired into `bin/ubx`'s
`execute_domains` — its live-activation story stops at "correctly baked
into the composed rootfs image", not on-device convergence via `ubx
rebuild`.
```

## Why this exists

`SPEC.md` §6 gives three concrete showcase-module examples for this
domain: `i18n.locale = "en_US.UTF-8";  # -> locales debconf/gen`,
`console.keymap = "us";  # -> console-setup`, and `time.timeZone =
"Europe/Oslo";  # -> /etc/localtime + timesyncd`. `nix/localization.nix`
is that trio, made real: a small, self-contained **compiler** — declared
`i18n`/`console`/`time` in, debconf preseed answers plus plain `/etc`
files out — following the project's own module-ecosystem philosophy:
"modules compile declarations into upstream Ubuntu concepts... rather than
bypassing them" (`SPEC.md` §6).

For every one of the three domains here, the real upstream mechanism is a
maintainer script reacting to a debconf answer, not a file this project
could safely fabricate by hand: the `locales` package's postinst reads
`locales/default_environment_locale` and
`locales/locales_to_be_generated` and runs `locale-gen`; the
`keyboard-configuration` package's postinst reads
`keyboard-configuration/layoutcode` and runs console-setup; the `tzdata`
package's postinst reads `tzdata/Areas`/`tzdata/Zones/<Area>` and both
writes `/etc/timezone` **and** creates the real `/etc/localtime` symlink
itself. This module therefore renders the matching `ubuntnix.debconf`-
shaped preseed answers for all three, reusing `nix/compose.nix`'s own
`renderPreseed` flattening logic verbatim.

## The declaration surface

```nix
i18n.locale = "en_US.UTF-8";            # required; the system default
                                         # locale, e.g. LANG=
i18n.supportedLocales =                 # default [ i18n.locale ]; every
  [ "en_US.UTF-8" "nb_NO.UTF-8" ];      # locale to generate -- MUST
                                         # contain i18n.locale
console.keymap = "us";                  # required; a console-setup XKB
                                         # layout code
time.timeZone = "Europe/Oslo";          # required; an IANA tz name
                                         # ("Area/City", or a bare "UTC")
```

`render`'s own signature takes these as `{ i18n ? {}; console ? {}; time ?
{}; }` — bare, unprefixed names, matching `SPEC.md`'s own example
verbatim. These are showcase-module top-level options, **not**
`ubuntnix.<primitive>` attributes — unlike {doc}`etc`'s/{doc}`filesystems`'s
own primitive surfaces.

### Options (all verified against `nix/localization.nix`)

| Option | Type | Default | Renders to |
|---|---|---|---|
| `i18n.locale` | locale-name string (`[A-Za-z_]+(\.[A-Za-z0-9-]+)?`) | *(required)* | `locales/default_environment_locale` debconf answer, `/etc/default/locale` |
| `i18n.supportedLocales` | list of locale-name strings, must contain `i18n.locale` | `[ i18n.locale ]` | `locales/locales_to_be_generated` debconf answer |
| `console.keymap` | keymap-code string (`[a-z][a-z0-9-]*`) | *(required)* | `keyboard-configuration/layoutcode` debconf answer, `/etc/default/keyboard` |
| `time.timeZone` | IANA tz-name string (`Area/City[/City...]` or a bare zone like `UTC`) | *(required)* | `tzdata/Areas` + `tzdata/Zones/<Area>` debconf answers, `/etc/timezone`, informational `localtimeTarget` |

## Validation

`checkI18n`/`checkConsole`/`checkTime` each collect their own violations,
concatenated into one `validateDecl` `throw` (never just the first — the
same posture every validator in this project takes):

- `i18n.locale` must be a non-empty string matching the locale-name shape;
- `i18n.supportedLocales`, if given, must be a list of strings, each
  matching that same shape, and **must contain** `i18n.locale` — a
  default locale that is never generated is a contradiction `locale-gen`
  itself would refuse to honor usefully;
- `console.keymap` must be a non-empty string matching the keymap-code
  shape;
- `time.timeZone` must be a non-empty string matching the IANA tz-name
  shape.

## Rendering: `nix/localization.nix`'s `render`

`render { i18n; console; time; }` first calls `validateDecl`, then builds:

- **`debconf`** — the raw `ubuntnix.debconf`-shaped attrset, three
  packages (`locales`, `keyboard-configuration`, `tzdata`);
- **`debconfSelections`** — `debconf` flattened via
  `config.flake.lib.compose.renderPreseed`;
- **`etc`** — a sorted-by-path list of four rendered file entries.

```json
{
  "version": 1,
  "i18n": { "locale": "en_US.UTF-8", "supportedLocales": ["en_US.UTF-8", "nb_NO.UTF-8"] },
  "console": { "keymap": "us" },
  "time": {
    "timeZone": "Europe/Oslo", "area": "Europe", "zone": "Oslo",
    "localtimeTarget": "/usr/share/zoneinfo/Europe/Oslo"
  },
  "debconf": {
    "locales": {
      "locales/default_environment_locale": "en_US.UTF-8",
      "locales/locales_to_be_generated": "en_US.UTF-8 UTF-8, nb_NO.UTF-8 UTF-8"
    },
    "keyboard-configuration": { "keyboard-configuration/layoutcode": "us" },
    "tzdata": { "tzdata/Areas": "Europe", "tzdata/Zones/Europe": "Oslo" }
  },
  "debconfSelections": "locales\tlocales/default_environment_locale\ten_US.UTF-8\n...",
  "etc": [
    { "path": "default/keyboard", "text": "XKBLAYOUT=\"us\"\n", "sha256": "<64 hex>", "owner": "root", "group": "root", "mode": "0644" },
    { "path": "default/locale", "text": "LANG=\"en_US.UTF-8\"\n", "sha256": "<64 hex>", "owner": "root", "group": "root", "mode": "0644" },
    { "path": "systemd/timesyncd.conf", "text": "[Time]\n", "sha256": "<64 hex>", "owner": "root", "group": "root", "mode": "0644" },
    { "path": "timezone", "text": "Europe/Oslo\n", "sha256": "<64 hex>", "owner": "root", "group": "root", "mode": "0644" }
  ]
}
```

`splitTz` derives `{ area; zone; }` from `time.timeZone` following
tzdata's own debconf convention: `"Europe/Oslo"` → `{ area = "Europe";
zone = "Oslo"; }`; a nested zone like `"America/Argentina/Buenos_Aires"` →
`{ area = "America"; zone = "Argentina/Buenos_Aires"; }`; a bare top-level
zone like `"UTC"` → `{ area = "Etc"; zone = "UTC"; }` (tzdata's own
"Etc" continent-bucket convention). `localeGenEntry` derives each
`locales/locales_to_be_generated` multiselect entry as `"<locale>
<charset>"`, charset taken from the locale's own `.`-suffix, defaulting to
`"UTF-8"` when the locale carries none (e.g. a bare `"C"`).

Every `etc` entry is run through the **real** `ubuntnix.etc` primitive's
own `validate` (`config.flake.lib.etc.validate`) as a cross-check, so this
module cannot silently drift from that primitive's own contract.

### Why `/etc/localtime` is never rendered here

`bin/ubx-etc-apply`'s activation model is copy-based only — it never
creates a symlink (see {doc}`etc`). Hand-rendering `/etc/localtime`'s
binary TZif content here would also mean vendoring `/usr/share/zoneinfo`
data this module has no flake-pure access to, and would be exactly the
"bypass the upstream mechanism and hand-roll our own" pattern this
project's module philosophy rejects. The real, working path for
`/etc/localtime` is the `tzdata` debconf answer above; this module's
`time` manifest field records the intended symlink target as an
informational `localtimeTarget` string (`/usr/share/zoneinfo/<timeZone>`)
for a later on-device tool to cross-check against — it is never rendered
through the `ubuntnix.etc` primitive.

`perSystem.packages.localization-manifest-proof` forces
`validate`/`render` against a fixed example declaration at eval time, the
same role `filesystems-manifest-proof` plays for `nix/filesystems.nix`.

## Composing onto the server/desktop parity images

`nix/profiles.nix`'s `perSystem` block is the only in-tree consumer of
this module today. It imports `examples/server.nix`/`examples/desktop.nix`
(plain attrsets declaring `i18n`/`console`/`time` alongside `networking`/
`fileSystems`/`users`), calls `config.flake.lib.localization.render {
inherit (exampleConfig) i18n console time; }`, and:

- writes the four `etc` entries' text (`default/locale`,
  `default/keyboard`, `timezone`, `systemd/timesyncd.conf`) directly into
  the composed rootfs's `/etc` tree, and
- passes `localizationRendered.debconf` as `nix/compose.nix`'s
  `composeRootfs`'s real `preseed` argument — the same argument
  `compose-preseed-proof` already demonstrates makes `debconf-set-
  selections` run for real, letting the `locales`/`keyboard-configuration`/
  `tzdata` packages' own postinst maintainer scripts execute inside the
  hardened compose sandbox.

Both `packages.server-parity-image` and `packages.desktop-parity-image`
are real, `nix flake check`/build-forced targets, so CI evaluates this
whole pipeline even before a QEMU e2e boots either image.

## Where this is proven

- `tests/unit/180-localization-flake-wiring.sh` statically greps
  `nix/localization.nix` for its real `throw` and `flake.lib.localization`
  wiring — this harness has no `nix` binary, so it cannot evaluate the
  module itself.
- `tests/unit/181-localization-render-fixtures.sh` statically pins the
  render contract described above (the debconf question names, the four
  `/etc` file paths/content shapes, the `splitTz`/`localeGenEntry`
  conventions) by grepping `nix/localization.nix`'s own source — the
  actual rendered output can only be proven correct by CI's `flake` job
  actually building `.#localization-manifest-proof`.
- `nix/profiles.nix`'s `server-parity-image`/`desktop-parity-image` build
  targets force this module's `render` against the real
  `examples/server.nix`/`examples/desktop.nix` declarations and feed the
  result into a real rootfs compose (`debconf-set-selections` genuinely
  runs). `tests/e2e/050-qemu-server-parity-e2e.sh` and
  `tests/e2e/070-qemu-desktop-parity-e2e.sh` then boot those images in
  QEMU and assert the guest reaches `multi-user.target` with the expected
  package set installed.

**What that e2e coverage does and does not verify**: the parity-image
assert scripts (`ubx-server-parity-assert`/`ubx-desktop-parity-assert`)
check the generation marker, `/ubx/bin/ubx --help`, the cloud-init-disabled
marker, and the rendered netplan/hostname content plus package parity —
they do **not** assert `/etc/default/locale`, `/etc/timezone`, or
`/etc/localtime`'s content from inside the booted guest. So while this
module's debconf answers are proven to genuinely reach real Debian
maintainer scripts at **compose time** (a materially stronger proof than a
module whose output is merely written to a file and never executed
against), there is currently no live, booted-guest assertion that the
locale is actually generated, the keyboard layout is actually active, or
`/etc/localtime` actually points where `localtimeTarget` says it should.

## Where to track progress

`nix/localization.nix` lands at milestone **M5** (`SPEC.md` §11, issue
#97), composed into the server/desktop parity images the same milestone.
Real module-tree wiring (a machine's own flake config setting `i18n`/
`console`/`time` through an actual `nixosModules`-style option rather than
calling `flake.lib.localization.render` directly) is the same not-yet-real
module tree {doc}`modules` describes project-wide; a live, booted-guest
assertion of locale/keyboard/timezone content is separate, not-yet-
scheduled follow-up work.
