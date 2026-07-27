# nix/filesystems.nix — the `fileSystems`/`swapDevices` showcase-module
# primitive surface: declaration + eval-time validation + rendering to
# `/etc/fstab` entries and matching systemd `.mount`/`.swap` units
# (SPEC.md §4.3 "fstab / systemd mount units + swap", §6 configuration
# surface's `fileSystems."/data" = { ... };  # → fstab / systemd mount
# units + swap`; GitHub issue #96).
#
# -- What this file is, and what it deliberately is NOT ----------------------
#
# Exactly the shape nix/crypttab.nix's own header establishes for a
# showcase-module domain — this file is its direct sibling and closest
# analog (read that file's header first if you haven't): a `validate`
# function (eval-boundary enforcement) and a `render` function (pure --
# every string this file emits is built from validated, punctuation-light
# fields it already controls, so -- exactly like nix/crypttab.nix's own
# reasoning -- there is no heredoc-collision risk and no store object to
# build; the manifest is a plain JSON-ready attrset) exposed under
# `flake.lib.fileSystems`, ready for a future `ubuntnix.fileSystems`/
# `ubuntnix.swapDevices` module option to call once real module evaluation
# exists (nix/etc.nix's header explains the "no modules/ tree yet" caveat
# this project is still under -- it applies verbatim here too).
# `perSystem.packages.filesystems-manifest-proof` (bottom) forces
# `validate`/`render` against a fixed example declaration at eval time, the
# same role `crypttab-manifest-proof` plays for nix/crypttab.nix.
#
# This file does NOT diff two generations' mount state against a real,
# running system, does NOT call `mount`/`swapon`, and does NOT decide which
# real disk backs a declared filesystem -- that is on-device, diff-driven
# planner/executor territory (this project's `bin/ubx-*` split), a LATER
# issue's job, exactly the "generation vs activation" line nix/crypttab.nix,
# nix/etc.nix, nix/pro.nix each already draw for their own domains.
#
# -- The declaration surface (SPEC.md §6) -------------------------------
#
#   ubuntnix.fileSystems."/data" = {
#     device = "/dev/disk/by-uuid/1234-5678-9abc-def0";  # required; the
#                                     # backing device fstab(5) col 1 -- a
#                                     # UUID/by-id/by-partuuid path is
#                                     # strongly preferred over a raw
#                                     # /dev/sdXN for the same "device node
#                                     # names are not stable across boots"
#                                     # reason nix/crypttab.nix's header
#                                     # gives, but (exactly like that file)
#                                     # this one does not itself enforce
#                                     # that choice -- only that the string
#                                     # is an absolute path. `/dev/mapper/
#                                     # <name>` -- the device a
#                                     # `ubuntnix.crypttab.<name>` entry's
#                                     # unlocked mapper is always found at
#                                     # (systemd-cryptsetup-generator(8)) --
#                                     # is equally accepted; see "Interop
#                                     # with nix/crypttab.nix" below.
#     fsType = "ext4";                # default "ext4" (fstab(5) col 3).
#     options = "defaults";           # default "defaults" (fstab(5) col 4).
#     dump = 0;                       # default 0 (fstab(5) col 5).
#     passno = 2;                     # default 2 (fstab(5) col 6) -- the
#                                     # stock non-root-filesystem value;
#                                     # this file has no notion of "/" (the
#                                     # root filesystem is baked into the
#                                     # compose-time image, nix/compose.nix
#                                     # -- see that file's own header --
#                                     # never a `ubuntnix.fileSystems`
#                                     # declaration), so there is no
#                                     # special-cased default for it here.
#   };
#
#   ubuntnix.swapDevices = [
#     { device = "/dev/disk/by-uuid/...";  # required; absolute path, same
#                                          # posture as fileSystems' device.
#       options = "";                     # default "" (extra fstab(5)
#                                          # col 4 tokens, comma-joined
#                                          # with "sw"; e.g. "discard").
#       priority = null;                  # default null; when set, an
#                                          # integer -- systemd.swap(5)'s
#                                          # Priority=, and fstab(5)'s own
#                                          # "pri=<N>" option token.
#     }
#   ];
#
# The `ubuntnix.fileSystems` attribute name is the mount point (fstab(5)
# col 2) -- matching the SPEC.md example's own `fileSystems."/data"` shape,
# exactly parallel to `ubuntnix.etc`'s path-keyed attrset.
# `ubuntnix.swapDevices` is a LIST, not an attrset: unlike a mount point, a
# swap device has no natural per-entry Nix-attribute-safe identifier (its
# only identity is its device path, which is not itself well-formed as an
# attribute name), so it takes the same "ordered list of attrsets" shape
# NixOS' own `swapDevices` option does.
#
# `fileSystems`/`swapDevices` throughout this file are exactly those two
# values -- `render`'s first two arguments.
#
# -- Interop with nix/crypttab.nix -------------------------------------------
#
# A LUKS volume declared as `ubuntnix.crypttab."data" = { ... };` unlocks,
# at boot, to `/dev/mapper/data` (systemd-cryptsetup-generator(8); see
# nix/crypttab.nix's own header, "Mount unit content"). That volume's
# CONTENT can be mounted either of two ways, and this file supports both --
# they are NOT mutually exclusive designs a caller must choose between up
# front, they are just two different attribute names to write to:
#
#   1. nix/crypttab.nix's OWN `mountPoint` field on the crypttab entry
#      itself (that file renders its own matching `.mount` unit, with
#      `After=`/`Requires=systemd-cryptsetup@<name>.service` baked in).
#   2. THIS file: declare `ubuntnix.crypttab."data"` with NO `mountPoint`
#      (decrypt-only), and separately declare
#      `ubuntnix.fileSystems."/mnt/data".device = "/dev/mapper/data";` --
#      this file recognizes the `/dev/mapper/<name>` shape (`cryptDepOf`
#      below) and renders the IDENTICAL `After=`/`Requires=
#      systemd-cryptsetup@<name>.service` wiring into ITS OWN mount unit,
#      so the two files compose cleanly: crypttab.nix owns unlocking,
#      this file owns where the unlocked content is actually mounted, and
#      neither has to know the other's Nix code exists to get the
#      dependency ordering right -- both just apply
#      systemd-cryptsetup-generator(8)'s own documented unit-naming rule
#      to the mapper name.
#
# A `render` caller does not have to pass anything crypttab-specific for
# this to work: `cryptDepOf` below recognizes the `/dev/mapper/<name>`
# device shape STRUCTURALLY (no cross-file lookup needed -- crypttab.nix's
# own mapper-name grammar, `nameRe = "[a-z][a-z0-9_]*"`, is duplicated here
# verbatim so a real mapper name and only a real mapper name matches). Any
# `/dev/mapper/<name>` device is assumed cryptsetup-backed and gets the
# `systemd-cryptsetup@<name>.service` wiring; this is deliberately
# permissive (it does not require the named crypttab entry to actually be
# declared anywhere this file can see) for the same reason nix/crypttab.nix
# itself never validates that a `device` UUID it's given really exists --
# neither file has cross-domain visibility into the other's declarations at
# THIS eval boundary (each is one dendritic module, evaluated independently
# per SPEC.md §2 G8), and a real mismatch (no such crypttab entry actually
# unlocks that mapper name) surfaces the ordinary way any dangling
# `Requires=` would at boot -- not something this eval-time validator can
# or should try to catch.
#
# -- Eval-boundary validation (`validate`) -------------------------------
#
# Every declared entry (in either `fileSystems` or `swapDevices`) is
# checked, and EVERY violation across the whole declaration is collected
# into one `throw` (never just the first -- same posture as
# nix/crypttab.nix's/nix/etc.nix's own `validate`):
#   - `fileSystems."<mountPoint>"`: the mount point (attribute name) must
#     be an absolute path with no empty/"."/".." segment -- reuses
#     nix/crypttab.nix's own `absPathOk` rule verbatim (segments MAY
#     contain "-", a real mount point legitimately does, e.g.
#     "/mnt/backup-data" -- same carve-out that file's header documents);
#   - `device` must be an absolute path (either shape from "Interop" above
#     is just an absolute path from this check's point of view);
#   - `fsType`/`options` must be non-empty/non-null strings (`fsType`
#     non-empty; `options` may be `""`, e.g. a bare `defaults`-only mount
#     with no extra tokens, so only string-typedness is required there --
#     same "opaque, passed through verbatim" posture nix/crypttab.nix's
#     `options` field takes);
#   - `dump`/`passno` must be non-negative integers;
#   - `swapDevices[i].device` must be an absolute path, `options` a
#     string, `priority` either `null` or an integer;
#   - no two `fileSystems` entries may declare the same `device` (a real
#     block device cannot be usefully double-mounted by two independent
#     fstab lines under this project's declarative model), and no two
#     `swapDevices` entries may declare the same `device` either.
#
# -- Rendering (`render`) -------------------------------------------------
#
# `render { fileSystems; swapDevices; }` first calls `validate`, then for
# every filesystem, in sorted-by-mount-point order (`builtins.attrNames`,
# nix/etc.nix's own "deterministic ordering for free" reasoning), composes:
#   - its fstab(5) line: "<device> <mountPoint> <fsType> <options> <dump>
#     <passno>";
#   - its `.mount` unit name (nix/crypttab.nix's/nix/boot.nix's own
#     "drop the leading '/', turn every remaining '/' into '-', append the
#     suffix" scheme, applied to the mount point -- see nix/crypttab.nix's
#     header, "Mount unit naming", for the identical, already-documented
#     "a mount point whose OWN segments contain a literal '-' is not
#     specially escaped" limitation, carried over unchanged here) and full
#     unit text (see "Rendered unit shapes" below).
# For every swap device, in the LIST's own declared order (a list has no
# natural sort key other than `device`, which this function does sort by,
# for the same determinism reason), composes its fstab(5) line
# ("<device> none swap <options> 0 0") and its `.swap` unit name/text.
#
# The returned manifest (JSON-ready, mirroring nix/crypttab.nix's own
# `render` return shape):
#
#   { "version": 1,
#     "fstabContent": "<every fileSystems + swapDevices line, sorted,
#                       joined with \"\\n\", trailing \"\\n\">",
#     "fileSystems": [
#       { "mountPoint", "device", "fsType", "options", "dump", "passno",
#         "fstabLine",
#         "cryptMapperName": <string, or null -- see "Interop" above>,
#         "mountUnitName", "mountUnitContent" },
#       ... sorted by mountPoint ],
#     "swapDevices": [
#       { "device", "options", "priority", "fstabLine",
#         "swapUnitName", "swapUnitContent" },
#       ... sorted by device ]
#   }
#
# -- Rendered unit shapes -------------------------------------------------
#
# `.mount` unit (non-crypttab-backed device -- no `[Unit]` After/Requires
# beyond the description; systemd's own fstab-generator-equivalent
# behaviour for a real block device's `What=` is to synthesize the right
# device-unit dependency on its own, so nothing extra is needed here):
#
#   [Unit]
#   Description=ubuntnix mount for "<mountPoint>" (SPEC.md §4.3 "fstab /
#   systemd mount units + swap"; GitHub issue #96)
#
#   [Mount]
#   What=<device>
#   Where=<mountPoint>
#   Type=<fsType>
#   Options=<options>
#
#   [Install]
#   WantedBy=local-fs.target
#
# `.mount` unit (crypttab-backed device, `/dev/mapper/<name>` -- see
# "Interop" above; identical to the above except for two extra `[Unit]`
# lines, exactly nix/crypttab.nix's own rendered unit's `[Unit]` section):
#
#   [Unit]
#   Description=ubuntnix mount for "<mountPoint>" (SPEC.md §4.3 "fstab /
#   systemd mount units + swap"; GitHub issue #96)
#   After=systemd-cryptsetup@<name>.service
#   Requires=systemd-cryptsetup@<name>.service
#
#   [Mount]
#   ... (unchanged)
#
# `.swap` unit:
#
#   [Unit]
#   Description=ubuntnix swap for "<device>" (SPEC.md §4.3 "fstab / systemd
#   mount units + swap"; GitHub issue #96)
#
#   [Swap]
#   What=<device>
#   Options=<options>          -- OMITTED entirely when options == ""
#   Priority=<priority>        -- OMITTED entirely when priority == null
#
#   [Install]
#   WantedBy=swap.target
#
# `.swap` unit naming follows the identical "drop leading '/', '/' -> '-',
# append suffix" scheme as `.mount` units, applied to `device` instead of a
# mount point (systemd.swap(5): a `.swap` unit's name must equal the
# escaped form of its `What=` path, exactly parallel to `.mount`'s
# Where=-must-match-filename rule) -- same documented "'-' in the path's
# own segments is not specially escaped" limitation.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  # -- validation ------------------------------------------------------------
  #
  # Mount-point path check: nix/crypttab.nix's own `absPathOk`/`segmentOk`,
  # duplicated verbatim (see that file's header, "Mount unit naming", for
  # why segments MAY contain "-").
  segmentOk = seg: seg != "" && seg != "." && seg != ".." && builtins.match "[A-Za-z0-9._-]+" seg != null;
  absPathOk = path:
    builtins.isString path
    && path != ""
    && builtins.substring 0 1 path == "/"
    && path != "/"
    && builtins.all segmentOk (lib.splitString "/" (builtins.substring 1 (builtins.stringLength path - 1) path));

  nonNegIntOk = v: builtins.isInt v && v >= 0;

  checkFileSystemEntry = mountPoint: e:
    let
      hasDevice = e ? device;
      device = e.device or "";
      fsType = e.fsType or "ext4";
      options = e.options or "defaults";
      dump = e.dump or 0;
      passno = e.passno or 2;
      mpOk = absPathOk mountPoint;
    in
    (if mpOk then [ ] else [ "ubuntnix.fileSystems.\"${toString mountPoint}\": mount point must be an absolute path with no empty/'.'/'..' segment" ])
    ++ (if hasDevice && absPathOk device then [ ] else [ "ubuntnix.fileSystems.\"${mountPoint}\": device must be set to an absolute path (e.g. /dev/disk/by-uuid/... or /dev/mapper/<name>)" ])
    ++ (if builtins.isString fsType && fsType != "" then [ ] else [ "ubuntnix.fileSystems.\"${mountPoint}\": fsType must be a non-empty string" ])
    ++ (if builtins.isString options then [ ] else [ "ubuntnix.fileSystems.\"${mountPoint}\": options must be a string" ])
    ++ (if nonNegIntOk dump then [ ] else [ "ubuntnix.fileSystems.\"${mountPoint}\": dump must be a non-negative integer" ])
    ++ (if nonNegIntOk passno then [ ] else [ "ubuntnix.fileSystems.\"${mountPoint}\": passno must be a non-negative integer" ]);

  checkSwapEntry = i: e:
    let
      label = "ubuntnix.swapDevices[${toString i}]";
      hasDevice = e ? device;
      device = e.device or "";
      options = e.options or "";
      priority = e.priority or null;
    in
    (if hasDevice && absPathOk device then [ ] else [ "${label}: device must be set to an absolute path" ])
    ++ (if builtins.isString options then [ ] else [ "${label}: options must be a string" ])
    ++ (if priority == null || builtins.isInt priority then [ ] else [ "${label}: priority must be null or an integer" ]);

  dupes = xs:
    let
      counted = builtins.foldl'
        (acc: x: acc // { ${x} = (acc.${x} or 0) + 1; })
        { }
        xs;
    in
    builtins.filter (x: counted.${x} > 1) (lib.unique xs);

  checkFileSystemDeviceDupes = fileSystems:
    let
      names = builtins.attrNames fileSystems;
      devices = map (n: fileSystems.${n}.device or null) names;
      devicesOk = builtins.filter (d: d != null) devices;
    in
    map (d: "two or more ubuntnix.fileSystems entries declare the same device \"${d}\" -- a device may be mounted at only one point") (dupes devicesOk);

  checkSwapDeviceDupes = swapDevices:
    let
      devices = builtins.filter (d: d != null) (map (e: e.device or null) swapDevices);
    in
    map (d: "two or more ubuntnix.swapDevices entries declare the same device \"${d}\"") (dupes devices);

  validate = { fileSystems ? { }, swapDevices ? [ ] }:
    let
      errors =
        (builtins.concatLists (map (mp: checkFileSystemEntry mp fileSystems.${mp}) (builtins.attrNames fileSystems)))
        ++ (checkFileSystemDeviceDupes fileSystems)
        ++ (builtins.concatLists (lib.imap0 (i: e: checkSwapEntry i e) swapDevices))
        ++ (checkSwapDeviceDupes swapDevices);
    in
    if errors == [ ]
    then { inherit fileSystems swapDevices; }
    else
      throw ''
        ubuntnix.fileSystems/ubuntnix.swapDevices failed eval-boundary validation (SPEC.md §4.3, §6; nix/filesystems.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  # -- rendering --------------------------------------------------------------

  # See header, "Rendered unit shapes" / nix/crypttab.nix's "Mount unit
  # naming": drop the leading "/", turn every remaining "/" into "-".
  escapePath = path:
    let
      rel = builtins.substring 1 (builtins.stringLength path - 1) path;
    in
    builtins.replaceStrings [ "/" ] [ "-" ] rel;

  mountUnitName = mountPoint: "${escapePath mountPoint}.mount";
  swapUnitName = device: "${escapePath device}.swap";

  # cryptDepOf "/dev/mapper/data" -> "data"; null for any other shape.
  # Duplicates nix/crypttab.nix's own mapper-name grammar verbatim -- see
  # header, "Interop with nix/crypttab.nix".
  cryptMapperNameRe = "[a-z][a-z0-9_]*";
  cryptDepOf = device:
    let
      m = builtins.match "/dev/mapper/(${cryptMapperNameRe})" device;
    in
    if m == null then null else builtins.head m;

  # Built as an explicit list of lines, not one big indented string with
  # inline conditionals: the [Unit] section's extra After=/Requires= lines
  # (crypttab-backed devices only) are each present-or-absent as a WHOLE
  # line, and building the line list in plain Nix list logic sidesteps any
  # ambiguity an indented-string `${lib.optionalString ...}` splice could
  # introduce around blank lines/indentation.
  mountUnitContent = { mountPoint, device, fsType, options, cryptMapperName }:
    let
      unitLines = [ "[Unit]" "Description=ubuntnix mount for \"${mountPoint}\" (SPEC.md §4.3 \"fstab / systemd mount units + swap\"; GitHub issue #96)" ]
        ++ lib.optionals (cryptMapperName != null) [
        "After=systemd-cryptsetup@${cryptMapperName}.service"
        "Requires=systemd-cryptsetup@${cryptMapperName}.service"
      ];
      mountLines = [
        ""
        "[Mount]"
        "What=${device}"
        "Where=${mountPoint}"
        "Type=${fsType}"
        "Options=${options}"
        ""
        "[Install]"
        "WantedBy=local-fs.target"
      ];
    in
    (builtins.concatStringsSep "\n" (unitLines ++ mountLines)) + "\n";

  swapUnitContent = { device, options, priority }:
    let
      unitLines = [
        "[Unit]"
        "Description=ubuntnix swap for \"${device}\" (SPEC.md §4.3 \"fstab / systemd mount units + swap\"; GitHub issue #96)"
        ""
        "[Swap]"
        "What=${device}"
      ]
      ++ lib.optionals (options != "") [ "Options=${options}" ]
      ++ lib.optionals (priority != null) [ "Priority=${toString priority}" ];
      installLines = [ "" "[Install]" "WantedBy=swap.target" ];
    in
    (builtins.concatStringsSep "\n" (unitLines ++ installLines)) + "\n";

  renderFileSystem = mountPoint: e:
    let
      device = e.device;
      fsType = e.fsType or "ext4";
      options = e.options or "defaults";
      dump = e.dump or 0;
      passno = e.passno or 2;
      cryptMapperName = cryptDepOf device;
      fstabLine = "${device} ${mountPoint} ${fsType} ${options} ${toString dump} ${toString passno}";
    in
    {
      inherit mountPoint device fsType options dump passno fstabLine cryptMapperName;
      mountUnitName = mountUnitName mountPoint;
      mountUnitContent = mountUnitContent { inherit mountPoint device fsType options cryptMapperName; };
    };

  renderSwap = e:
    let
      device = e.device;
      options = e.options or "";
      priority = e.priority or null;
      # fstab(5) swap options: "sw", plus "pri=<N>" when a priority is
      # set, plus any caller-supplied extra tokens -- comma-joined.
      priToken = lib.optional (priority != null) "pri=${toString priority}";
      extraTokens = lib.optional (options != "") options;
      fstabOptions = builtins.concatStringsSep "," ([ "sw" ] ++ priToken ++ extraTokens);
      fstabLine = "${device} none swap ${fstabOptions} 0 0";
    in
    {
      inherit device options priority fstabLine;
      swapUnitName = swapUnitName device;
      swapUnitContent = swapUnitContent { inherit device options priority; };
    };

  render = { fileSystems ? { }, swapDevices ? [ ] }:
    let
      validated = validate { inherit fileSystems swapDevices; };
      fsNames = builtins.attrNames validated.fileSystems;
      renderedFs = map (mp: renderFileSystem mp validated.fileSystems.${mp}) fsNames;
      renderedSwap = builtins.sort (a: b: a.device < b.device) (map renderSwap validated.swapDevices);
      allLines = (map (v: v.fstabLine) renderedFs) ++ (map (v: v.fstabLine) renderedSwap);
      fstabContent =
        if allLines == [ ]
        then ""
        else (builtins.concatStringsSep "\n" allLines) + "\n";
    in
    {
      version = 1;
      inherit fstabContent;
      fileSystems = renderedFs;
      swapDevices = renderedSwap;
    };

  renderJSON = decl: builtins.toJSON (render decl) + "\n";

  # exampleEntries -- a small, fixed DECLARATION forced through the
  # validate/render/serialize pipeline by `filesystems-manifest-proof`
  # below during ordinary flake evaluation (mirrors nix/crypttab.nix's own
  # `exampleEntries`/`crypttab-manifest-proof` role). The "data" mount
  # deliberately reuses nix/crypttab.nix's own `exampleEntries.data`
  # mapper name ("data" -> /dev/mapper/data), so this proof doubles as a
  # worked demonstration of "Interop with nix/crypttab.nix" above: a
  # LUKS-backed device referenced here renders the
  # systemd-cryptsetup@data.service After=/Requires= wiring with no
  # cross-file lookup.
  exampleEntries = {
    fileSystems = {
      "/data" = {
        device = "/dev/mapper/data";
        fsType = "ext4";
        options = "defaults";
      };
      "/srv/media" = {
        device = "/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111";
        fsType = "ext4";
        options = "defaults,noatime";
      };
    };
    swapDevices = [
      {
        device = "/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222";
        options = "discard";
        priority = 10;
      }
    ];
  };
in
{
  flake.lib.fileSystems = { inherit validate render renderJSON mountUnitName swapUnitName cryptDepOf; };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }:
    let
      inherit (config.flake.lib.stdenv) runInUbuntuBase;
    in
    {
      # filesystems-manifest-proof: forces validate/render against
      # `exampleEntries` at EVAL time -- see nix/crypttab.nix's own
      # `crypttab-manifest-proof` for why constructing this derivation is
      # enough, without a real `nix build`, to make CI's "flake" job
      # (`flake check --no-build`) exercise this file's validation/
      # rendering logic for real. A NEGATIVE proof (a bad declaration
      # actually throwing) is deliberately not wired up as a
      # `packages.*` output either, for the identical reason
      # nix/etc.nix's/nix/crypttab.nix's own headers give: `validate`
      # throws at EVALUATION time, and exposing a throwing call under
      # `packages` would poison `nix flake check` for the whole flake.
      # tests/unit/178-filesystems-flake-wiring.sh statically greps this
      # file's own code for the real `throw` instead, mirroring
      # tests/unit/175/111/041's own posture.
      packages.filesystems-manifest-proof = runInUbuntuBase {
        inherit system;
        name = "filesystems-manifest-proof";
        script = ''
          {
            echo "MARKER=ubuntnix-filesystems-manifest-proof-v1"
            cat <<'UBX_MANIFEST_EOF'
          ${renderJSON exampleEntries}
          UBX_MANIFEST_EOF
          } > "$out"
        '';
      };
    };
}
