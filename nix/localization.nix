# nix/localization.nix — the localization showcase-module trio: `i18n`,
# `console`, `time` (SPEC.md §6 configuration-surface examples:
#   i18n.locale = "en_US.UTF-8";       # -> locales debconf/gen
#   console.keymap = "us";             # -> console-setup
#   time.timeZone = "Europe/Oslo";     # -> /etc/localtime + timesyncd
# GitHub issue #97).
#
# -- What this file is, and what it deliberately is NOT ----------------------
#
# Exactly the shape nix/filesystems.nix's own header establishes for a
# showcase-module domain (read that file's header first if you haven't):
# a `validate` function (eval-boundary enforcement) and a `render` function
# (pure -- every string this file emits is built from validated,
# punctuation-light fields it already controls) exposed under
# `flake.lib.localization`, ready for a future `i18n`/`console`/`time`
# module option to call once real module evaluation exists (nix/etc.nix's
# header explains the "no modules/ tree yet" caveat this project is still
# under -- it applies verbatim here too). `perSystem.packages.
# localization-manifest-proof` (bottom) forces `validate`/`render` against
# a fixed example declaration at eval time, the same role
# `filesystems-manifest-proof` plays for nix/filesystems.nix.
#
# This file does NOT run `locale-gen`, does NOT call `dpkg-reconfigure`,
# and does NOT itself create a real `/etc/localtime` symlink on a running
# machine -- that is on-device, diff-driven planner/executor territory
# (this project's `bin/ubx-*` split), a LATER issue's job, exactly the
# "generation vs activation" line nix/crypttab.nix, nix/etc.nix,
# nix/filesystems.nix each already draw for their own domains.
#
# -- The declaration surface (SPEC.md §6) -------------------------------
#
#   i18n.locale = "en_US.UTF-8";            # required; the system default
#                                            # locale, e.g. LANG=.
#   i18n.supportedLocales = [ "en_US.UTF-8" "nb_NO.UTF-8" ];
#                                            # default [ i18n.locale ];
#                                            # every locale to be
#                                            # generated. `i18n.locale`
#                                            # MUST be a member (a default
#                                            # locale that is never
#                                            # generated cannot be set).
#   console.keymap = "us";                  # required; a console-setup
#                                            # XKB layout code.
#   time.timeZone = "Europe/Oslo";          # required; an IANA tz
#                                            # database name ("Area/City",
#                                            # or a bare "UTC").
#
# `render`'s own signature takes these three as `{ i18n ? {}; console ?
# {}; time ? {}; }` -- bare, unprefixed names, matching the SPEC example's
# own surface (these are showcase-module top-level options, NOT
# `ubuntnix.<primitive>` attributes -- unlike nix/etc.nix's/nix/
# filesystems.nix's own primitive surfaces).
#
# -- Compiling onto the upstream mechanism -------------------------------
#
# SPEC.md's own module-ecosystem philosophy: "modules compile declarations
# into upstream Ubuntu concepts... rather than bypassing them". For every
# one of the three domains here, the REAL upstream mechanism is a
# maintainer script reacting to a debconf answer -- not a file this
# project could safely fabricate by hand:
#
#   - `i18n`: the `locales` package's postinst reads
#     `locales/default_environment_locale` and
#     `locales/locales_to_be_generated` and runs `locale-gen` plus writes
#     `/etc/default/locale` itself.
#   - `console`: the `keyboard-configuration` package's postinst reads
#     `keyboard-configuration/layoutcode` (and friends) and runs
#     console-setup, writing `/etc/default/keyboard` itself.
#   - `time`: the `tzdata` package's postinst reads `tzdata/Areas` +
#     `tzdata/Zones/<Area>` and both writes `/etc/timezone` AND creates
#     the real `/etc/localtime` symlink itself -- already proven working
#     end to end by nix/compose.nix's own `compose-preseed-proof` (see
#     that file's header, "compose-preseed-proof").
#
# This file therefore renders `ubuntnix.debconf`-shaped preseed answers
# for each domain (SPEC.md §6's `ubuntnix.debconf."<pkg>" = { "<q>" =
# "<v>"; };` shape) via `config.flake.lib.compose.renderPreseed` --
# reusing nix/compose.nix's OWN preseed-flattening logic verbatim, not a
# reimplementation -- so the "pkg\tquestion\tvalue" records this file
# produces are byte-identical in shape to what nix/compose.nix's own
# `composeRootfs` already knows how to feed to `debconf-set-selections`
# and, from there, to a package's real maintainer script.
#
# `/etc/localtime` is deliberately NEVER rendered as an `ubuntnix.etc`
# entry: bin/ubx-etc-apply's activation model is copy-based ONLY (see
# that script's header, "Content source", and bin/ubx-etc's own
# `cmd_observe` comment, "bin/ubx-etc-apply's copy-based activation model
# ... never itself creates anything else under a managed path" -- i.e. no
# symlinks, ever), so the `ubuntnix.etc` primitive has no way to produce a
# real symlink today, and hand-rendering `/etc/localtime`'s binary TZif
# content here would mean vendoring `/usr/share/zoneinfo` data this file
# has no (flake-pure) access to -- worse, it would be exactly the kind of
# "bypass the upstream mechanism and hand-roll our own" this project's own
# module-ecosystem philosophy explicitly rejects. The REAL, working path
# for `/etc/localtime` is the `tzdata` debconf answers above; this file's
# render output records the intended symlink target as an informational
# `localtimeTarget` manifest field (`/usr/share/zoneinfo/<time.timeZone>`)
# for a later on-device tool to cross-check against, not as something
# rendered through the etc primitive.
#
# What genuinely IS a plain, upstream-shaped `/etc` file, and so IS
# rendered here via the `ubuntnix.etc`-shaped entries below (validated
# with `config.flake.lib.etc.validate` itself -- the exact same rules a
# real `ubuntnix.etc."<path>"` declaration is held to, so this file cannot
# silently drift from that primitive's own contract):
#
#   - `default/locale`   -- `/etc/default/locale`, `LANG="<locale>"\n`
#     (the same content the `locales` postinst itself would write; a
#     concrete, review-visible manifest entry that does not depend on
#     debconf/maintainer-script execution having happened).
#   - `default/keyboard` -- `/etc/default/keyboard`,
#     `XKBLAYOUT="<keymap>"\n` (console-setup's own file format; only the
#     layout field is populated -- model/variant/options are a richer
#     surface this issue's scope does not ask for).
#   - `timezone`         -- `/etc/timezone`, `<time.timeZone>\n` (the
#     plain-text Debian/Ubuntu convention `tzdata`'s own postinst writes
#     alongside the `/etc/localtime` symlink).
#   - `systemd/timesyncd.conf` -- `/etc/systemd/timesyncd.conf`, a `[Time]`
#     section header only, matching the minimal file real Ubuntu itself
#     ships by default (systemd-timesyncd needs no timezone-specific
#     configuration to function -- it always operates in UTC -- so this is
#     the "timesyncd" artifact `time.timeZone` compiles to: proof the unit
#     is present/configured, not a place timezone-specific keys get
#     written).
#
# Every one of these `ubuntnix.etc`-shaped entries is rendered as a
# self-contained manifest record here (`path`, `text`, `sha256`, `owner`,
# `group`, `mode`) rather than by invoking nix/etc.nix's own `render`
# (which builds a real derivation via `runInUbuntuBase`): this mirrors
# nix/filesystems.nix's own choice to stay a pure, JSON-serializable
# manifest (see that file's header) rather than a derivation-producing
# function, which is what keeps this file's `render` cheaply exercisable
# by `tests/unit/181-localization-render-fixtures.sh`'s pure-fixture
# style (no `nix` binary needed -- see that test's own header) the same
# way `tests/unit/179-filesystems-render-fixtures.sh` already is for
# nix/filesystems.nix.
#
# -- Eval-boundary validation (`validate`) -------------------------------
#
# Every violation across the whole declaration is collected into one
# `throw` (never just the first -- same posture as every sibling showcase
# module's own `validate`):
#   - `i18n.locale` must be a non-empty string matching a locale-name
#     shape (`localeRe` below);
#   - `i18n.supportedLocales` must be a list of strings, each matching the
#     same shape, and must CONTAIN `i18n.locale` (a default locale that is
#     never generated is a contradiction `locale-gen` itself would refuse
#     to honor usefully);
#   - `console.keymap` must be a non-empty string matching a keymap-code
#     shape (`keymapRe` below);
#   - `time.timeZone` must be a non-empty string matching an IANA
#     tz-name shape (`tzRe` below: `Area/City[/City...]`, or a bare
#     top-level zone like `"UTC"`).
#
# -- Rendering (`render`) -------------------------------------------------
#
# `render { i18n; console; time; }` first calls `validate`, then builds:
#   - `debconf`, the raw `ubuntnix.debconf`-shaped attrset (three
#     packages: `locales`, `keyboard-configuration`, `tzdata`);
#   - `debconfSelections`, `debconf` flattened via
#     `config.flake.lib.compose.renderPreseed` (see "Compiling onto the
#     upstream mechanism" above);
#   - `etc`, a sorted-by-path list of the four rendered file entries
#     described above.
#
# The returned manifest (JSON-ready, mirroring nix/filesystems.nix's own
# `render` return shape):
#
#   { "version": 1,
#     "i18n": { "locale", "supportedLocales" },
#     "console": { "keymap" },
#     "time": { "timeZone", "area", "zone", "localtimeTarget" },
#     "debconf": { "<pkg>": { "<question>": "<value>" } },
#     "debconfSelections": "<pkg>\t<question>\t<value>\n... (renderPreseed
#                           output)",
#     "etc": [ { "path", "text", "sha256", "owner", "group", "mode" },
#              ... sorted by path ]
#   }
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  inherit (config.flake.lib.compose) renderPreseed;
  inherit (config.flake.lib.etc) validate;
  inherit (config.flake.lib.stdenv) runInUbuntuBase;

  # -- validation ------------------------------------------------------------

  localeRe = "[A-Za-z_]+(\\.[A-Za-z0-9-]+)?";
  localeOk = s: builtins.isString s && s != "" && builtins.match localeRe s != null;

  keymapRe = "[a-z][a-z0-9-]*";
  keymapOk = s: builtins.isString s && s != "" && builtins.match keymapRe s != null;

  tzRe = "[A-Za-z_+-]+(/[A-Za-z0-9_+-]+)*";
  tzOk = s: builtins.isString s && s != "" && builtins.match tzRe s != null;

  checkI18n = i18n:
    let
      hasLocale = i18n ? locale;
      locale = i18n.locale or "";
      hasSupported = i18n ? supportedLocales;
      supportedLocales = i18n.supportedLocales or [ locale ];
      supportedIsList = builtins.isList supportedLocales;
    in
    (if hasLocale && localeOk locale then [ ] else [ "i18n.locale must be set to a non-empty locale name (e.g. \"en_US.UTF-8\")" ])
    ++ (if !hasSupported || supportedIsList then [ ] else [ "i18n.supportedLocales must be a list of strings" ])
    ++ (
      if supportedIsList
      then builtins.concatMap (l: if localeOk l then [ ] else [ "i18n.supportedLocales: \"${toString l}\" is not a valid locale name" ]) supportedLocales
      else [ ]
    )
    ++ (if hasLocale && supportedIsList && localeOk locale && !(builtins.elem locale supportedLocales)
    then [ "i18n.supportedLocales must contain i18n.locale (\"${locale}\") -- a default locale that is never generated cannot be honored" ]
    else [ ]);

  checkConsole = console:
    let
      hasKeymap = console ? keymap;
      keymap = console.keymap or "";
    in
    if hasKeymap && keymapOk keymap then [ ] else [ "console.keymap must be set to a non-empty keymap code (e.g. \"us\")" ];

  checkTime = time:
    let
      hasTz = time ? timeZone;
      timeZone = time.timeZone or "";
    in
    if hasTz && tzOk timeZone then [ ] else [ "time.timeZone must be set to a non-empty IANA time zone name (e.g. \"Europe/Oslo\" or \"UTC\")" ];

  validateDecl = { i18n ? { }, console ? { }, time ? { } }:
    let
      errors = checkI18n i18n ++ checkConsole console ++ checkTime time;
    in
    if errors == [ ]
    then { inherit i18n console time; }
    else
      throw ''
        i18n/console/time failed eval-boundary validation (SPEC.md §6; nix/localization.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}'';

  # -- rendering --------------------------------------------------------------

  # "Europe/Oslo" -> { area = "Europe"; zone = "Oslo"; };
  # "America/Argentina/Buenos_Aires" -> { area = "America"; zone =
  # "Argentina/Buenos_Aires"; } (tzdata's own `Zones/<Area>` debconf
  # template value for a nested zone is the remainder of the path, exactly
  # as it appears under /usr/share/zoneinfo/<Area>/);
  # "UTC" -> { area = "Etc"; zone = "UTC"; } (tzdata's own convention: a
  # bare top-level zone name lives under the "Etc" continent bucket).
  splitTz = timeZone:
    let
      parts = lib.splitString "/" timeZone;
    in
    if builtins.length parts == 1
    then { area = "Etc"; zone = timeZone; }
    else { area = builtins.head parts; zone = builtins.concatStringsSep "/" (builtins.tail parts); };

  # locale "en_US.UTF-8" -> "en_US.UTF-8 UTF-8" (debconf's own
  # locales/locales_to_be_generated multiselect entry shape: "<locale>
  # <charset>", charset taken from the locale's own suffix, defaulting to
  # "UTF-8" when the locale carries none, e.g. a bare "C").
  localeGenEntry = locale:
    let
      parts = lib.splitString "." locale;
      charset = if builtins.length parts > 1 then builtins.concatStringsSep "." (builtins.tail parts) else "UTF-8";
    in
    "${locale} ${charset}";

  renderDeclaration = { i18n, console, time }:
    let
      locale = i18n.locale;
      supportedLocales = i18n.supportedLocales or [ locale ];
      keymap = console.keymap;
      timeZone = time.timeZone;
      tz = splitTz timeZone;

      debconf = {
        locales = {
          "locales/default_environment_locale" = locale;
          "locales/locales_to_be_generated" = builtins.concatStringsSep ", " (map localeGenEntry supportedLocales);
        };
        keyboard-configuration = {
          "keyboard-configuration/layoutcode" = keymap;
        };
        tzdata = {
          "tzdata/Areas" = tz.area;
          "tzdata/Zones/${tz.area}" = tz.zone;
        };
      };

      etcEntries = {
        "default/locale" = {
          text = "LANG=\"${locale}\"\n";
        };
        "default/keyboard" = {
          text = "XKBLAYOUT=\"${keymap}\"\n";
        };
        "timezone" = {
          text = "${timeZone}\n";
        };
        "systemd/timesyncd.conf" = {
          text = "[Time]\n";
        };
      };
      # Run every entry through the REAL ubuntnix.etc primitive's own
      # validate -- see header, "What genuinely IS a plain, upstream-
      # shaped /etc file". `validate` just returns its input unchanged
      # when it does not throw, so this is purely a cross-check.
      validatedEtcEntries = validate etcEntries;

      renderEtcEntry = path: e: {
        inherit path;
        text = e.text;
        sha256 = builtins.hashString "sha256" e.text;
        owner = "root";
        group = "root";
        mode = "0644";
      };
      etc = map (path: renderEtcEntry path validatedEtcEntries.${path}) (builtins.attrNames validatedEtcEntries);
    in
    {
      version = 1;
      i18n = { inherit locale supportedLocales; };
      console = { inherit keymap; };
      time = { inherit timeZone; inherit (tz) area zone; localtimeTarget = "/usr/share/zoneinfo/${timeZone}"; };
      inherit debconf;
      debconfSelections = renderPreseed debconf;
      inherit etc;
    };

  render = decl: renderDeclaration (validateDecl decl);

  renderJSON = decl: builtins.toJSON (render decl) + "\n";

  # exampleDeclaration -- a small, fixed DECLARATION forced through the
  # validate/render/serialize pipeline by `localization-manifest-proof`
  # below during ordinary flake evaluation (mirrors nix/filesystems.nix's
  # own `exampleEntries`/`filesystems-manifest-proof` role).
  exampleDeclaration = {
    i18n = {
      locale = "en_US.UTF-8";
      supportedLocales = [ "en_US.UTF-8" "nb_NO.UTF-8" ];
    };
    console = {
      keymap = "us";
    };
    time = {
      timeZone = "Europe/Oslo";
    };
  };
