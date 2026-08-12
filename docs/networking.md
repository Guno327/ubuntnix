# Networking (netplan, hostname, hosts)

```{admonition} Implemented (M5, issue #95): compiles onto the generated /etc primitive
:class: note

`nix/networking.nix` exists in the repository as of milestone **M5**
(`SPEC.md` §6 "showcase modules: base-system domains, compiled to
upstream mechanisms" — `networking = { ... };  # -> netplan YAML`, §11
M5 "networking/netplan"; issue #95). It is a **showcase module**, not a
new primitive: it validates a declared `ubuntnix.networking` attrset,
compiles it to netplan v2 YAML plus `/etc/hostname`/`/etc/hosts` text,
and hands that text straight to {doc}`etc`'s own
`config.flake.lib.etc.render` — generation, diffing, and (once a real
module tree exists to call it from) activation are therefore already
fully handled by `nix/etc.nix`/`bin/ubx-etc`/`bin/ubx-etc-apply`; this
file adds no parallel rendering or activation mechanism of its own.

`perSystem.packages.networking-proof` renders a small fixed declaration
(a plain DHCP interface, a static interface, and a WPA-secured wifi
interface) end to end — a **real derivation build**, not just a
JSON-manifest proof, since this module's whole point is composing onto
`nix/etc.nix`'s own store-building `render` — and is asserted against in
CI's `flake` job. `tests/unit/218-networking-flake-wiring.sh` and
`tests/unit/219-networking-netplan-render.sh` statically pin the
declaration surface and the render contract described below. Like every
showcase module in this project (see {doc}`modules`), there is currently
**no real module tree** (`ubuntnix.networking` is exposed only as
`config.flake.lib.networking`, not yet reachable from a real
`nixosModules`-style option a machine's own flake config sets) and no
production `profiles.server`/`profiles.desktop` module declares a real
`networking` config today — see "Where this is proven" below.
```

## Why this exists

`SPEC.md` §6 draws a hard line between the closed **primitive** set
(packages, files, users, debconf, boot, secrets) and **modules**, which
"are nothing but compositions of primitives". Networking is the
project's first showcase of that pattern for a base-system domain:
instead of teaching `nix/etc.nix` anything new about netplan, this file
is a small, self-contained **compiler** — declared interfaces/wifi/
hostname/hosts in, netplan YAML + `/etc/hostname` + `/etc/hosts` text
out — that hands its output straight to the primitive that already knows
how to generate, diff, and (eventually) activate `/etc` content.

## The declaration surface

```nix
ubuntnix.networking = {
  hostname = "myhost";                       # required; DNS-label or
                                              # dotted-FQDN grammar
  hosts = {                                  # optional; extra
                                              # /etc/hosts entries
    "192.168.1.10" = [ "nas" "nas.local" ];
  };
  interfaces.eth0 = {                        # -> netplan "ethernets:"
    dhcp4 = true;                             # default false
    dhcp6 = false;                            # default false
    addresses = [ "192.168.1.5/24" ];         # default [ ]; CIDR form
    gateway = "192.168.1.1";                  # default null
    nameservers = [ "1.1.1.1" "8.8.8.8" ];    # default [ ]
  };
  wifi.wlan0 = {                              # -> netplan "wifis:"
    ssid = "MyNetwork";                       # required
    pskSecret = "wifiPsk";                    # default null (open AP);
                                               # a secrets.<name>
                                               # REFERENCE, never a PSK
                                               # value -- see "Wi-Fi PSK"
                                               # below
    dhcp4 = true;                             # default true (wifi only)
    # dhcp6/addresses/gateway/nameservers: same fields/defaults as
    # interfaces.<name> above
  };
};
```

### Options (all verified against `nix/networking.nix`)

| Option | Type | Default | Renders to |
|---|---|---|---|
| `hostname` | DNS-label/FQDN string | *(required)* | `/etc/hostname`, and `/etc/hosts`' `127.0.1.1` alias |
| `hosts."<ip>"` | list of hostname strings | `{ }` | extra `/etc/hosts` alias lines |
| `interfaces."<name>".dhcp4` | bool | `false` | netplan `dhcp4:` |
| `interfaces."<name>".dhcp6` | bool | `false` | netplan `dhcp6:` |
| `interfaces."<name>".addresses` | list of CIDR strings | `[ ]` | netplan `addresses:` |
| `interfaces."<name>".gateway` | nullable IP string | `null` | netplan `routes: [{ to: default; via: ...; }]` |
| `interfaces."<name>".nameservers` | list of IP strings | `[ ]` | netplan `nameservers.addresses:` |
| `wifi."<name>".dhcp4` | bool | `true` | netplan `dhcp4:` (defaults `true` — most APs are DHCP) |
| `wifi."<name>".dhcp6` | bool | `false` | netplan `dhcp6:` |
| `wifi."<name>".addresses` | list of CIDR strings | `[ ]` | netplan `addresses:` |
| `wifi."<name>".gateway` | nullable IP string | `null` | netplan `routes:` |
| `wifi."<name>".nameservers` | list of IP strings | `[ ]` | netplan `nameservers.addresses:` |
| `wifi."<name>".ssid` | string, 1-32 chars | *(required)* | `access-points."<ssid>":` mapping key |
| `wifi."<name>".pskSecret` | nullable secret-name string | `null` | `access-points."<ssid>".password:` (as a placeholder — see below) |

`interfaces`/`wifi` attribute *names* are the real Linux/netplan device
names (e.g. `eth0`, `enp3s0`, `wlan0`), restricted to
`[a-zA-Z][a-zA-Z0-9]*` — simple enough to be a legal netplan mapping key
and a legal YAML plain scalar with zero quoting concerns.

## Wi-Fi PSK: the rendered-config escape

`SPEC.md` §8.1's "Rendered-config escape": "where an upstream format
cannot reference a path (e.g. netplan Wi-Fi PSK), the store holds only a
template and activation renders the final file into a root-only
non-store location." Concretely: `pskSecret` is typed
`nullOr (strMatching secretNameRe)` — a bare secret **name**
(`SPEC.md` §8.1's `secrets.<name>`), structurally incapable of holding
real PSK bytes (the same invariant `nix/pro.nix`'s `tokenSecret`
establishes for the Ubuntu Pro token). Instead of a real password, the
rendered netplan YAML carries only a deterministic **placeholder token**
derived from the secret's declared name:

```text
@@UBUNTNIX_SECRET:<name>@@
```

— the literal text that lands in the Nix store. Substituting that
placeholder with the real PSK read from `/run/secrets/<name>` is an
**activation-time** step, out of this module's scope (mirrors
`nix/etc.nix`'s own "does not compute a diff... that's `bin/ubx-etc`'s
job" boundary) — nothing in `nix/networking.nix` ever reads or forces a
real secrets index or real secret material.
`tests/unit/219-networking-netplan-render.sh` statically confirms no raw
secret value ever appears in the file — only the name-derived
placeholder shape, and that `pskSecret`'s type can never carry one.

`pskSecret = null` means an open (no password) access point: no
`password:` line is rendered at all.

## Validation

Two layers, mirroring `nix/pro.nix`'s/`nix/secrets.nix`'s own shape:

1. **`networkingType`** — a real `lib.evalModules` submodule — catches
   every per-field type/shape violation for free via the module system
   itself: bad hostname grammar, non-boolean `dhcp4`, a malformed
   CIDR/IP string, an out-of-grammar secret name, and so on.
2. **`checkManifest`** catches the cross-field/cross-entry rules a
   single option's type cannot express on its own, collecting **every**
   violation into one `throw` (never just the first):
   - device-name grammar on the `interfaces`/`wifi` attribute *names*
     themselves (`[a-zA-Z][a-zA-Z0-9]*`);
   - `hosts.<ip>` keys must be literal IP addresses;
   - an `interfaces`/`wifi` entry with **neither** DHCP (`dhcp4`/`dhcp6`)
     **nor** a static address — the interface would come up
     unconfigured, almost always a declaration mistake;
   - a device name declared under **both** `interfaces` and `wifi` at
     once — two conflicting netplan device matches for the same real
     device.

## Rendering: hand-rolled YAML, not a generator

Every string this file emits is built from validated, punctuation-light,
already-typed fields (bools, CIDR/IP strings, interface/secret names) —
a small set of line-building helpers (`spaces`/`ln`/`boolLine`) assemble
the YAML text directly rather than depending on `nixpkgs.lib`'s YAML
generators, so this module keeps full control over exactly which
optional stanzas appear. Attribute-set iteration is already
alphabetically deterministic, so `interfaces`/`wifi`/`hosts` all render
in stable, sorted-by-name order with no explicit sort step.

### The render contract

`toEtcEntries` — pinned by `tests/unit/219-networking-netplan-render.sh`
— compiles a validated `networking` attrset to three
{doc}`etc`-primitive entries:

```nix
{
  "hostname".text = renderHostnameContent networking;
  "hosts".text = renderHostsContent networking;
  "netplan/01-ubuntnix.yaml" = {
    text = renderNetplanYAML networking;
    mode = "0600";   # root-only, matching stock Ubuntu's own default
                      # netplan file permissions
  };
}
```

`/etc/netplan/01-ubuntnix.yaml` is a full netplan v2 document:

```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: true
      dhcp6: false
    eth1:
      dhcp4: false
      dhcp6: false
      addresses:
        - 192.168.1.5/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
  wifis:
    wlan0:
      dhcp4: true
      dhcp6: false
      access-points:
        "ubuntnix-wifi":
          password: "@@UBUNTNIX_SECRET:wifiPsk@@"
```

Notes the render contract pins:

- the gateway always renders as `routes: [{ to: default; via: ...; }]`
  — netplan's non-deprecated form — **never** the deprecated
  `gateway4:`/`gateway6:` keys;
- `addresses:`/`routes:`/`nameservers:` stanzas are only emitted when
  non-empty/non-null — an interface with no static address gets no
  `addresses:` key at all, not an empty list;
- `access-points:` omits `password:` entirely for an open network.

`/etc/hostname` is `"${hostname}\n"`. `/etc/hosts` matches stock
Ubuntu's own boilerplate shape: `127.0.0.1 localhost`, `127.0.1.1
<hostname>`, then every declared `hosts.<ip>` line, then the standard
IPv6 boilerplate lines — always in that order.

## Composing onto `/etc`

`render { system; name; networking; }` is the entire composition step —
`toEtcEntries networking` handed straight to
`config.flake.lib.etc.render` (issue #26). There is no parallel
rendering mechanism, no separate manifest schema, and no separate
planner/executor for this module: once entries reach `nix/etc.nix`'s
`render`, they are ordinary `/etc` entries, generated, diffed, and
applied exactly as {doc}`etc` describes.

## Where this is proven

- `tests/unit/218-networking-flake-wiring.sh` statically confirms the
  module is wired (`flake.lib.networking`, the real `throw` in
  `validate`, `perSystem.packages.networking-proof`) — this harness has
  no `nix` binary, so it cannot evaluate the module itself.
- `tests/unit/219-networking-netplan-render.sh` statically pins the
  render contract described above (netplan v2 shape, the dhcp/static/
  wifi cases, the gateway `routes:`/`to: default` form, the Wi-Fi PSK
  placeholder escape, the `/etc/hostname`/`/etc/hosts` wiring, and the
  `0600` netplan file mode) by grepping `nix/networking.nix`'s own
  source — the actual rendered YAML text can only be proven correct by
  CI's `flake` job actually building `.#networking-proof`, which forces
  `validate`/`render` against a fixture declaration (`exampleNetworking`)
  at real Nix evaluation time.

What this does **not** yet prove: there is no QEMU/e2e test that boots an
image with a declared `ubuntnix.networking` config and asserts a real
network interface comes up under the rendered netplan YAML — unlike
{doc}`home` (issue #105) or `nix/boot.nix`'s switch-loop proofs, this
module's live-activation story stops at "a correctly rendered `/etc`
entry", the same boundary {doc}`etc` itself describes for
`bin/ubx-etc-apply`. No `profiles.server`/`profiles.desktop` module
declares a real `ubuntnix.networking` config today either — only
`nix/networking.nix`'s own `exampleNetworking` fixture exercises it.

## Where to track progress

`nix/networking.nix` lands at milestone **M5** (`SPEC.md` §11, issue
#95). Real module-tree wiring (a machine's own flake config setting
`ubuntnix.networking` through an actual `nixosModules`-style option
rather than calling `flake.lib.networking.render` directly) is the same
not-yet-real module tree {doc}`modules` describes project-wide; live
network-activation proof (a booted netplan interface, not just a
correctly rendered file) is separate, not-yet-scheduled follow-up work.
