# nix/profiles.nix — the `profiles.server` showcase module (SPEC.md §6's
# `profiles.server.enable = true; # -> upstream server seed` surface, §10
# "parity example configs", §11 M5 exit criterion; GitHub issue #99).
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
# (`serverSeedExceptions`) that were added purely to exercise the stdenv/
# archive-fetch machinery (issue #6/#7) and are not real members of any
# upstream Server seed. This is the exact same posture nix/archive.nix's
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
  # `hello`/`htop`/`ed`/`jq` are the small M1 stdenv/archive-fetch proof
  # fixtures (nix/stdenv.nix/nix/archive.nix/nix/compose.nix's own proof
  # packages) that happen to share the one project-wide lockfile with every
  # real boot-critical package (kernel, grub, filesystem tools, ...) — see
  # archive.packages.json's own header for why the lockfile is one shared
  # set rather than per-consumer subsets. None of the four is a real member
  # of any upstream Ubuntu Server install.
  serverSeedExceptions = [ "hello" "htop" "ed" "jq" ];

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
in
{
  flake.lib.profiles = {
    server = {
      inherit validateDecl render renderJSON serverSeedPackages serverSeedExceptions cloudInitDisabledPath;
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
    };
}