in
{
  flake.lib.localization = { inherit validateDecl render renderJSON splitTz localeGenEntry; };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }: {
    # localization-manifest-proof: forces validate/render against
    # `exampleDeclaration` at EVAL time -- see nix/filesystems.nix's own
    # `filesystems-manifest-proof` for why constructing this derivation is
    # enough, without a real `nix build`, to make CI's "flake" job
    # (`flake check --no-build`) exercise this file's validation/
    # rendering logic for real. A NEGATIVE proof (a bad declaration
    # actually throwing) is deliberately not wired up as a `packages.*`
    # output either, for the identical reason nix/etc.nix's/
    # nix/filesystems.nix's own headers give: `validate` throws at
    # EVALUATION time, and exposing a throwing call under `packages` would
    # poison `nix flake check` for the whole flake.
    # tests/unit/180-localization-flake-wiring.sh statically greps this
    # file's own code for the real `throw` instead, mirroring
    # tests/unit/178's own posture.
    packages.localization-manifest-proof = runInUbuntuBase {
      inherit system;
      name = "localization-manifest-proof";
      script = ''
        {
          echo "MARKER=ubuntnix-localization-manifest-proof-v1"
          cat <<'UBX_MANIFEST_EOF'
        ${renderJSON exampleDeclaration}
        UBX_MANIFEST_EOF
        } > "$out"
      '';
    };
  };
}
