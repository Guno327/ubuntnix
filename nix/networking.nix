# nix/networking.nix — the `networking` SHOWCASE module: compiles a
# declarative interfaces/wifi/hostname/hosts surface into upstream netplan
# YAML plus `/etc/hostname` and `/etc/hosts` (SPEC.md §6 "showcase modules:
# base-system domains, compiled to upstream mechanisms" — `networking = {
# ... };  # -> netplan YAML`, §5 "Package policy", §11 M5 "networking/
# netplan"; GitHub issue #95).
#
# -- Showcase, not primitive ------------------------------------------------
#
# SPEC.md §6 draws a hard line between the closed PRIMITIVE set (packages,
# files, users, debconf, boot, secrets) and MODULES, which "are nothing but
# compositions of primitives". This file is the latter: it never touches a
# real `/etc/netplan`, `/etc/hostname`, or `/etc/hosts` itself and never
# renders its own content-addressed store tree — it VALIDATES a declared
# `networking` attrset, compiles it to netplan YAML + hostname/hosts text,
# and hands that text straight to `config.flake.lib.etc.render`
# (nix/etc.nix, issue #26) exactly the way the issue's own scope describes:
# "Emit /etc/netplan/*.yaml, /etc/hostname, /etc/hosts through the existing
# ubuntnix.etc primitive." Generation vs activation is therefore already
# fully handled by nix/etc.nix/bin/ubx-etc/bin/ubx-etc-apply; this file adds
# nothing there and duplicates none of it.
#
# -- The declaration surface -------------------------------------------------
#
#   ubuntnix.networking = {
#     hostname = "myhost";                       # required; a valid
#                                                  # DNS-label hostname (or
#                                                  # dotted FQDN)
#     hosts = {                                   # optional; extra
#                                                  # /etc/hosts entries
#       "192.168.1.10" = [ "nas" "nas.local" ];
#     };
#     interfaces.eth0 = {                         # -> netplan "ethernets:"
#       dhcp4 = true;                              # default false
#       dhcp6 = false;                             # default false
#       addresses = [ "192.168.1.5/24" ];          # default [ ]; CIDR form
#       gateway = "192.168.1.1";                   # default null
#       nameservers = [ "1.1.1.1" "8.8.8.8" ];     # default [ ]
#     };
#     wifi.wlan0 = {                               # -> netplan "wifis:"
#       ssid = "MyNetwork";                        # required
#       pskSecret = "wifiPsk";                     # default null (open AP);
#                                                    # a secrets.<name>
#                                                    # REFERENCE, never a PSK
#                                                    # value -- see "Wi-Fi
#                                                    # PSK: the rendered-
#                                                    # config escape" below
#       dhcp4 = true;                               # default true
#       # dhcp6/addresses/gateway/nameservers: same fields/defaults as
#       # interfaces.<name> above
#     };
#   };
#
# `interfaces`/`wifi` attribute names are the real Linux/netplan device
# names (e.g. "eth0", "enp3s0", "wlan0") — restricted to
# `[a-zA-Z][a-zA-Z0-9]*` (see `ifaceNameRe` below): simple enough to be a
# legal netplan mapping key and a legal YAML plain scalar with zero quoting
# concerns, without this file having to implement real interface-name
# escaping for exotic names (predictable-network-interface-names style
# names like "enp3s0" already fit this grammar fine; a literal "-" or "."
# in a device name is vanishingly rare and can widen this regex later if a
# real one ever needs it).
#
# -- Wi-Fi PSK: the rendered-config escape (SPEC.md §8.1) --------------------
#
# SPEC.md §8.1's "Rendered-config escape": "where an upstream format cannot
# reference a path (e.g. netplan Wi-Fi PSK), the store holds only a
# template and activation renders the final file into a root-only
# non-store location." Concretely, here: `pskSecret` is typed
# `lib.types.nullOr (lib.types.strMatching secretNameRe)` — a bare secret
# NAME (SPEC.md §8.1's `secrets.<name>`), structurally incapable of holding
# real PSK bytes (same invariant nix/pro.nix's `tokenSecret` establishes for
# the Pro token, and the same enforcement shape: nothing in this file ever
# reads/forces a real secrets index or real secret material). Instead of a
# real password, the netplan YAML this file renders carries only a
# deterministic PLACEHOLDER TOKEN derived from the secret's declared name
# (`pskPlaceholder` below: `"@@UBUNTNIX_SECRET:<name>@@"`) — the literal
# text that lands in the Nix store. A later activation step (out of this
# issue's scope, exactly like nix/etc.nix's own "does NOT compute a diff...
# that's bin/ubx-etc's job" boundary) is responsible for substituting that
# placeholder with the real PSK read from `/run/secrets/<name>` when it
# copies this rendered template into the real, root-only
# `/etc/netplan/01-ubuntnix.yaml` — never before, and never inside a store
# object. tests/unit/219-networking-netplan-render.sh statically confirms
# no raw secret VALUE ever appears here — only the name-derived placeholder
# shape.
#
# -- Rendering: hand-rolled YAML, not a generator ----------------------------
#
# Every string this file emits is built from validated, punctuation-light,
# already-typed fields (bools, CIDR/IP strings, interface/secret names) —
# exactly the class of data nix/crypttab.nix's own header calls out as
# having "no heredoc-collision risk to design around" for the same reason.
# A small set of line-building helpers (`spaces`/`ln`/`boolLine`) below
# assemble the YAML text directly rather than depending on nixpkgs' lib
# generators (`lib.generators.toYAML` is not universally available across
# the pinned nixpkgs-as-lib revision and, more importantly, gives this file
# far less control over exactly which optional stanzas appear — this
# module's whole job is a hand-fitted compiler onto netplan's own schema,
# not a generic serializer). Attribute-set iteration
# (`builtins.attrNames`) is already alphabetically deterministic (see
# nix/etc.nix's/nix/crypttab.nix's own "deterministic ordering for free"
# precedent), so `interfaces`/`wifi`/`hosts` all render in stable,
# sorted-by-name order with no explicit sort step.
#
# -- Validation ---------------------------------------------------------------
#
# Follows nix/pro.nix's/nix/secrets.nix's two-layer shape: `networkingType`
# (a real `lib.evalModules` submodule) catches every per-field type/shape
# violation (bad hostname grammar, non-boolean dhcp4, malformed CIDR/IP,
# an out-of-grammar secret name, ...) for free via the module system itself;
# `checkManifest` below then catches the small set of CROSS-FIELD/
# CROSS-ENTRY rules a single option's type cannot express on its own:
# device-name grammar on the attribute NAMES themselves (mirrors
# nix/secrets.nix's own `badNames` check), an interface/wifi entry with
# neither DHCP nor a static address (silently unconfigured -- almost always
# a declaration mistake), and a device name declared under BOTH
# `interfaces` and `wifi` at once (two conflicting netplan device matches
# for the same real device). One `throw` enumerates every violation found,
# not just the first — the same posture every validator in this project
# already takes.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  # -- grammars -----------------------------------------------------------
  #
  # Interface/wifi device names: see header, "The declaration surface".
  ifaceNameRe = "^[a-zA-Z][a-zA-Z0-9]*$";
  ifaceNameOk = n: builtins.match ifaceNameRe n != null;

  # Loose IPv4/IPv6 literal grammar (digits, ':', '.', hex letters) --
  # deliberately not a full RFC-accurate parser; good enough to catch
  # obvious mistakes (a bare hostname where an IP is required, stray
  # whitespace/punctuation) the same way nix/crypttab.nix's own device-path
  # check is a light shape check, not a real block-device validator.
  ipRe = "^[0-9a-fA-F:.]+$";
  cidrRe = "^[0-9a-fA-F:.]+/[0-9]{1,3}$";

  # DNS-label / dotted-FQDN grammar, used for both `hostname` and every
  # `hosts.<ip>` alias.
  hostnameRe = "^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$";

  # Secret NAME grammar -- identical to nix/pro.nix's own `secretNameRe`
  # (this file is, like nix/pro.nix, a secrets CONSUMER, not a new
  # mechanism -- see header, "Wi-Fi PSK: the rendered-config escape").
  secretNameRe = "^[A-Za-z_][A-Za-z0-9_-]{0,63}$";

  # -- ip/wifi shared option shape -----------------------------------------
  #
  # `interfaceType` and `wifiType` share every field except `ssid`/
  # `pskSecret` (wifi-only) and `dhcp4`'s default (netplan/NetworkManager
  # convention: a declared wifi AP is assumed to want an address by
  # default, a wired interface is not). Expressed as one options fragment
  # (`ipOptions`) merged into both submodules, rather than duplicated,
  # so the two can never silently drift apart on a shared field.
  ipOptions = {
    dhcp6 = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to request an address via DHCPv6 (netplan `dhcp6:`).";
    };
    addresses = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching cidrRe);
      default = [ ];
      description = "Static addresses in CIDR form, e.g. \"192.168.1.5/24\" (netplan `addresses:`).";
    };
    gateway = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching ipRe);
      default = null;
      description = "Default gateway IP, rendered as a netplan `routes: [{ to: default; via: ...; }]` entry (not the deprecated gateway4/gateway6 keys).";
    };
    nameservers = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching ipRe);
      default = [ ];
      description = "Nameserver IPs (netplan `nameservers.addresses:`).";
    };
  };

  interfaceType = lib.types.submodule {
    options = ipOptions // {
      dhcp4 = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to request an address via DHCPv4 (netplan `dhcp4:`).";
      };
    };
  };

  wifiType = lib.types.submodule {
    options = ipOptions // {
      dhcp4 = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to request an address via DHCPv4 (netplan `dhcp4:`). Defaults true for wifi (most access points are DHCP).";
      };
      ssid = lib.mkOption {
        type = lib.types.strMatching "^.{1,32}$";
        description = "The network SSID (max 32 octets), rendered as the `access-points:` mapping key.";
      };
      pskSecret = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching secretNameRe);
        default = null;
        description = ''
          The NAME of the secret (SPEC.md §8.1's `secrets.<name>`) carrying
          the WPA PSK. NEVER a PSK value -- see this file's header, "Wi-Fi
          PSK: the rendered-config escape". `null` means an open (no
          password) access point: no `password:` line is rendered at all.
        '';
      };
    };
  };

  networkingType = lib.types.submodule {
    options = {
      hostname = lib.mkOption {
        type = lib.types.strMatching hostnameRe;
        description = "The machine's hostname, rendered to /etc/hostname and as /etc/hosts' 127.0.1.1 alias.";
      };
      hosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf (lib.types.strMatching hostnameRe));
        default = { };
        description = ''
          Extra /etc/hosts entries: IP literal (attribute name) -> list of
          hostname aliases. Merged in on top of the standard
          localhost/127.0.1.1/IPv6 boilerplate lines every stock Ubuntu
          /etc/hosts carries.
        '';
      };
      interfaces = lib.mkOption {
        type = lib.types.attrsOf interfaceType;
        default = { };
        description = "Wired/generic interfaces, compiled to netplan's `network.ethernets`.";
      };
      wifi = lib.mkOption {
        type = lib.types.attrsOf wifiType;
        default = { };
        description = "Wireless interfaces, compiled to netplan's `network.wifis`.";
      };
    };
  };

  # evalDeclared -- runs a declared `ubuntnix.networking` attrset through
  # the real Nix module system, self-contained -- mirrors nix/pro.nix's/
  # nix/secrets.nix's own `evalDeclared`.
  evalDeclared = networking:
    (lib.evalModules {
      modules = [{
        options.networking = lib.mkOption { type = networkingType; };
        config = { inherit networking; };
      }];
    }).config.networking;

  # -- ipEntryUnconfigured -- true iff neither dhcp4 nor dhcp6 nor any
  # static address is set: the entry would compile to a netplan stanza
  # netplan itself would bring up with no address at all, almost always a
  # declaration mistake rather than an intentional link-only interface.
  ipEntryUnconfigured = e: !e.dhcp4 && !e.dhcp6 && e.addresses == [ ];

  # checkManifest -- cross-field checks the submodule TYPE above cannot
  # express by itself (device-name grammar on ATTRIBUTE NAMES, the
  # "unconfigured entry" rule, and the interfaces/wifi name-collision
  # rule) -- mirrors nix/secrets.nix's own `checkManifest` shape: one
  # throw enumerating EVERY violation found, not just the first.
  checkManifest = networking:
    let
      ifaceNames = builtins.attrNames networking.interfaces;
      wifiNames = builtins.attrNames networking.wifi;
      hostsIps = builtins.attrNames networking.hosts;

      badIfaceNames = builtins.filter (n: !ifaceNameOk n) ifaceNames;
      badWifiNames = builtins.filter (n: !ifaceNameOk n) wifiNames;
      badHostsIps = builtins.filter (ip: builtins.match ipRe ip == null) hostsIps;

      unconfiguredIfaces = builtins.filter (n: ipEntryUnconfigured networking.interfaces.${n}) ifaceNames;
      unconfiguredWifi = builtins.filter (n: ipEntryUnconfigured networking.wifi.${n}) wifiNames;

      collidingNames = builtins.filter (n: builtins.elem n wifiNames) ifaceNames;
    in
    (map (n: "ubuntnix.networking.interfaces.\"${n}\": device name must match ${ifaceNameRe}") badIfaceNames)
    ++ (map (n: "ubuntnix.networking.wifi.\"${n}\": device name must match ${ifaceNameRe}") badWifiNames)
    ++ (map (ip: "ubuntnix.networking.hosts.\"${ip}\": key must be a literal IP address matching ${ipRe}") badHostsIps)
    ++ (map (n: "ubuntnix.networking.interfaces.\"${n}\": neither dhcp4/dhcp6 nor any static address is set -- the interface would come up unconfigured") unconfiguredIfaces)
    ++ (map (n: "ubuntnix.networking.wifi.\"${n}\": neither dhcp4/dhcp6 nor any static address is set -- the interface would come up unconfigured") unconfiguredWifi)
    ++ (map (n: "\"${n}\" is declared under both ubuntnix.networking.interfaces and ubuntnix.networking.wifi -- a device can only be one or the other") collidingNames);

  # validate -- a declared `ubuntnix.networking` attrset -> the same
  # attrset, type-checked and defaulted, or a `throw` enumerating every
  # violation found (nix/pro.nix's/nix/secrets.nix's own posture).
  validate = declared:
    let
      evaled = evalDeclared declared;
      errors = checkManifest evaled;
    in
    if errors == [ ]
    then evaled
    else
      throw ''
        ubuntnix.networking failed validation (SPEC.md §6, §8.1; nix/networking.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  # -- rendering: small YAML line-building helpers ------------------------
  #
  # See header, "Rendering: hand-rolled YAML, not a generator".
  spaces = n: builtins.concatStringsSep "" (builtins.genList (_: "  ") n);
  ln = n: text: "${spaces n}${text}";
  boolLine = n: key: value: ln n "${key}: ${lib.boolToString value}";

  # escapeYamlDq -- wraps a string in a double-quoted YAML scalar,
  # escaping the two characters that would otherwise break out of it.
  # Every string this touches (SSIDs, the PSK placeholder) is already
  # validated/derived, punctuation-light data -- this is just the safe
  # habit, not a defense against adversarial input this file's own
  # `validate` wouldn't already have rejected.
  escapeYamlDq = s: "\"" + (builtins.replaceStrings [ "\\" "\"" ] [ "\\\\" "\\\"" ] s) + "\"";

  # pskPlaceholder -- see header, "Wi-Fi PSK: the rendered-config escape".
  # A deterministic, name-derived, punctuation-obvious token -- never the
  # real PSK, never even reachable from real secret material.
  pskPlaceholder = secretName: "@@UBUNTNIX_SECRET:${secretName}@@";

  # ipEntryLines -- the fields `interfaces.<name>` and `wifi.<name>` share
  # (dhcp4/dhcp6/addresses/routes/nameservers), rendered at indent level n.
  ipEntryLines = n: e:
    [
      (boolLine n "dhcp4" e.dhcp4)
      (boolLine n "dhcp6" e.dhcp6)
    ]
    ++ (lib.optionals (e.addresses != [ ]) (
      [ (ln n "addresses:") ] ++ (map (a: ln (n + 1) "- ${a}") e.addresses)
    ))
    ++ (lib.optionals (e.gateway != null) [
      (ln n "routes:")
      (ln (n + 1) "- to: default")
      (ln (n + 1) "  via: ${e.gateway}")
    ])
    ++ (lib.optionals (e.nameservers != [ ]) (
      [ (ln n "nameservers:") (ln (n + 1) "addresses:") ]
      ++ (map (ns: ln (n + 2) "- ${ns}") e.nameservers)
    ));

  # accessPointLines -- wifi's own `access-points:` stanza, rendered at
  # indent level n; omits `password:` entirely for an open (pskSecret ==
  # null) network.
  accessPointLines = n: w:
    [ (ln n "access-points:") (ln (n + 1) "${escapeYamlDq w.ssid}:") ]
    ++ (lib.optionals (w.pskSecret != null) [
      (ln (n + 2) "password: ${escapeYamlDq (pskPlaceholder w.pskSecret)}")
    ]);

  ethernetsBlock = interfaces:
    if interfaces == { } then [ ]
    else
      [ (ln 1 "ethernets:") ]
      ++ (lib.concatMap
        (name: [ (ln 2 "${name}:") ] ++ (ipEntryLines 3 interfaces.${name}))
        (builtins.attrNames interfaces));

  wifisBlock = wifi:
    if wifi == { } then [ ]
    else
      [ (ln 1 "wifis:") ]
      ++ (lib.concatMap
        (name:
          [ (ln 2 "${name}:") ]
          ++ (ipEntryLines 3 wifi.${name})
          ++ (accessPointLines 3 wifi.${name}))
        (builtins.attrNames wifi));

  # renderNetplanYAML -- a VALIDATED `networking` attrset -> the full
  # netplan v2 YAML document text (trailing newline).
  renderNetplanYAML = networking:
    let
      lines =
        [ "network:" (ln 1 "version: 2") ]
        ++ (ethernetsBlock networking.interfaces)
        ++ (wifisBlock networking.wifi);
    in
    builtins.concatStringsSep "\n" lines + "\n";

  # renderHostsContent -- a VALIDATED `networking` attrset -> the full
  # /etc/hosts text, matching stock Ubuntu's own boilerplate shape
  # (127.0.0.1 localhost / 127.0.1.1 <hostname> / declared entries / the
  # standard IPv6 lines).
  renderHostsContent = networking:
    let
      declaredLines = map
        (ip: "${ip} ${builtins.concatStringsSep " " networking.hosts.${ip}}")
        (builtins.attrNames networking.hosts);
      lines =
        [ "127.0.0.1 localhost" "127.0.1.1 ${networking.hostname}" "" ]
        ++ declaredLines
        ++ [
          ""
          "# The following lines are desirable for IPv6 capable hosts"
          "::1     localhost ip6-localhost ip6-loopback"
          "ff02::1 ip6-allnodes"
          "ff02::2 ip6-allrouters"
        ];
    in
    builtins.concatStringsSep "\n" lines + "\n";

  # renderHostnameContent -- a VALIDATED `networking` attrset -> the full
  # /etc/hostname text.
  renderHostnameContent = networking: "${networking.hostname}\n";

  # toEtcEntries -- a declared `ubuntnix.networking` attrset -> the
  # `ubuntnix.etc."path"` entries attrset (nix/etc.nix's own declaration
  # shape) this module composes onto. Runs `validate` itself, so callers
  # never need to call it separately first.
  toEtcEntries = declared:
    let networking = validate declared; in
    {
      "hostname".text = renderHostnameContent networking;
      "hosts".text = renderHostsContent networking;
      "netplan/01-ubuntnix.yaml" = {
        text = renderNetplanYAML networking;
        # netplan configs may carry the Wi-Fi PSK placeholder template
        # (see header) -- kept root-only exactly like stock Ubuntu's own
        # default netplan file permissions.
        mode = "0600";
      };
    };

  # render -- toEtcEntries, handed straight to nix/etc.nix's own
  # `flake.lib.etc.render` (issue #26) -- see header, "Showcase, not
  # primitive": this is the ENTIRE composition, no parallel rendering
  # mechanism of its own.
  render =
    { system ? "x86_64-linux"
    , name ? "networking"
    , networking
    }:
    config.flake.lib.etc.render {
      inherit system name;
      entries = toEtcEntries networking;
    };

  # exampleNetworking -- a small, fixed declaration exercising all three
  # showcase cases this issue's own acceptance criteria names: a plain
  # DHCP interface, a static interface (address/gateway/nameservers), and
  # a WPA-secured wifi interface sourcing its PSK via the secrets escape.
  # Forced through validate/render by `networking-proof` below during
  # ordinary flake evaluation -- mirrors nix/etc.nix's own `etc-proof`
  # role (a REAL derivation build, not just a JSON-manifest proof, since
  # this module's whole point is composing onto nix/etc.nix's own
  # store-building `render`).
  exampleNetworking = {
    hostname = "ubuntnix-example";
    hosts = {
      "192.168.1.10" = [ "nas" "nas.local" ];
    };
    interfaces = {
      # dhcp case
      eth0 = { dhcp4 = true; };
      # static case
      eth1 = {
        addresses = [ "192.168.1.5/24" ];
        gateway = "192.168.1.1";
        nameservers = [ "1.1.1.1" "8.8.8.8" ];
      };
    };
    wifi = {
      # wifi (secrets-escape) case
      wlan0 = {
        ssid = "ubuntnix-wifi";
        pskSecret = "wifiPsk";
        dhcp4 = true;
      };
    };
  };
in
{
  # Exposed under flake.lib (same dendritic contribution pattern
  # nix/etc.nix/nix/pro.nix/nix/crypttab.nix each use for their own file).
  flake.lib.networking = {
    inherit networkingType validate toEtcEntries render
      renderNetplanYAML renderHostsContent renderHostnameContent
      pskPlaceholder;
  };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }: {
    # networking-proof (issue #95): renders exampleNetworking end to end
    # (validate -> netplan YAML + hostname/hosts text -> nix/etc.nix's own
    # content-addressed store objects) and is asserted against in CI (the
    # "flake" job) the same way etc-proof/crypttab-manifest-proof/
    # pro-manifest-proof prove their own files. A NEGATIVE proof (a bad
    # declaration actually throwing) is deliberately not wired up as a
    # `packages.*` output either, for the identical reason nix/etc.nix's
    # own header gives: `validate` throws at EVALUATION time, and exposing
    # a throwing call under `packages` would poison `nix flake check` for
    # the whole flake. tests/unit/218-networking-flake-wiring.sh statically
    # greps this file's own code for the real `throw` instead, mirroring
    # tests/unit/111's/170's/175's own posture.
    packages.networking-proof = render {
      inherit system;
      name = "networking-proof";
      networking = exampleNetworking;
    };
  };
}
