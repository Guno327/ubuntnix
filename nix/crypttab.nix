# nix/crypttab.nix — the passphrase-LUKS GROUNDWORK primitive: declaration
# surface + eval-time validation + rendering to a `/etc/crypttab` entry plus
# its corresponding systemd `.mount` unit (SPEC.md §11 M4 "passphrase-LUKS
# groundwork (crypttab/fileSystems)", §4.2 "generated /etc"; GitHub issue
# #83, milestone M4).
#
# -- Scope: mechanism only, no installer integration ------------------------
#
# This is groundwork, not the guided-install LUKS flow (SPEC.md §11 lists
# that separately, under M7 "the full install flow"). This file — plus its
# planner (bin/ubx-crypttab) and executor (bin/ubx-crypttab-apply) — builds
# ONLY the generation + activation mechanism: given a declared LUKS volume
# (backing device, mapper name, options, optional mount point), compile it
# to a correct `/etc/crypttab` entry and the matching mount unit so the
# decrypted mapper device can actually be mounted. Nothing here decides
# WHICH real disk to encrypt, prompts for a passphrase, or runs
# `cryptsetup luksFormat` — that is entirely M7's job, exactly the same
# "generation vs activation, eval vs on-device" split nix/pro.nix,
# nix/etc.nix, nix/secrets.nix each already draw for their own domains (see
# those files' own headers).
#
# -- The declaration surface -------------------------------------------------
#
#   ubuntnix.crypttab."data" = {
#     device = "/dev/disk/by-uuid/1234-5678-9abc-def0";  # required; the
#                                     # backing device crypttab(5) col 2 --
#                                     # a UUID/by-id/by-partuuid path is
#                                     # strongly preferred over a raw
#                                     # /dev/sdXN (SPEC.md's own storage
#                                     # posture: device NODE NAMES are not
#                                     # stable across boots), but this file
#                                     # does not itself enforce that choice
#                                     # -- only that the string is an
#                                     # absolute path.
#     keyFile = "none";               # default "none" (crypttab(5): prompt
#                                     # for a passphrase at boot -- the ONLY
#                                     # mode this issue's "passphrase LUKS"
#                                     # scope covers; a real keyfile-backed
#                                     # volume is a different, not-yet-
#                                     # declared feature). "-" is also
#                                     # accepted (crypttab(5) treats it as a
#                                     # synonym for "none" in the presence of
#                                     # options); a real keyfile PATH is
#                                     # rejected -- see "Why keyFile is
#                                     # restricted to none/-" below.
#     options = "luks,discard";       # default "" (crypttab(5) col 4);
#                                     # opaque, passed through verbatim.
#     mountPoint = "/mnt/data";       # optional; when set, a systemd
#                                     # `.mount` unit is ALSO rendered,
#                                     # wired to wait on the mapper device
#                                     # systemd's own cryptsetup generator
#                                     # creates from this crypttab entry.
#     fsType = "ext4";                # default "ext4"; only consulted when
#                                     # mountPoint is set.
#     mountOptions = "defaults";      # default "defaults"; only consulted
#                                     # when mountPoint is set.
#   };
#
# The attribute name ("data" above) is the crypttab mapper name --
# crypttab(5) column 1, and (per systemd-cryptsetup-generator(8)) also the
# instance name of the `systemd-cryptsetup@<name>.service` unit systemd
# synthesizes from this entry at boot. `entries` throughout this file is
# exactly that attrset.
#
# -- Why keyFile is restricted to none/- (not an arbitrary path) ------------
#
# SPEC.md's "Full-disk encryption: passphrase LUKS in v1" (§ "Full-disk
# encryption") names passphrase-at-boot as the ENTIRE v1 scope; a
# keyfile-backed volume is a materially different secret-handling story
# (the keyfile's own bytes would need this project's secrets primitive,
# nix/secrets.nix, wired in as a THIRD consumer alongside password-hash/Pro
# token consumption -- SPEC.md §8.1's "no secret material ever enters a
# store object" would apply to it exactly as it does there) that this issue
# does not ask for and that adding here would be scope creep past
# "passphrase-LUKS groundwork". Restricting `keyFile` to the two crypttab(5)
# spellings that both mean "prompt at boot" keeps this file's declaration
# surface honest about what it actually supports today; a real keyfile mode
# is a natural, additive extension for a LATER issue once that secrets
# question is worked out on its own.
#
# -- Mapper-name character restriction: no "-" --------------------------------
#
# systemd's unit-name escaping (systemd-escape(1)) maps a literal "-" in an
# escaped string to the four-character sequence "\x2d" (because "-" is
# itself the escape-output's own path-separator stand-in, exactly the
# nix/boot.nix precedent this file's "Mount unit naming" section below
# leans on for `.mount` units). A crypttab mapper name containing "-" would
# therefore make `systemd-cryptsetup@<name>.service`'s real instance name
# NOT equal the mapper name written verbatim -- silently breaking the
# `Requires=`/`After=` wiring below unless this file also implemented
# systemd's full escaping algorithm. Restricting declared names to
# `[a-z][a-z0-9_]*` (no "-") sidesteps that whole class of bug for this
# groundwork issue's scope; teaching this file real systemd-escape semantics
# for arbitrary mapper names is left for whenever a real declaration
# actually needs a "-" in one.
#
# -- Rendering --------------------------------------------------------------
#
# `render entries` first calls `validate entries`, then for every volume,
# in sorted-by-name order (`builtins.attrNames`, exactly nix/etc.nix's own
# "deterministic ordering for free" reasoning):
#   - composes its crypttab(5) line (`<name> <device> <keyFile>[ <options>]`
#     -- the 4th field is omitted entirely, not left blank, when `options`
#     is ""; crypttab(5) treats a truly absent 4th field and an empty one
#     identically, so this keeps a no-options entry's rendered line
#     unsurprising to a human reading `/etc/crypttab` by eye);
#   - when `mountPoint` is set, composes the matching `.mount` unit's
#     filename (see "Mount unit naming") and full unit text (see "Mount
#     unit content").
#
# The returned manifest is a plain attrset (JSON-ready, mirroring
# nix/pro.nix's `renderManifestJSON` split of "build the attrset in Nix,
# serialize with builtins.toJSON, done" — there is no store object to build
# here at all: unlike nix/etc.nix's arbitrary user-declared `text` bytes,
# every string this file emits is built from validated, punctuation-light
# fields it already fully controls, so there is no heredoc-collision risk
# to design around):
#
#   { "version": 1,
#     "crypttabContent": "<all lines, sorted, joined with \"\\n\", trailing \"\\n\">",
#     "volumes": [
#       { "name", "device", "keyFile", "options",
#         "crypttabLine",
#         "mountPoint": <string, or null>,
#         "fsType": <string, or null>,
#         "mountOptions": <string, or null>,
#         "mountUnitName": <string, or null>,      -- null iff mountPoint is null
#         "mountUnitContent": <string, or null> },  -- null iff mountPoint is null
#       ... ]
#   }
#
# bin/ubx-crypttab (the planner) and bin/ubx-crypttab-apply (the executor)
# are the on-device, diff-driven/root-privileged halves that consume this --
# this file never touches a real `/etc/crypttab` or a real mount unit
# directory, exactly nix/etc.nix's own "generation vs activation" split.
#
# -- Mount unit naming --------------------------------------------------------
#
# Follows nix/boot.nix's own documented rule verbatim (see that file's
# `writeUnitLines`, ~line 350: "systemd REQUIRES a .mount unit's filename to
# equal the escaped form of its Where= path"): drop the leading "/", turn
# every remaining "/" into "-", append ".mount". Exactly nix/boot.nix's own
# scheme, with the identical, already-documented limitation carried over
# unchanged: a `mountPoint` whose OWN path segments contain a literal "-"
# is not specially escaped (systemd would collide it with a real "/"), the
# same simplification nix/boot.nix's own comment accepts for its "/tmp"/
# "/home" writable-state mounts. `mountPoint` is validated to rule out the
# traversal-style cases `pathOk` below already guards nix/etc.nix's own
# `ubuntnix.etc` paths against; "-" is deliberately NOT rejected there
# (unlike in mapper names above) since a real system's real mount points
# legitimately contain one (e.g. "/mnt/backup-data") -- this is a narrower,
# documented gap, not a validation hole.
#
# -- Mount unit content --------------------------------------------------
#
# [Unit]
# Description=ubuntnix LUKS-backed mount for "<name>" (SPEC.md's "Full-disk
# encryption"; crypttab groundwork, issue #83, M4)
# After=systemd-cryptsetup@<name>.service
# Requires=systemd-cryptsetup@<name>.service
#
# [Mount]
# What=/dev/mapper/<name>
# Where=<mountPoint>
# Type=<fsType>
# Options=<mountOptions>
#
# [Install]
# WantedBy=local-fs.target
#
# `systemd-cryptsetup@<name>.service` is not declared or rendered by this
# file at all -- systemd's own systemd-cryptsetup-generator(8) synthesizes
# it automatically from a real `/etc/crypttab`'s entries at boot (this is
# exactly why `/etc/crypttab` is the mechanism worth building here: the
# decrypt unit comes for free from a correct crypttab entry, and this
# file's own job reduces to naming it correctly in `Requires=`/`After=` so
# the generated mount unit waits for it). `<name>` in that unit name is
# used LITERALLY (never escaped) — see "Mapper-name character restriction"
# above for why that is safe for every name this file's own `validate`
# accepts.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  # -- validation ------------------------------------------------------------
  #
  # Mapper name: no "-" -- see header, "Mapper-name character restriction".
  nameRe = "[a-z][a-z0-9_]*";
  nameOk = s: builtins.isString s && builtins.match nameRe s != null;

  # Absolute path, no empty/"."/".." segment -- mirrors nix/etc.nix's own
  # `pathOk`/`segmentOk`, except segments here MAY contain "-" (see header,
  # "Mount unit naming", for why that's a deliberate, narrower carve-out
  # than nix/etc.nix's own path rule) and the path itself is expected
  # ABSOLUTE (an `/etc`-relative path makes no sense for a mount point),
  # unlike nix/etc.nix's own relative-only rule.
  segmentOk = seg: seg != "" && seg != "." && seg != ".." && builtins.match "[A-Za-z0-9._-]+" seg != null;
  absPathOk = path:
    builtins.isString path
    && path != ""
    && builtins.substring 0 1 path == "/"
    && path != "/"
    && builtins.all segmentOk (lib.splitString "/" (builtins.substring 1 (builtins.stringLength path - 1) path));

  keyFileOk = s: s == "none" || s == "-";

  checkVolume = name: v:
    let
      hasDevice = v ? device;
      device = v.device or "";
      keyFile = v.keyFile or "none";
      options = v.options or "";
      hasMount = v ? mountPoint && v.mountPoint != null;
      mountPoint = v.mountPoint or null;
      fsType = v.fsType or "ext4";
      mountOptions = v.mountOptions or "defaults";
    in
    (if nameOk name then [ ] else [ "ubuntnix.crypttab.\"${toString name}\": mapper name must match ${nameRe} (no '-'; see nix/crypttab.nix header, 'Mapper-name character restriction')" ])
    ++ (if hasDevice && builtins.isString device && device != "" && builtins.substring 0 1 device == "/"
    then [ ] else [ "ubuntnix.crypttab.\"${name}\": device must be set to an absolute path (e.g. /dev/disk/by-uuid/...)" ])
    ++ (if keyFileOk keyFile then [ ] else [ "ubuntnix.crypttab.\"${name}\": keyFile must be \"none\" or \"-\" (passphrase-at-boot only; see header, 'Why keyFile is restricted to none/-')" ])
    ++ (if builtins.isString options then [ ] else [ "ubuntnix.crypttab.\"${name}\": options must be a string" ])
    ++ (if !hasMount then [ ]
    else if absPathOk mountPoint then [ ] else [ "ubuntnix.crypttab.\"${name}\": mountPoint must be an absolute path with no empty/'.'/'..' segment" ])
    ++ (if builtins.isString fsType && fsType != "" then [ ] else [ "ubuntnix.crypttab.\"${name}\": fsType must be a non-empty string" ])
    ++ (if builtins.isString mountOptions then [ ] else [ "ubuntnix.crypttab.\"${name}\": mountOptions must be a string" ]);

  validate = entries:
    let
      errors = builtins.concatLists (map (name: checkVolume name entries.${name}) (builtins.attrNames entries));
    in
    if errors == [ ]
    then entries
    else
      throw ''
        ubuntnix.crypttab failed eval-boundary validation (SPEC.md §11 M4, §4.2; nix/crypttab.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  # -- rendering --------------------------------------------------------------

  mountUnitName = mountPoint:
    let
      rel = builtins.substring 1 (builtins.stringLength mountPoint - 1) mountPoint;
      escaped = builtins.replaceStrings [ "/" ] [ "-" ] rel;
    in
    "${escaped}.mount";

  mountUnitContent = { name, mountPoint, fsType, mountOptions }: ''
    [Unit]
    Description=ubuntnix LUKS-backed mount for "${name}" (SPEC.md's "Full-disk encryption"; crypttab groundwork, issue #83, M4)
    After=systemd-cryptsetup@${name}.service
    Requires=systemd-cryptsetup@${name}.service

    [Mount]
    What=/dev/mapper/${name}
    Where=${mountPoint}
    Type=${fsType}
    Options=${mountOptions}

    [Install]
    WantedBy=local-fs.target
  '';

  renderVolume = name: v:
    let
      device = v.device;
      keyFile = v.keyFile or "none";
      options = v.options or "";
      hasMount = v ? mountPoint && v.mountPoint != null;
      mountPoint = v.mountPoint or null;
      fsType = v.fsType or "ext4";
      mountOptions = v.mountOptions or "defaults";

      # crypttab(5): "<name> <device> <keyfile> <options>" -- the 4th
      # field is OMITTED (not left blank) when there are no options; see
      # header, "Rendering".
      crypttabLine =
        if options == ""
        then "${name} ${device} ${keyFile}"
        else "${name} ${device} ${keyFile} ${options}";
    in
    {
      inherit name device keyFile options crypttabLine;
      mountPoint = if hasMount then mountPoint else null;
      fsType = if hasMount then fsType else null;
      mountOptions = if hasMount then mountOptions else null;
      mountUnitName = if hasMount then mountUnitName mountPoint else null;
      mountUnitContent = if hasMount then mountUnitContent { inherit name mountPoint fsType mountOptions; } else null;
    };

  render = entries:
    let
      validated = validate entries;
      names = builtins.attrNames validated;
      volumes = map (name: renderVolume name validated.${name}) names;
      crypttabContent =
        if volumes == [ ]
        then ""
        else (builtins.concatStringsSep "\n" (map (v: v.crypttabLine) volumes)) + "\n";
    in
    {
      version = 1;
      inherit crypttabContent;
      volumes = map
        (v: {
          inherit (v) name device keyFile options crypttabLine mountPoint fsType mountOptions mountUnitName mountUnitContent;
        })
        volumes;
    };

  renderJSON = entries: builtins.toJSON (render entries) + "\n";

  # exampleEntries -- a small, fixed DECLARATION (raw entries, pre-render)
  # forced through the validate/render/serialize pipeline by `crypttab-
  # manifest-proof` below during ordinary flake evaluation -- mirrors
  # nix/pro.nix's own `exampleManifest` role. NB: unlike pro.nix (where
  # mkManifest renders and renderManifestJSON only serializes), here
  # `renderJSON` itself renders its ENTRIES argument, so the example must be
  # the raw entries, never an already-rendered manifest (feeding a rendered
  # manifest back into renderJSON would double-render and throw).
  exampleEntries = {
    data = {
      device = "/dev/disk/by-uuid/00000000-0000-0000-0000-000000000000";
      keyFile = "none";
      options = "luks,discard";
      mountPoint = "/mnt/data";
      fsType = "ext4";
      mountOptions = "defaults";
    };
  };
in
{
  flake.lib.crypttab = { inherit validate render renderJSON mountUnitName; };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }:
    let
      inherit (config.flake.lib.stdenv) runInUbuntuBase;
    in
    {
      # crypttab-manifest-proof: forces validate/render against
      # `exampleEntries` at EVAL time -- see nix/pro.nix's own
      # `pro-manifest-proof` for why constructing this derivation is
      # enough, without a real `nix build`, to make CI's "flake" job
      # (`flake check --no-build`) exercise this file's validation/
      # rendering logic for real. A NEGATIVE proof (a bad declaration
      # actually throwing) is deliberately not wired up as a
      # `packages.*` output either, for the identical reason
      # nix/etc.nix's own header gives: `validate` throws at EVALUATION
      # time, and exposing a throwing call under `packages` would poison
      # `nix flake check` for the whole flake. tests/unit/175-crypttab-
      # flake-wiring.sh statically greps this file's own code for the
      # real `throw` instead, mirroring tests/unit/111/041's own posture.
      packages.crypttab-manifest-proof = runInUbuntuBase {
        inherit system;
        name = "crypttab-manifest-proof";
        script = ''
          {
            echo "MARKER=ubuntnix-crypttab-manifest-proof-v1"
            cat <<'UBX_MANIFEST_EOF'
          ${renderJSON exampleEntries}
          UBX_MANIFEST_EOF
          } > "$out"
        '';
      };
    };
}
