# nix/profiles.nix — the `profiles.server` AND `profiles.desktop` showcase
# modules (SPEC.md §6's `profiles.server.enable = true; # -> upstream
# server seed` / `profiles.desktop.enable = true; # -> upstream desktop
# seed` surfaces, §10 "parity example configs", §11 M5/M6 exit criteria;
# GitHub issue #99 for server, GitHub issue #107 for desktop).
#
# -- What M5 needs -----------------------------------------------------------
#
# SPEC.md §11's M5 exit criterion: "the server parity config boots in QEMU
# with a package set matching the upstream Server seed (minus enumerated
# exceptions)". This file's job is exactly that, in three pieces:
#
#   1. `flake.lib.profiles.server` — the `profiles.server.enable` primitive
#      surface itself: `render { enable; extraPackages; }` -> a validated,
#      JSON-ready manifest (mirrors nix/localization.nix's/nix/
#      filesystems.nix's own `validate`+`render` shape), carrying the
#      resolved package list plus the "cloud-init present but inert"
#      `/etc` entry SPEC.md §12 R12 asks for.
#   2. `examples/server.nix` (repo root, this file's own sibling) — the
#      **server parity example config**: a plain attrset in exactly SPEC.md
#      §6's own worked-example shape, wiring the landed M5 base modules
#      (networking, fileSystems+swap, i18n/console/time, users) together
#      with `profiles.server.enable = true;`. SPEC.md §10: "the parity
#      example configs double as ubuntnix's reference configurations in the
#      repo and CI" — this file (via `packages.server-parity-image` below)
#      IS that CI usage.
#   3. `packages.server-parity-image` (bottom) — `examples/server.nix`,
#      compiled through every base module's own `render`/`validate` (never
#      reimplemented here) and baked onto nix/boot.nix's `bootRootfs` ->
#      `squashfsImage` -> `kernelArtifacts` -> `grubCfg` -> `diskImage`
#      pipeline (the exact same M1 boot pipeline `boot-image-proof` already
#      proves works), giving `tests/e2e/050-qemu-server-parity-e2e.sh`
#      something real to boot.
#
# -- What "the upstream Server seed" means IN THIS REPO ----------------------
#
# A real apt-solver resolve against a live archive.ubuntu.com mirror (the
# ONLY way to know upstream's actual Server minimal+standard task-set
# closure) needs real network + apt tooling this project's own dev harness
# does not have (see tests/README.md and every sibling `nix/*.nix` file's
# own "this dev harness has no `nix` binary" caveat — the same gap extends
# to "and no outbound network", which `bin/ubx-resolve`'s own CI-only
# `regen-lockfile` job is the documented, existing escape hatch for). This
# file therefore does NOT attempt to invent a second, hand-typed package
# list that claims to BE the real upstream seed — that would silently drift
# from reality with every archive update and give false confidence. Instead,
# `serverSeedPackages` below is defined as this project's OWN already
# apt-solver-resolved, already snapshot-pinned closure (nix/archive.nix's
# `lockfile.public.packages` — every entry already proven mutually
# consistent by a real apt solve at `bin/ubx-resolve` time, and already
# proven to boot by `boot-image-proof`/tests/e2e/010), MINUS the small,
# explicitly enumerated set of M1 proof-only fixture packages
# (`serverSeedExceptions`) that are not real members of any upstream Server
# seed. As of GitHub issue #118's reconciliation against the committed
# upstream manifest (tests/fixtures/upstream-manifests/ubuntu-24.04.3-live-
# server-amd64.manifest), that set is exactly ONE package: `hello`, the M1
# stdenv/archive-fetch proof fixture (issue #6/#7) that has no upstream
# Ubuntu package at all. `htop`, `ed`, and `jq` were REMOVED from this
# exception list by this same reconciliation — issue #128 had already
# corrected this section's prose to note that all three genuinely appear in
# the upstream Server manifest, but deliberately left the exception lists
# themselves alone because nothing depended on the distinction yet; it does
# now, because excluding `ed` broke `ubuntu-standard`'s own postinst
# configuration (`dpkg: dependency problems ... Package ed is not
# installed`) once that metapackage was declared, so keeping a real upstream
# dependency out of the seed is an active correctness bug, not a harmless
# simplification. This is the exact same posture nix/archive.nix's
# own "esm-tier fetching" section already takes for its own gap (a real,
# needs-owner action — extending the resolver's declared input,
# `archive.packages.json`, with real Server-task-set package names and
# re-running `bin/ubx-resolve` against a live archive with real network
# access — documented below as a PM ACTION REQUIRED, non-blocking, exactly
# mirroring that section's own wording) rather than something this file
# fakes with invented data.
#
# PM ACTION REQUIRED (needs-owner, non-blocking): `archive.packages.json`'s
# declared set does not yet include the real Ubuntu Server minimal/standard
# task-set package names (`cloud-init`, `openssh-server`, `netplan.io`,
# `cron`, `rsyslog`, ...). This file deliberately does NOT add them there
# itself: tests/unit/053-archive-declaration-seed.sh enforces "every
# declared name must already be pinned in archive.lock.json" (declared ⊆
# pinned — see that test's own "DIRECTION NOTE"), and pinning a new name
# for real needs `bin/ubx-resolve` run against a live snapshot with real
# network + apt access this sandboxed dev/CI environment does not have —
# committing an unpinned declaration would fail that test immediately, and
# a HAND-TYPED lockfile entry (a fabricated sha256) would be worse: a
# silent, undetectable lie about a real archive artifact's hash. Until the
# owner runs the real resolver and commits the regenerated
# archive.packages.json/archive.lock.json pair, `serverSeedPackages` below
# is the already-locked M1 closure (minus fixtures) — a real, if narrower,
# stand-in — and the QEMU e2e proof
# (`tests/e2e/050-qemu-server-parity-e2e.sh`) asserts the CURRENTLY
# ACHIEVABLE thing: every declared seed package is actually installed on
# the booted image, and none of the enumerated exceptions leaked in — not
# byte-for-byte equality against a live upstream manifest this environment
# cannot fetch.
#
# -- Desktop (`profiles.desktop`; GitHub issue #107; SPEC.md §11 M6) --------
#
# `flake.lib.profiles.desktop` is `profiles.server`'s direct sibling —
# identical `validateDecl`/`render`/`renderJSON` shape, identical
# lockfile-derived-not-hand-curated posture for `desktopSeedPackages`/
# `desktopSeedExceptions` (see "What 'the upstream Server seed' means in
# this repo" above — read verbatim as "Desktop" for this section; not
# re-explained a second time). The one real difference: a GNOME desktop
# needs a display manager + graphical boot target, which a server install
# does not — `graphicalTargetName`/`displayManagerServiceName`/
# `displayManagerSymlinkPath` below are that DECLARATIVE data (what
# `systemctl set-default graphical.target` and a display-manager package's
# own postinst would each write), materialized into real symlinks only by
# `packages.desktop-parity-image`'s own `extraFilesScript` below — there is
# no symlink primitive in nix/etc.nix (see that file's own "does NOT decide
# symlink-vs-copy" header note) to route this through instead, so this file
# does the same manual `ln -sf` bootRootfs's own `extraFilesScript`
# machinery already uses for `serverParityAssertUnit`'s own
# `multi-user.target.wants` symlink, just for `default.target`/
# `display-manager.service` instead.
#
# GitHub issue #107's own explicit scope boundary: booting this image to an
# actual graphical GNOME session in QEMU is issue #108, NOT this file — see
# that issue for the live e2e. What this file guarantees instead is that
# the DECLARATION is real and wired: `packages.desktop-parity-image` below
# forces evaluation of `profiles.desktop`'s full render pipeline (the same
# "CI's flake-check/build forces evaluation" role
# `profiles-server-manifest-proof`/`server-parity-image` already play for
# `profiles.server`), so issue #108 has something real to boot once it
# lands, without this issue needing a QEMU e2e of its own.
#
# PM ACTION REQUIRED (needs-owner, non-blocking, desktop-specific): unlike
# `serverSeedPackages` above (whose upstream Server minimal/standard
# task-set gap is a handful of names layered on an otherwise
# already-boot-critical-heavy lockfile), NONE of `archive.lock.json`'s 171
# currently-pinned packages are GNOME/desktop packages at all — every one
# is a base/boot-critical package shared with the server seed. A real
# `profiles.desktop` seed needs, at minimum, a display manager (`gdm3`),
# the shell + session (`gnome-shell`, `gnome-session`, `gnome-session-bin`),
# a display server (`xserver-xorg`, `xwayland`, `mutter`), core apps
# (`gnome-control-center`, `gnome-terminal`, `nautilus`,
# `gnome-settings-daemon`), the desktop meta-package (`ubuntu-desktop` or
# `ubuntu-desktop-minimal`), NetworkManager (this repo currently manages
# networking via netplan+systemd-networkd instead — a real desktop install
# also carries `network-manager` for its GUI), PolicyKit (`policykit-1`),
# `upower`, `gvfs`, an audio stack (`pipewire`/`pipewire-pulse` on 24.04),
# `plymouth` (boot splash), and `fonts-ubuntu`. None of these are declared
# in `archive.packages.json` nor pinned in `archive.lock.json` today, and
# — exactly like `serverSeedPackages`'s own gap above — this file
# deliberately does NOT hand-type lockfile entries for them (a fabricated
# sha256 would be an undetectable lie about a real archive artifact) nor
# add undeclared names to `archive.packages.json` (tests/unit/053's
# declared ⊆ pinned invariant would fail immediately). Until the owner runs
# `bin/ubx-resolve` against a live snapshot with real network + apt access
# and commits the regenerated archive.packages.json/archive.lock.json pair
# with these names, `desktopSeedPackages` below is — like
# `serverSeedPackages` — the already-locked base closure (minus fixtures):
# a real, if far narrower, stand-in that lets this module, its example, and
# its parity-image target all evaluate and pass for real today, with the
# actual GNOME package gap enumerated here for the owner to action.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  inherit (config.flake.lib.stdenv) runInUbuntuBase;
  inherit (config.flake.lib.archive) lockfile debs;
  inherit (config.flake.lib.compose) squashfsImage;
  # Renamed on import (not just `validate`): this file exposes its OWN
  # `validateDecl` under `flake.lib.profiles.server` below (the
  # `profiles.server.enable`/`extraPackages` surface's own validator) --
  # keeping the etc-primitive's own validator under its own distinct name
  # here avoids the two colliding, and avoids ever accidentally exposing
  # the WRONG one under `profiles.server`.
  etcValidate = config.flake.lib.etc.validate;
  inherit (config.flake.lib.boot)
    mkBootSpec
    resolveKernelFlavor
    bootRootfs
    kernelArtifacts
    grubCfg
    diskImage;

  # -- serverSeedPackages / serverSeedExceptions ---------------------------
  #
  # See header, "What 'the upstream Server seed' means in this repo".
  # `hello` is the sole M1 stdenv/archive-fetch proof fixture (nix/
  # stdenv.nix/nix/archive.nix/nix/compose.nix's own proof package) that
  # happens to share the one project-wide lockfile with every real
  # boot-critical package (kernel, grub, filesystem tools, ...) — see
  # archive.packages.json's own header for why the lockfile is one shared
  # set rather than per-consumer subsets. It is excluded from the parity
  # diff because of that proof-fixture role, NOT because it is absent from
  # upstream by accident: `hello` genuinely has no upstream Ubuntu package
  # (see tests/fixtures/upstream-manifests/ubuntu-24.04.3-live-server-amd64.
  # manifest, which does not list it).
  #
  # `htop`, `ed`, and `jq` used to sit in this list too, on the same
  # "M1 proof fixture" theory. GitHub issue #118's reconciliation against
  # that same committed upstream manifest proved the theory wrong for all
  # three: they ARE genuine members of the real Ubuntu Server seed (issue
  # #128 already corrected this section's prose to say so, but deliberately
  # left the list itself alone, since nothing depended on it yet). Once
  # `ubuntu-standard` was declared as part of extending the seed toward the
  # real upstream task-set, excluding `ed` stopped being harmless: dpkg
  # refused to configure `ubuntu-standard` because one of its real
  # dependencies (`ed`) was missing from the composed image
  # (`dpkg: dependency problems ... Package ed is not installed`). Removing
  # `htop`/`ed`/`jq` from this list is therefore a correctness fix, not a
  # simplification: it makes the composed image match upstream more
  # closely, which is exactly what this list exists to guarantee.
  serverSeedExceptions = [ "hello" ];

  serverSeedPackages =
    builtins.sort (a: b: a < b)
      (builtins.filter
        (p: !(builtins.elem p serverSeedExceptions))
        (map (p: p.name) lockfile.public.packages));

  # -- cloud-init: present-but-inert (SPEC.md §12 R12) ---------------------
  #
  # "ship present-but-inert like a post-install stock system (status done /
  # disabled marker)". Real Ubuntu images ship the disabling marker at
  # exactly this path (`cloud-init status` treats its presence as "disabled
  # by the administrator"; `cloud-init`'s own upstream docs document this
  # exact mechanism) -- an empty file is the whole contract, no content to
  # get wrong. Run through the REAL `ubuntnix.etc` primitive's own
  # `validate` (config.flake.lib.etc.validate) -- the identical cross-check
  # nix/localization.nix's own header already documents doing for its own
  # rendered files -- so this cannot silently drift from that primitive's
  # contract. The real `cloud-init` PACKAGE itself is a separate, still-
  # pending archive-pin gap (see this file's header, "PM ACTION REQUIRED")
  # -- this marker is deliberately independent of whether that package is
  # actually composed onto an image today: a real Ubuntu Server install
  # ships the marker as a plain `/etc` file regardless of which mechanism
  # (cloud-init's own postinst, or the installer) wrote it, and this
  # project's job here is only to reproduce that FILE, which needs no
  # package present to exist.
  cloudInitEtcEntries = etcValidate {
    "cloud/cloud-init.disabled" = {
      text = "";
    };
  };

  cloudInitDisabledPath = "/etc/cloud/cloud-init.disabled";

  renderEtcEntry = path: e: {
    inherit path;
    text = e.text;
    sha256 = builtins.hashString "sha256" e.text;
    owner = e.owner or "root";
    group = e.group or "root";
    mode = e.mode or "0644";
  };

  # -- validateDecl / render (the `profiles.server` primitive surface) ----
  #
  # `validateDecl { enable; extraPackages; }` -- mirrors nix/localization.nix's
  # own `validateDecl`/`render` split (`render = decl: renderDeclaration
  # (validateDecl decl);`): every violation across the whole declaration is
  # collected into one `throw` (never just the first -- same posture as
  # every sibling showcase module's own validator). `enable = false` is
  # always valid and renders an empty, inert manifest (no packages, no etc
  # entries) -- the module contributes nothing when off, exactly like
  # nix/systemd.nix's own packaged-state `enable = false` entries
  # contribute nothing when unset.
  checkExtraPackages = extraPackages:
    let
      missing = builtins.filter (p: !(debs ? ${p})) extraPackages;
    in
    if missing == [ ] then [ ]
    else [ "profiles.server.extraPackages: package(s) not in the locked archive set (archive.lock.json): ${builtins.concatStringsSep ", " missing} -- add them to archive.lock.json (nix/archive.nix) first." ];

  validateDecl = { enable ? false, extraPackages ? [ ] }:
    let
      errors =
        (if builtins.isBool enable then [ ] else [ "profiles.server.enable must be a boolean, got ${builtins.typeOf enable}" ])
        ++ (if builtins.isList extraPackages then [ ] else [ "profiles.server.extraPackages must be a list of package names, got ${builtins.typeOf extraPackages}" ])
        ++ (if builtins.isList extraPackages then checkExtraPackages extraPackages else [ ]);
    in
    if errors == [ ]
    then { inherit enable extraPackages; }
    else
      throw ''
        profiles.server failed eval-boundary validation (SPEC.md §6, §11 M5; nix/profiles.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  renderDeclaration = { enable, extraPackages }:
    if !enable then
      {
        version = 1;
        enable = false;
        packages = [ ];
        etc = [ ];
      }
    else
      let
        packages = builtins.sort (a: b: a < b) (lib.unique (serverSeedPackages ++ extraPackages));
        etc = map
          (path: renderEtcEntry path cloudInitEtcEntries.${path})
          (builtins.attrNames cloudInitEtcEntries);
      in
      {
        version = 1;
        enable = true;
        inherit packages etc;
        cloudInit = { disabledPath = cloudInitDisabledPath; };
      };

  render = decl: renderDeclaration (validateDecl decl);

  renderJSON = decl: builtins.toJSON (render decl) + "\n";

  # exampleDeclaration -- forced through render/renderJSON at EVAL time by
  # `profiles-server-manifest-proof` below, mirroring nix/filesystems.nix's/
  # nix/localization.nix's own `exampleEntries`/`exampleDeclaration` role.
  exampleDeclaration = { enable = true; };

  # =========================================================================
  # `profiles.desktop` (GitHub issue #107; SPEC.md §11 M6) -- see this
  # file's header, "Desktop", for the full posture. Everything below
  # mirrors the `profiles.server` bindings above field-for-field, except
  # where desktop-specific (the display-manager/graphical-target wiring).
  # =========================================================================

  # -- desktopSeedPackages / desktopSeedExceptions -------------------------
  #
  # See header, "Desktop" / "What 'the upstream Server seed' means in this
  # repo". Same single M1 stdenv/archive-fetch proof fixture as
  # `serverSeedExceptions` (`hello`) -- it shares the one project-wide
  # lockfile (archive.packages.json's own header) and is excluded from the
  # parity diff for that same proof-fixture reason, NOT because it is
  # absent from upstream by accident: `hello` genuinely has no upstream
  # Ubuntu package (see tests/fixtures/upstream-manifests/ubuntu-24.04.3-
  # live-server-amd64.manifest, which does not list it).
  #
  # `htop`, `ed`, and `jq` used to sit in this list too. GitHub issue #118's
  # reconciliation against that same committed upstream manifest proved
  # they are genuine upstream Server-seed members (issue #128 already
  # corrected this section's prose to say so, but deliberately left the
  # list itself alone). They were removed from `serverSeedExceptions` (see
  # that binding's own comment above for the full "ubuntu-standard" story,
  # which mirrors here field-for-field) as a correctness fix, and removed
  # from this list too so both profiles stay identical by construction.
  desktopSeedExceptions = [ "hello" ];

  desktopSeedPackages =
    builtins.sort (a: b: a < b)
      (builtins.filter
        (p: !(builtins.elem p desktopSeedExceptions))
        (map (p: p.name) lockfile.public.packages));

  # -- display manager / graphical-target wiring ---------------------------
  #
  # Declarative data only (see header, "Desktop") -- what a real
  # `systemctl set-default graphical.target` plus a display-manager
  # package's own postinst (e.g. gdm3's `dpkg-reconfigure gdm3`, which
  # writes /etc/systemd/system/display-manager.service) would each
  # produce. Materialized into real symlinks only by
  # `packages.desktop-parity-image`'s own `extraFilesScript` below --
  # `render`/`renderDeclaration` here stay pure data, exactly like every
  # other primitive/module surface in this repo.
  graphicalTargetName = "graphical.target";
  graphicalTargetUnitPath = "/lib/systemd/system/graphical.target";
  displayManagerServiceName = "gdm.service";
  displayManagerUnitPath = "/lib/systemd/system/gdm.service";
  defaultTargetSymlinkPath = "/etc/systemd/system/default.target";
  displayManagerSymlinkPath = "/etc/systemd/system/display-manager.service";

  # -- desktop validateDecl / render (the `profiles.desktop` primitive
  #    surface) -- mirrors `checkExtraPackages`/`validateDecl` above
  #    exactly, save for the option-path name in error text. -------------
  checkDesktopExtraPackages = extraPackages:
    let
      missing = builtins.filter (p: !(debs ? ${p})) extraPackages;
    in
    if missing == [ ] then [ ]
    else [ "profiles.desktop.extraPackages: package(s) not in the locked archive set (archive.lock.json): ${builtins.concatStringsSep ", " missing} -- add them to archive.lock.json (nix/archive.nix) first." ];

  desktopValidateDecl = { enable ? false, extraPackages ? [ ] }:
    let
      errors =
        (if builtins.isBool enable then [ ] else [ "profiles.desktop.enable must be a boolean, got ${builtins.typeOf enable}" ])
        ++ (if builtins.isList extraPackages then [ ] else [ "profiles.desktop.extraPackages must be a list of package names, got ${builtins.typeOf extraPackages}" ])
        ++ (if builtins.isList extraPackages then checkDesktopExtraPackages extraPackages else [ ]);
    in
    if errors == [ ]
    then { inherit enable extraPackages; }
    else
      throw ''
        profiles.desktop failed eval-boundary validation (SPEC.md §6, §11 M6; nix/profiles.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  desktopRenderDeclaration = { enable, extraPackages }:
    if !enable then
      {
        version = 1;
        enable = false;
        packages = [ ];
        etc = [ ];
      }
    else
      let
        packages = builtins.sort (a: b: a < b) (lib.unique (desktopSeedPackages ++ extraPackages));
      in
      {
        version = 1;
        enable = true;
        inherit packages;
        etc = [ ];
        graphicalSession = {
          defaultTarget = graphicalTargetName;
          displayManager = {
            service = displayManagerServiceName;
            symlinkPath = displayManagerSymlinkPath;
          };
        };
      };

  desktopRender = decl: desktopRenderDeclaration (desktopValidateDecl decl);

  desktopRenderJSON = decl: builtins.toJSON (desktopRender decl) + "\n";

  # exampleDesktopDeclaration -- forced through desktopRender/
  # desktopRenderJSON at EVAL time by `profiles-desktop-manifest-proof`
  # below, mirroring `exampleDeclaration` above.
  exampleDesktopDeclaration = { enable = true; };
in
{
  flake.lib.profiles = {
    server = {
      inherit validateDecl render renderJSON serverSeedPackages serverSeedExceptions cloudInitDisabledPath;
    };
    desktop = {
      validateDecl = desktopValidateDecl;
      render = desktopRender;
      renderJSON = desktopRenderJSON;
      inherit desktopSeedPackages desktopSeedExceptions;
      inherit graphicalTargetName displayManagerServiceName displayManagerSymlinkPath defaultTargetSymlinkPath;
    };
  };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }:
    let
      inherit (config.flake.lib.stdenv) runInUbuntuBase;

      # -- the server parity example config, compiled through every landed
      #    base module (see this file's header, item 3) ------------------
      exampleConfig = import ../examples/server.nix;

      networkingValidated = config.flake.lib.networking.validate exampleConfig.networking;
      netplanYaml = config.flake.lib.networking.renderNetplanYAML networkingValidated;
      hostsContent = config.flake.lib.networking.renderHostsContent networkingValidated;
      hostnameContent = config.flake.lib.networking.renderHostnameContent networkingValidated;

      localizationRendered = config.flake.lib.localization.render {
        inherit (exampleConfig) i18n console time;
      };
      findLocalizationEtc = path:
        (builtins.head (builtins.filter (e: e.path == path) localizationRendered.etc)).text;
      localeText = findLocalizationEtc "default/locale";
      keyboardText = findLocalizationEtc "default/keyboard";
      timezoneText = findLocalizationEtc "timezone";
      timesyncdText = findLocalizationEtc "systemd/timesyncd.conf";

      filesystemsRendered = config.flake.lib.fileSystems.render {
        inherit (exampleConfig) fileSystems swapDevices;
      };

      usersManifest = config.flake.lib.users.mkManifest {
        inherit (exampleConfig) users groups;
      };
      usersManifestJSON = config.flake.lib.users.renderManifestJSON usersManifest;

      serverManifest = render { enable = exampleConfig.profiles.server.enable; };
      serverPackagesText = builtins.concatStringsSep "\n" serverManifest.packages + "\n";

      # -- the boot pipeline (nix/boot.nix; same machinery boot-image-proof
      #    already proves works, GitHub issue #10/M1) ---------------------
      bootSpec = mkBootSpec { };
      flavor = resolveKernelFlavor bootSpec.kernel;

      # ubx-server-parity-assert.service -- a SELF-CONTAINED assertion unit
      # (not `bootRootfs`'s own `withE2eAssertService`, which powers the
      # guest off on ITS OWN success -- two independent oneshot units both
      # racing to `systemctl poweroff` off the same `multi-user.target`
      # would be a real race; this profile needs its own checks folded into
      # ONE unit instead). Checks, in order: the M1 generation marker + ubx
      # binary (same two checks `withE2eAssertService`'s own script makes,
      # duplicated rather than shared since that script is not exposed as a
      # reusable fragment -- see nix/boot.nix's own `e2eAssertScript`), the
      # cloud-init disabled marker (SPEC.md §12 R12), the rendered
      # networking/hostname files exist, and -- the M5 exit criterion
      # itself -- that every `profiles.server`-declared seed package is
      # actually `dpkg`-installed and none of the enumerated fixture
      # exceptions leaked in (see this file's header, "What 'the upstream
      # Server seed' means in this repo", for why this is a subset check,
      # not full-set equality against a live upstream manifest this
      # environment cannot fetch).
      serverParityAssertScript = ''
        #!/bin/sh
        # /usr/local/bin/ubx-server-parity-assert -- baked in only by
        # packages.server-parity-image below; never a real installer-
        # produced system (SPEC.md §10; mirrors nix/boot.nix's own
        # ubx-e2e-assert posture).
        set -e

        current="$(cat /ubx/generations/current 2>/dev/null || true)"
        if [ -z "$current" ] || [ ! -f "/ubx/generations/$current/marker" ]; then
          echo "UBX-SERVER-PARITY-FAIL: generation marker file missing (current='$current')"
          exit 1
        fi

        if [ ! -x /ubx/bin/ubx ]; then
          echo "UBX-SERVER-PARITY-FAIL: /ubx/bin/ubx missing or not executable"
          exit 1
        fi

        if ! /ubx/bin/ubx --help > /dev/null 2>&1; then
          echo "UBX-SERVER-PARITY-FAIL: /ubx/bin/ubx --help did not exit 0"
          exit 1
        fi

        if [ ! -f "${cloudInitDisabledPath}" ]; then
          echo "UBX-SERVER-PARITY-FAIL: ${cloudInitDisabledPath} marker missing (SPEC.md sec12 R12)"
          exit 1
        fi

        if [ ! -f /etc/netplan/01-ubuntnix.yaml ]; then
          echo "UBX-SERVER-PARITY-FAIL: /etc/netplan/01-ubuntnix.yaml missing"
          exit 1
        fi

        if [ "$(cat /etc/hostname)" != "${networkingValidated.hostname}" ]; then
          echo "UBX-SERVER-PARITY-FAIL: /etc/hostname mismatch (got '$(cat /etc/hostname)', want '${networkingValidated.hostname}')"
          exit 1
        fi

        # Use dpkg -l piped through awk (column 2) rather than a dpkg-query
        # format string, because a dpkg-query format string would contain
        # brace-wrapped field names that Nix would try to interpolate out of
        # this indented-string script -- awk's fixed-column output needs no
        # such escaping. "ii" lines are dpkg's own "installed" status marker;
        # the trailing sed strips a possible arch qualifier.
        installed="$(dpkg -l | awk '/^ii/ {print $2}' | sed 's/:.*$//' | sort -u)"

        missing=""
        for pkg in $(cat /ubx/generations/1/server-seed-packages.txt); do
          if ! printf '%s\n' "$installed" | grep -qx "$pkg"; then
            missing="$missing $pkg"
          fi
        done

        unexpected=""
        for pkg in ${builtins.concatStringsSep " " serverSeedExceptions}; do
          if printf '%s\n' "$installed" | grep -qx "$pkg"; then
            unexpected="$unexpected $pkg"
          fi
        done

        if [ -n "$missing" ] || [ -n "$unexpected" ]; then
          echo "UBX-SERVER-PARITY-FAIL: missing-seed-packages=[$missing] unexpected-exception-packages=[$unexpected]"
          exit 1
        fi

        echo "UBX-SERVER-PARITY-PASS"
        sync
        systemctl poweroff
      '';

      serverParityAssertUnit = ''
        [Unit]
        Description=ubuntnix server-parity assertions (tests/e2e; server-parity-image only)
        After=multi-user.target
        Requires=multi-user.target

        [Service]
        Type=oneshot
        StandardOutput=journal+console
        StandardError=journal+console
        ExecStart=/usr/local/bin/ubx-server-parity-assert

        [Install]
        WantedBy=multi-user.target
      '';

      serverParityExtraFilesScript = ''
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/netplan" "$out/etc/default" "$out/etc/systemd" "$out/etc/cloud"

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/hostname" <<'UBX_PROFILES_EOF'
        ${hostnameContent}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/hosts" <<'UBX_PROFILES_EOF'
        ${hostsContent}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/netplan/01-ubuntnix.yaml" <<'UBX_PROFILES_EOF'
        ${netplanYaml}
        UBX_PROFILES_EOF
        ubxrun "$UBX_BASE/bin/chmod" 0600 "$out/etc/netplan/01-ubuntnix.yaml"

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/default/locale" <<'UBX_PROFILES_EOF'
        ${localeText}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/default/keyboard" <<'UBX_PROFILES_EOF'
        ${keyboardText}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/timezone" <<'UBX_PROFILES_EOF'
        ${timezoneText}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/timesyncd.conf" <<'UBX_PROFILES_EOF'
        ${timesyncdText}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/fstab" <<'UBX_PROFILES_EOF'
        ${filesystemsRendered.fstabContent}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/cloud/cloud-init.disabled" <<'UBX_PROFILES_EOF'
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/ubx/generations/1"
        ubxrun "$UBX_BASE/bin/cat" > "$out/ubx/generations/1/users-manifest.json" <<'UBX_PROFILES_EOF'
        ${usersManifestJSON}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/ubx/generations/1/server-seed-packages.txt" <<'UBX_PROFILES_EOF'
        ${serverPackagesText}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-server-parity-assert" <<'UBX_PROFILES_SCRIPT_EOF'
        ${serverParityAssertScript}
        UBX_PROFILES_SCRIPT_EOF
        ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-server-parity-assert"

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/ubx-server-parity-assert.service" <<'UBX_PROFILES_UNIT_EOF'
        ${serverParityAssertUnit}
        UBX_PROFILES_UNIT_EOF
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/multi-user.target.wants"
        ubxrun "$UBX_BASE/bin/ln" -sf ../ubx-server-parity-assert.service \
          "$out/etc/systemd/system/multi-user.target.wants/ubx-server-parity-assert.service"
      '';

      serverParityRootfs = bootRootfs {
        inherit system bootSpec;
        name = "server-parity";
        packages = serverManifest.packages;
        preseed = localizationRendered.debconf;
        extraFilesScript = serverParityExtraFilesScript;
      };

      serverParitySquashfs = squashfsImage {
        inherit system;
        name = "server-parity";
        rootfs = serverParityRootfs;
      };

      serverParityKernel = kernelArtifacts {
        inherit system flavor;
        name = "server-parity";
        rootfs = serverParityRootfs;
      };

      serverParityGeneration = {
        index = 1;
        title = "ubuntnix server-parity generation 1 (${bootSpec.kernel})";
        kernelPath = "/vmlinuz-${flavor}";
        initrdPath = "/initrd.img-${flavor}";
        rootDevice = "/dev/vda2";
        kernelParams = bootSpec.kernelParams ++ [
          "rootfstype=squashfs"
          "console=ttyS0"
        ];
      };

      serverParityGrubCfg = grubCfg {
        inherit system;
        name = "server-parity";
        generations = [ serverParityGeneration ];
      };

      serverParityDiskImage = diskImage {
        inherit system flavor;
        name = "server-parity";
        squashfs = serverParitySquashfs;
        kernel = serverParityKernel;
        grubCfgDrv = serverParityGrubCfg;
      };

      # =======================================================================
      # `profiles.desktop` (GitHub issue #107; SPEC.md §11 M6) -- mirrors
      # every server-parity binding above field-for-field. See this file's
      # header, "Desktop", for the full posture and scope boundary (issue
      # #108 owns the live QEMU graphical-boot e2e; this is a build-time
      # proof target only).
      # =======================================================================

      # -- the desktop parity example config, compiled through the same
      #    landed base modules as the server parity config -----------------
      desktopExampleConfig = import ../examples/desktop.nix;

      desktopNetworkingValidated = config.flake.lib.networking.validate desktopExampleConfig.networking;
      desktopNetplanYaml = config.flake.lib.networking.renderNetplanYAML desktopNetworkingValidated;
      desktopHostsContent = config.flake.lib.networking.renderHostsContent desktopNetworkingValidated;
      desktopHostnameContent = config.flake.lib.networking.renderHostnameContent desktopNetworkingValidated;

      desktopLocalizationRendered = config.flake.lib.localization.render {
        inherit (desktopExampleConfig) i18n console time;
      };
      findDesktopLocalizationEtc = path:
        (builtins.head (builtins.filter (e: e.path == path) desktopLocalizationRendered.etc)).text;
      desktopLocaleText = findDesktopLocalizationEtc "default/locale";
      desktopKeyboardText = findDesktopLocalizationEtc "default/keyboard";
      desktopTimezoneText = findDesktopLocalizationEtc "timezone";
      desktopTimesyncdText = findDesktopLocalizationEtc "systemd/timesyncd.conf";

      desktopFilesystemsRendered = config.flake.lib.fileSystems.render {
        inherit (desktopExampleConfig) fileSystems swapDevices;
      };

      desktopUsersManifest = config.flake.lib.users.mkManifest {
        inherit (desktopExampleConfig) users groups;
      };
      desktopUsersManifestJSON = config.flake.lib.users.renderManifestJSON desktopUsersManifest;

      desktopManifest = desktopRender { enable = desktopExampleConfig.profiles.desktop.enable; };
      desktopPackagesText = builtins.concatStringsSep "\n" desktopManifest.packages + "\n";

      # ubx-desktop-parity-assert.service -- mirrors
      # ubx-server-parity-assert.service exactly (see above for the "one
      # self-contained unit" reasoning), plus one desktop-specific check:
      # the default.target/display-manager symlinks this profile's own
      # extraFilesScript writes below are actually in place with the
      # expected targets. Deliberately does NOT check that gdm/gnome-shell
      # are dpkg-installed or that a graphical session actually starts --
      # neither package is in today's locked archive set yet (see this
      # file's header, "Desktop", PM ACTION REQUIRED) and booting to a real
      # graphical session is issue #108's own scope, not this proof's.
      desktopParityAssertScript = ''
        #!/bin/sh
        # /usr/local/bin/ubx-desktop-parity-assert -- baked in only by
        # packages.desktop-parity-image below; never a real installer-
        # produced system (SPEC.md §10; mirrors ubx-server-parity-assert).
        set -e

        current="$(cat /ubx/generations/current 2>/dev/null || true)"
        if [ -z "$current" ] || [ ! -f "/ubx/generations/$current/marker" ]; then
          echo "UBX-DESKTOP-PARITY-FAIL: generation marker file missing (current='$current')"
          exit 1
        fi

        if [ ! -x /ubx/bin/ubx ]; then
          echo "UBX-DESKTOP-PARITY-FAIL: /ubx/bin/ubx missing or not executable"
          exit 1
        fi

        if ! /ubx/bin/ubx --help > /dev/null 2>&1; then
          echo "UBX-DESKTOP-PARITY-FAIL: /ubx/bin/ubx --help did not exit 0"
          exit 1
        fi

        if [ ! -f /etc/netplan/01-ubuntnix.yaml ]; then
          echo "UBX-DESKTOP-PARITY-FAIL: /etc/netplan/01-ubuntnix.yaml missing"
          exit 1
        fi

        if [ "$(cat /etc/hostname)" != "${desktopNetworkingValidated.hostname}" ]; then
          echo "UBX-DESKTOP-PARITY-FAIL: /etc/hostname mismatch (got '$(cat /etc/hostname)', want '${desktopNetworkingValidated.hostname}')"
          exit 1
        fi

        if [ "$(readlink '${defaultTargetSymlinkPath}')" != "${graphicalTargetUnitPath}" ]; then
          echo "UBX-DESKTOP-PARITY-FAIL: ${defaultTargetSymlinkPath} does not point at ${graphicalTargetUnitPath}"
          exit 1
        fi

        if [ "$(readlink '${displayManagerSymlinkPath}')" != "${displayManagerUnitPath}" ]; then
          echo "UBX-DESKTOP-PARITY-FAIL: ${displayManagerSymlinkPath} does not point at ${displayManagerUnitPath}"
          exit 1
        fi

        # See nix/profiles.nix's serverParityAssertScript for why awk/sed
        # over dpkg -l is used instead of a dpkg-query format string.
        installed="$(dpkg -l | awk '/^ii/ {print $2}' | sed 's/:.*$//' | sort -u)"

        missing=""
        for pkg in $(cat /ubx/generations/1/desktop-seed-packages.txt); do
          if ! printf '%s\n' "$installed" | grep -qx "$pkg"; then
            missing="$missing $pkg"
          fi
        done

        unexpected=""
        for pkg in ${builtins.concatStringsSep " " desktopSeedExceptions}; do
          if printf '%s\n' "$installed" | grep -qx "$pkg"; then
            unexpected="$unexpected $pkg"
          fi
        done

        if [ -n "$missing" ] || [ -n "$unexpected" ]; then
          echo "UBX-DESKTOP-PARITY-FAIL: missing-seed-packages=[$missing] unexpected-exception-packages=[$unexpected]"
          exit 1
        fi

        echo "UBX-DESKTOP-PARITY-PASS"
        sync
        systemctl poweroff
      '';

      desktopParityAssertUnit = ''
        [Unit]
        Description=ubuntnix desktop-parity assertions (tests/e2e; desktop-parity-image only)
        After=multi-user.target
        Requires=multi-user.target

        [Service]
        Type=oneshot
        StandardOutput=journal+console
        StandardError=journal+console
        ExecStart=/usr/local/bin/ubx-desktop-parity-assert

        [Install]
        WantedBy=multi-user.target
      '';

      desktopParityExtraFilesScript = ''
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/netplan" "$out/etc/default" "$out/etc/systemd/system"

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/hostname" <<'UBX_PROFILES_EOF'
        ${desktopHostnameContent}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/hosts" <<'UBX_PROFILES_EOF'
        ${desktopHostsContent}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/netplan/01-ubuntnix.yaml" <<'UBX_PROFILES_EOF'
        ${desktopNetplanYaml}
        UBX_PROFILES_EOF
        ubxrun "$UBX_BASE/bin/chmod" 0600 "$out/etc/netplan/01-ubuntnix.yaml"

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/default/locale" <<'UBX_PROFILES_EOF'
        ${desktopLocaleText}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/default/keyboard" <<'UBX_PROFILES_EOF'
        ${desktopKeyboardText}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/timezone" <<'UBX_PROFILES_EOF'
        ${desktopTimezoneText}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/timesyncd.conf" <<'UBX_PROFILES_EOF'
        ${desktopTimesyncdText}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/fstab" <<'UBX_PROFILES_EOF'
        ${desktopFilesystemsRendered.fstabContent}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/ubx/generations/1"
        ubxrun "$UBX_BASE/bin/cat" > "$out/ubx/generations/1/users-manifest.json" <<'UBX_PROFILES_EOF'
        ${desktopUsersManifestJSON}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/ubx/generations/1/desktop-seed-packages.txt" <<'UBX_PROFILES_EOF'
        ${desktopPackagesText}
        UBX_PROFILES_EOF

        ubxrun "$UBX_BASE/bin/cat" > "$out/usr/local/bin/ubx-desktop-parity-assert" <<'UBX_PROFILES_SCRIPT_EOF'
        ${desktopParityAssertScript}
        UBX_PROFILES_SCRIPT_EOF
        ubxrun "$UBX_BASE/bin/chmod" +x "$out/usr/local/bin/ubx-desktop-parity-assert"

        ubxrun "$UBX_BASE/bin/cat" > "$out/etc/systemd/system/ubx-desktop-parity-assert.service" <<'UBX_PROFILES_UNIT_EOF'
        ${desktopParityAssertUnit}
        UBX_PROFILES_UNIT_EOF
        ubxrun "$UBX_BASE/bin/mkdir" -p "$out/etc/systemd/system/multi-user.target.wants"
        ubxrun "$UBX_BASE/bin/ln" -sf ../ubx-desktop-parity-assert.service \
          "$out/etc/systemd/system/multi-user.target.wants/ubx-desktop-parity-assert.service"

        # -- display-manager / graphical.target wiring (see this file's
        #    header, "Desktop") -- the declarative data
        #    `desktopManifest.graphicalSession` carries, materialized here
        #    as real symlinks (mirrors what `systemctl set-default
        #    graphical.target` / a display-manager package's own postinst
        #    would each write on a real install). `graphical.target` itself
        #    ships with the `systemd` package (already in today's locked
        #    seed -- see `desktopSeedPackages` above), so the default.target
        #    symlink below likely resolves for real; `gdm.service` does
        #    NOT, since the `gdm3` package is outside today's locked
        #    archive set (this file's header, PM ACTION REQUIRED) -- that
        #    symlink is deliberately dangling until it lands. `ln -sf`
        #    needs no target to exist either way, so both symlinks are
        #    still real, inspectable artifacts of the intended wiring.
        ubxrun "$UBX_BASE/bin/ln" -sf "${graphicalTargetUnitPath}" "$out${defaultTargetSymlinkPath}"
        ubxrun "$UBX_BASE/bin/ln" -sf "${displayManagerUnitPath}" "$out${displayManagerSymlinkPath}"
      '';

      desktopParityRootfs = bootRootfs {
        inherit system bootSpec;
        name = "desktop-parity";
        packages = desktopManifest.packages;
        preseed = desktopLocalizationRendered.debconf;
        extraFilesScript = desktopParityExtraFilesScript;
      };

      desktopParitySquashfs = squashfsImage {
        inherit system;
        name = "desktop-parity";
        rootfs = desktopParityRootfs;
      };

      desktopParityKernel = kernelArtifacts {
        inherit system flavor;
        name = "desktop-parity";
        rootfs = desktopParityRootfs;
      };

      desktopParityGeneration = {
        index = 1;
        title = "ubuntnix desktop-parity generation 1 (${bootSpec.kernel})";
        kernelPath = "/vmlinuz-${flavor}";
        initrdPath = "/initrd.img-${flavor}";
        rootDevice = "/dev/vda2";
        kernelParams = bootSpec.kernelParams ++ [
          "rootfstype=squashfs"
          "console=ttyS0"
        ];
      };

      desktopParityGrubCfg = grubCfg {
        inherit system;
        name = "desktop-parity";
        generations = [ desktopParityGeneration ];
      };

      desktopParityDiskImage = diskImage {
        inherit system flavor;
        name = "desktop-parity";
        squashfs = desktopParitySquashfs;
        kernel = desktopParityKernel;
        grubCfgDrv = desktopParityGrubCfg;
      };
    in
    {
      # profiles-server-manifest-proof: forces validateDecl/render/renderJSON
      # against `exampleDeclaration` at EVAL time -- see nix/filesystems.nix's own
      # `filesystems-manifest-proof` for why constructing this derivation is
      # enough, without a real `nix build`, to make CI's "flake" job
      # (`flake check --no-build`) exercise this file's validation/
      # rendering logic for real. tests/unit/182-profiles-flake-wiring.sh
      # statically greps this file's own code for the real `throw`s,
      # mirroring tests/unit/178's/180's own posture.
      packages.profiles-server-manifest-proof = runInUbuntuBase {
        inherit system;
        name = "profiles-server-manifest-proof";
        script = ''
          {
            echo "MARKER=ubuntnix-profiles-server-manifest-proof-v1"
            cat <<'UBX_MANIFEST_EOF'
          ${renderJSON exampleDeclaration}
          UBX_MANIFEST_EOF
          } > "$out"
        '';
      };

      # server-parity-image (GitHub issue #99, SPEC.md §11 M5 exit
      # criterion): the actual bootable disk image
      # tests/e2e/050-qemu-server-parity-e2e.sh boots, built from
      # examples/server.nix compiled through every landed base module and
      # `profiles.server` itself, on the same M1 boot pipeline
      # `boot-image-proof` already proves works.
      packages.server-parity-image = serverParityDiskImage;

      # profiles-desktop-manifest-proof: forces desktopValidateDecl/
      # desktopRender/desktopRenderJSON against `exampleDesktopDeclaration`
      # at EVAL time -- mirrors profiles-server-manifest-proof above
      # exactly (GitHub issue #107).
      packages.profiles-desktop-manifest-proof = runInUbuntuBase {
        inherit system;
        name = "profiles-desktop-manifest-proof";
        script = ''
          {
            echo "MARKER=ubuntnix-profiles-desktop-manifest-proof-v1"
            cat <<'UBX_MANIFEST_EOF'
          ${desktopRenderJSON exampleDesktopDeclaration}
          UBX_MANIFEST_EOF
          } > "$out"
        '';
      };

      # desktop-parity-image (GitHub issue #107, SPEC.md §11 M6): the
      # BUILD-TIME parity/proof target this issue's own scope calls for --
      # examples/desktop.nix compiled through every landed base module and
      # `profiles.desktop` itself, on the same M1 boot pipeline
      # `boot-image-proof`/`server-parity-image` already prove works, so
      # CI's flake-check/build forces evaluation of the whole desktop
      # render pipeline. The LIVE graphical-boot QEMU e2e (structured so
      # this target is ready to be that e2e's subject) is GitHub issue
      # #108, deliberately not built here -- see this file's header,
      # "Desktop".
      packages.desktop-parity-image = desktopParityDiskImage;
    };
}
