# nix/installer.nix — the installer answers→config COMPILER (SPEC.md §10
# "Parity principle: ... compiles the user's answers into config: storage
# -> fileSystems, identity -> a user with its password hash written into
# the secrets index, locale/keyboard/timezone -> the corresponding
# modules, desktop-vs-server -> profiles.*, and the third-party-software
# checkbox -> the restricted+multiverse per-machine toggle"; GitHub issue
# #113).
#
# -- What this file is, and what it deliberately is NOT ----------------------
#
# Exactly nix/localization.nix's own two-function shape (read that file's
# header first if you haven't): a `validateAnswers` function (eval-boundary
# enforcement over the STRUCTURED installer-answers attrset this file
# defines below) and a `compileAnswers` function (pure -- every field of
# the config attrset it returns is built straight from validated,
# already-typed answer fields; `compileAnswers` calls `validateAnswers`
# itself, so callers never need to call it separately first) exposed under
# `flake.lib.installer`. `perSystem.packages.installer-compiler-proof`
# (bottom) forces `compileAnswers` against three fixed example answer sets
# at eval time, the same role `localization-manifest-proof` plays for
# nix/localization.nix.
#
# This file does NOT touch an ISO, does NOT run subiquity, does NOT prompt
# a user, does NOT write `/flake` on a real machine, and does NOT itself
# validate/render through any downstream base module (networking,
# fileSystems, localization, users, crypttab, profiles) -- it only ever
# BUILDS the plain attrset those modules' own `validate`/`render` functions
# are the real authority on, exactly the same "generation vs activation"
# and "compile onto the upstream primitive, never reimplement its
# validation" lines every sibling nix/*.nix file already draws for its own
# domain. A real installer step 2 ("writes the initial generation, built
# from the parity example config matching the user's choices", SPEC.md
# §10) is expected to feed `compileAnswers`'s return value through those
# modules exactly the way nix/profiles.nix's own `perSystem` block already
# does for `examples/server.nix`/`examples/desktop.nix` -- see
# tests/unit/202-installer-roundtrip-validate.sh, which proves this file's
# compiled output is ACTUALLY acceptable to every one of those modules'
# own validation grammar, not merely shaped like it.
#
# -- The declaration surface: structured installer answers ------------------
#
#   ubuntnix.installer.answers = {
#     storage = {
#       mode = "guided";                  # required; one of "guided",
#                                          # "lvm", "luks", "manual" --
#                                          # subiquity's own storage flows
#                                          # (SPEC.md §10: "the installer
#                                          # reuses upstream machinery ...
#                                          # inheriting its storage flows:
#                                          # guided, LVM, LUKS once M5
#                                          # lands, manual").
#       device = "/dev/disk/by-uuid/...";  # required; absolute path -- the
#                                          # backing device for the primary
#                                          # data filesystem. For
#                                          # mode == "luks" this is the
#                                          # ENCRYPTED physical device (the
#                                          # crypttab entry's own `device`);
#                                          # every other mode, it is mounted
#                                          # directly.
#       mountPoint = "/data";             # default "/data".
#       fsType = "ext4";                  # default "ext4".
#       options = "defaults";             # default "defaults".
#       swapDevice = null;                # default null (no swap);
#                                          # otherwise an absolute path.
#       swapOptions = "";                 # default "".
#       luksName = "data";                # required, only when
#                                          # mode == "luks" -- the crypttab
#                                          # mapper name (nix/crypttab.nix's
#                                          # own mapper-name grammar).
#       luksOptions = "luks,discard";     # default "luks,discard"; only
#                                          # consulted when mode == "luks".
#     };
#     identity = {
#       username = "gunnar";              # required.
#       groups = [ "sudo" ];              # default [ "sudo" ].
#       authorizedKeys = [ "ssh-ed25519 ..." ];  # default [ ].
#       hashedPasswordSecret = null;      # default null; otherwise the
#                                          # NAME of a secret already
#                                          # declared in `secrets/index.nix`
#                                          # (nix/users.nix's own
#                                          # `hashedPasswordSecret` field,
#                                          # SPEC.md §10: "identity -> a
#                                          # user with its password hash
#                                          # written into the secrets
#                                          # index").
#     };
#     locale = "en_US.UTF-8";             # default "en_US.UTF-8".
#     keyboard = "us";                    # default "us".
#     timezone = "UTC";                   # default "UTC".
#     desktop = false;                    # required bool -- true compiles
#                                          # `profiles.desktop.enable`,
#                                          # false compiles
#                                          # `profiles.server.enable`
#                                          # (SPEC.md §10:
#                                          # "desktop-vs-server ->
#                                          # profiles.*" -- always exactly
#                                          # one of the two, never both).
#     thirdParty = false;                 # default false -- the
#                                          # installer's third-party-
#                                          # software checkbox (SPEC.md §5,
#                                          # §10: "the third-party-software
#                                          # checkbox -> the
#                                          # restricted+multiverse
#                                          # per-machine toggle").
#     networking = {
#       hostname = "myhost";              # required.
#       interface = "eth0";               # default "eth0".
#       dhcp = true;                      # default true.
#     };
#   };
#
# -- The mapping (SPEC.md §10), field by field -------------------------------
#
#   storage       -> fileSystems.<mountPoint> / swapDevices (device, fsType,
#                     options carried straight through); mode == "luks"
#                     ADDITIONALLY compiles a `crypttab.<luksName>` entry
#                     (nix/crypttab.nix's own declaration surface) and
#                     routes the mounted `device` through the mapper path
#                     `/dev/mapper/<luksName>` (exactly the "Interop with
#                     nix/crypttab.nix" shape nix/filesystems.nix's own
#                     header documents) -- guided/LVM/manual all compile
#                     identically, straight to `fileSystems`, since none of
#                     them need a crypttab entry.
#   identity      -> users.<username> = { groups; authorizedKeys;
#                     hashedPasswordSecret; } (nix/users.nix's own
#                     declaration surface; `hashedPasswordSecret` is a
#                     REFERENCE only, never a value -- see that file's
#                     header, "hashedPasswordSecret: a reference, never a
#                     value" -- this file inherits that invariant for free
#                     by never doing anything with the field but copying
#                     the string through).
#   locale/keyboard/timezone -> i18n.locale / console.keymap / time.timeZone
#                     (nix/localization.nix's own declaration surface).
#   desktop       -> profiles.desktop.enable = true (desktop == true) XOR
#                     profiles.server.enable = true (desktop == false) --
#                     never both, and the OFF profile is left entirely
#                     unset (not `= false`) to match
#                     examples/server.nix's/examples/desktop.nix's own
#                     shape exactly (neither example config declares the
#                     profile it isn't using at all).
#   thirdParty    -> archive.components = { restricted = true;
#                     multiverse = true; } (nix/archive.nix's own
#                     `ubuntnix.archive.components` toggle, SPEC.md §5)
#                     ONLY when true. When false, the field is omitted
#                     entirely rather than compiled as `{ restricted =
#                     false; multiverse = false; }`: nix/archive.nix's own
#                     `componentToggleType` already defaults both to
#                     `false`, so an all-false toggle and an absent one are
#                     semantically identical, and omitting it keeps a
#                     "stock, no third-party" compiled config
#                     structurally IDENTICAL to examples/server.nix /
#                     examples/desktop.nix (neither example declares this
#                     field either) -- see
#                     tests/unit/203-installer-structural-equality-examples.sh.
#   networking    -> networking.hostname / networking.hosts (always `{ }`
#                     -- the installer's own guided flow asks for a
#                     hostname, never extra /etc/hosts aliases; a real user
#                     wanting those edits the generated config by hand
#                     afterward, exactly like nix/profiles.nix's own
#                     parity-image posture already assumes for every other
#                     "the installer produces a reasonable starting point,
#                     not the final word" field here) / networking.
#                     interfaces.<interface>.dhcp4 (nix/networking.nix's
#                     own declaration surface; DHCP only -- subiquity's own
#                     guided flow defaults to DHCP, and a static-IP
#                     interface is a manual post-install edit, out of this
#                     issue's scope).
#   server cloud-init -> deliberately NOT compiled here at all. SPEC.md
#                     §10: "Server installs keep cloud-init, as upstream
#                     does" / §12 R12: "ship present-but-inert". This is
#                     ALREADY exactly what `profiles.server.enable = true`
#                     compiles to -- nix/profiles.nix's own `render`
#                     unconditionally renders the
#                     `/etc/cloud/cloud-init.disabled` present-but-inert
#                     marker (see that file's header, "cloud-init:
#                     present-but-inert (SPEC.md §12 R12)") whenever
#                     `enable = true`, with no separate declaration surface
#                     of its own for this file to compile answers into.
#                     `compileAnswers` therefore represents "server keeps
#                     cloud-init present-but-inert" faithfully by the mere
#                     act of compiling `profiles.server.enable = true` for
#                     every non-desktop answer set -- adding a parallel
#                     cloud-init field here would be a second, redundant
#                     source of truth nix/profiles.nix does not read.
#
# -- Eval-boundary validation (`validateAnswers`) ----------------------------
#
# Every violation across the whole declared answers attrset is collected
# into one `throw` (never just the first -- same posture as every sibling
# showcase module's own `validate`/`validateDecl`). Grammars reused here
# are duplicated VERBATIM from their owning domain file rather than
# imported (mirrors nix/users.nix's own `secretNameRe` duplication note,
# "Cross-referencing a REAL declared secret": this file has no access to
# those files' internal, unexported regex bindings, only their exposed
# `flake.lib.<domain>` functions -- and duplicating a short regex string is
# the same tradeoff every sibling file already accepts elsewhere in this
# tree):
#   - `storage.mode` must be one of "guided"/"lvm"/"luks"/"manual";
#   - `storage.device` must be a non-empty absolute path;
#   - `storage.mountPoint`/`storage.swapDevice` (when set) must likewise be
#     non-empty absolute paths;
#   - `storage.fsType`/`storage.options`/`storage.swapOptions` must be
#     strings;
#   - when `storage.mode == "luks"`: `storage.luksName` is REQUIRED and
#     must match nix/crypttab.nix's own mapper-name grammar
#     (`[a-z][a-z0-9_]*`); `storage.luksOptions` must be a string;
#   - `identity.username` is required and must match nix/users.nix's own
#     username grammar (`^[a-z_][a-z0-9_-]{0,31}$`);
#   - `identity.groups` must be a list of strings each matching that same
#     grammar;
#   - `identity.authorizedKeys` must be a list of strings each matching
#     nix/users.nix's own `keyLineRe`;
#   - `identity.hashedPasswordSecret`, when set, must match nix/users.nix's
#     own `secretNameRe`;
#   - `locale`/`keyboard`/`timezone` must each be non-empty strings (the
#     full shape grammars -- e.g. a real IANA tz-name shape -- are
#     nix/localization.nix's own `validateDecl`'s job at the config-eval
#     boundary proper, not re-litigated here: this file's own check is
#     "did the installer actually collect an answer", not "is it a real
#     locale/timezone", the same division of labor
#     tests/unit/202-installer-roundtrip-validate.sh exists to prove holds
#     for every fixture below);
#   - `desktop`/`thirdParty` must be booleans;
#   - `networking.hostname` is required and must match nix/networking.nix's
#     own `hostnameRe`;
#   - `networking.interface` must match nix/networking.nix's own
#     `ifaceNameRe`;
#   - `networking.dhcp` must be a boolean.
#
# `validateAnswers` returns the answers attrset with every optional field
# DEFAULTED (mirrors nix/localization.nix's own `validateDecl` returning
# `{ inherit i18n console time; }` post-defaulting) -- `compileAnswers`
# reads only off that defaulted result, never off the raw, possibly-
# partial input.
{ config, inputs, ... }:
let
  lib = inputs.nixpkgs.lib;

  # -- grammars (duplicated verbatim from their owning domain file; see
  #    header, "Eval-boundary validation") ----------------------------------
  storageModes = [ "guided" "lvm" "luks" "manual" ];

  # nix/crypttab.nix's own `nameRe` (mapper name; no "-").
  luksNameRe = "[a-z][a-z0-9_]*";
  luksNameOk = s: builtins.isString s && builtins.match luksNameRe s != null;

  # nix/users.nix's own `nameRe` (username/group name).
  userNameRe = "^[a-z_][a-z0-9_-]{0,31}$";
  userNameOk = s: builtins.isString s && builtins.match userNameRe s != null;

  # nix/users.nix's own `keyLineRe`.
  keyLineRe = "^[^ \t\n]+ [^ \t\n]+.*$";
  keyLineOk = s: builtins.isString s && builtins.match keyLineRe s != null;

  # nix/users.nix's own `secretNameRe`.
  secretNameRe = "^[A-Za-z_][A-Za-z0-9_-]{0,63}$";
  secretNameOk = s: builtins.isString s && builtins.match secretNameRe s != null;

  # nix/networking.nix's own `hostnameRe`.
  hostnameRe = "^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$";
  hostnameOk = s: builtins.isString s && builtins.match hostnameRe s != null;

  # nix/networking.nix's own `ifaceNameRe`.
  ifaceNameRe = "^[a-zA-Z][a-zA-Z0-9]*$";
  ifaceNameOk = s: builtins.isString s && builtins.match ifaceNameRe s != null;

  absPathOk = s: builtins.isString s && s != "" && builtins.substring 0 1 s == "/";
  nonEmptyStrOk = s: builtins.isString s && s != "";

  # -- per-section checks --------------------------------------------------

  checkStorage = storage:
    let
      hasMode = storage ? mode;
      mode = storage.mode or "";
      modeOk = builtins.elem mode storageModes;
      hasDevice = storage ? device;
      device = storage.device or "";
      mountPoint = storage.mountPoint or "/data";
      fsType = storage.fsType or "ext4";
      options = storage.options or "defaults";
      swapDevice = storage.swapDevice or null;
      swapOptions = storage.swapOptions or "";
      isLuks = modeOk && mode == "luks";
      luksName = storage.luksName or null;
      luksOptions = storage.luksOptions or "luks,discard";
    in
    (if hasMode && modeOk then [ ] else [ "installer.answers.storage.mode must be one of: ${builtins.concatStringsSep ", " storageModes}" ])
    ++ (if hasDevice && absPathOk device then [ ] else [ "installer.answers.storage.device must be set to an absolute path" ])
    ++ (if absPathOk mountPoint then [ ] else [ "installer.answers.storage.mountPoint must be an absolute path" ])
    ++ (if nonEmptyStrOk fsType then [ ] else [ "installer.answers.storage.fsType must be a non-empty string" ])
    ++ (if builtins.isString options then [ ] else [ "installer.answers.storage.options must be a string" ])
    ++ (if swapDevice == null || absPathOk swapDevice then [ ] else [ "installer.answers.storage.swapDevice must be null or an absolute path" ])
    ++ (if builtins.isString swapOptions then [ ] else [ "installer.answers.storage.swapOptions must be a string" ])
    ++ (
      if !isLuks then [ ]
      else (if luksNameOk luksName then [ ] else [ "installer.answers.storage.luksName is required and must match ${luksNameRe} when storage.mode == \"luks\"" ])
      ++ (if builtins.isString luksOptions then [ ] else [ "installer.answers.storage.luksOptions must be a string" ])
    );

  checkIdentity = identity:
    let
      hasUsername = identity ? username;
      username = identity.username or "";
      groups = identity.groups or [ "sudo" ];
      groupsIsList = builtins.isList groups;
      authorizedKeys = identity.authorizedKeys or [ ];
      keysIsList = builtins.isList authorizedKeys;
      hashedPasswordSecret = identity.hashedPasswordSecret or null;
    in
    (if hasUsername && userNameOk username then [ ] else [ "installer.answers.identity.username is required and must match ${userNameRe}" ])
    ++ (if groupsIsList then [ ] else [ "installer.answers.identity.groups must be a list of strings" ])
    ++ (if groupsIsList then builtins.concatMap (g: if userNameOk g then [ ] else [ "installer.answers.identity.groups: \"${toString g}\" is not a valid group name" ]) groups else [ ])
    ++ (if keysIsList then [ ] else [ "installer.answers.identity.authorizedKeys must be a list of strings" ])
    ++ (if keysIsList then builtins.concatMap (k: if keyLineOk k then [ ] else [ "installer.answers.identity.authorizedKeys: an entry is not a valid \"<type> <key> [comment]\" line" ]) authorizedKeys else [ ])
    ++ (if hashedPasswordSecret == null || secretNameOk hashedPasswordSecret then [ ] else [ "installer.answers.identity.hashedPasswordSecret must be null or match ${secretNameRe}" ]);

  checkNetworking = networking:
    let
      hasHostname = networking ? hostname;
      hostname = networking.hostname or "";
      interface = networking.interface or "eth0";
      dhcp = networking.dhcp or true;
    in
    (if hasHostname && hostnameOk hostname then [ ] else [ "installer.answers.networking.hostname is required and must match ${hostnameRe}" ])
    ++ (if ifaceNameOk interface then [ ] else [ "installer.answers.networking.interface must match ${ifaceNameRe}" ])
    ++ (if builtins.isBool dhcp then [ ] else [ "installer.answers.networking.dhcp must be a boolean" ]);

  checkAnswers = answers:
    let
      storage = answers.storage or { };
      identity = answers.identity or { };
      networking = answers.networking or { };
      locale = answers.locale or "en_US.UTF-8";
      keyboard = answers.keyboard or "us";
      timezone = answers.timezone or "UTC";
      hasDesktop = answers ? desktop;
      desktop = answers.desktop or false;
      thirdParty = answers.thirdParty or false;
    in
    checkStorage storage
    ++ checkIdentity identity
    ++ checkNetworking networking
    ++ (if nonEmptyStrOk locale then [ ] else [ "installer.answers.locale must be a non-empty string" ])
    ++ (if nonEmptyStrOk keyboard then [ ] else [ "installer.answers.keyboard must be a non-empty string" ])
    ++ (if nonEmptyStrOk timezone then [ ] else [ "installer.answers.timezone must be a non-empty string" ])
    ++ (if !hasDesktop || builtins.isBool desktop then [ ] else [ "installer.answers.desktop must be a boolean" ])
    ++ (if builtins.isBool thirdParty then [ ] else [ "installer.answers.thirdParty must be a boolean" ]);

  # validateAnswers -- see header, "Eval-boundary validation": one `throw`
  # enumerating every violation found, or the answers attrset with every
  # optional field defaulted.
  validateAnswers = answers:
    let
      errors = checkAnswers answers;
    in
    if errors != [ ] then
      throw ''
        ubuntnix.installer.answers failed eval-boundary validation (SPEC.md §10; nix/installer.nix):
        ${builtins.concatStringsSep "\n" (map (e: "  - ${e}") errors)}''
    else
      let
        storage = answers.storage or { };
        identity = answers.identity or { };
        networking = answers.networking or { };
      in
      {
        storage = {
          mode = storage.mode;
          device = storage.device;
          mountPoint = storage.mountPoint or "/data";
          fsType = storage.fsType or "ext4";
          options = storage.options or "defaults";
          swapDevice = storage.swapDevice or null;
          swapOptions = storage.swapOptions or "";
          luksName = storage.luksName or null;
          luksOptions = storage.luksOptions or "luks,discard";
        };
        identity = {
          username = identity.username;
          groups = identity.groups or [ "sudo" ];
          authorizedKeys = identity.authorizedKeys or [ ];
          hashedPasswordSecret = identity.hashedPasswordSecret or null;
        };
        locale = answers.locale or "en_US.UTF-8";
        keyboard = answers.keyboard or "us";
        timezone = answers.timezone or "UTC";
        desktop = answers.desktop or false;
        thirdParty = answers.thirdParty or false;
        networking = {
          hostname = networking.hostname;
          interface = networking.interface or "eth0";
          dhcp = networking.dhcp or true;
        };
      };

  # -- compileAnswers -- see header, "The mapping (SPEC.md §10)" -------------
  #
  # A validated, defaulted answers attrset -> the ubuntnix example-config
  # attrset (examples/server.nix's/examples/desktop.nix's own exact plain-
  # attrset shape): networking, fileSystems, swapDevices, i18n, console,
  # time, users, groups, profiles.{server,desktop}.enable -- plus, ONLY
  # when the answers ask for it, `crypttab` (storage.mode == "luks") and
  # `archive.components` (thirdParty == true). Pure attrset construction;
  # calls `validateAnswers` itself so callers never need to call it
  # separately first (mirrors nix/localization.nix's own
  # `render = decl: renderDeclaration (validateDecl decl);` split).
  compileAnswers = answers:
    let
      a = validateAnswers answers;

      isLuks = a.storage.mode == "luks";
      # See header mapping, "storage": a LUKS-backed mount routes through
      # the mapper path systemd-cryptsetup-generator(8) always unlocks a
      # crypttab entry to (nix/filesystems.nix's own "Interop with
      # nix/crypttab.nix" -- the SAME convention this file reuses here,
      # not a new one).
      fsDevice = if isLuks then "/dev/mapper/${a.storage.luksName}" else a.storage.device;

      networking = {
        hostname = a.networking.hostname;
        hosts = { };
        interfaces.${a.networking.interface} = {
          dhcp4 = a.networking.dhcp;
        };
      };

      fileSystems = {
        ${a.storage.mountPoint} = {
          device = fsDevice;
          fsType = a.storage.fsType;
          options = a.storage.options;
        };
      };

      swapDevices =
        if a.storage.swapDevice == null
        then [ ]
        else [{ device = a.storage.swapDevice; options = a.storage.swapOptions; }];

      i18n = { locale = a.locale; };
      console = { keymap = a.keyboard; };
      time = { timeZone = a.timezone; };

      userEntry =
        { groups = a.identity.groups; authorizedKeys = a.identity.authorizedKeys; }
        // lib.optionalAttrs (a.identity.hashedPasswordSecret != null) {
          hashedPasswordSecret = a.identity.hashedPasswordSecret;
        };
      users = { ${a.identity.username} = userEntry; };
      groups = { };

      # See header mapping, "desktop": exactly one profile is compiled,
      # and the other is left entirely absent (never `= false`) to match
      # examples/server.nix's/examples/desktop.nix's own shape exactly.
      profiles =
        if a.desktop
        then { desktop.enable = true; }
        else { server.enable = true; };

      base = {
        inherit networking fileSystems swapDevices i18n console time users groups profiles;
      };

      luksExtra = lib.optionalAttrs isLuks {
        crypttab.${a.storage.luksName} = {
          device = a.storage.device;
          keyFile = "none";
          options = a.storage.luksOptions;
        };
      };

      thirdPartyExtra = lib.optionalAttrs a.thirdParty {
        archive.components = {
          restricted = true;
          multiverse = true;
        };
      };
    in
    base // luksExtra // thirdPartyExtra;

  # -- example answer sets, forced through compileAnswers by
  #    `installer-compiler-proof` below at EVAL time (mirrors
  #    nix/localization.nix's own `exampleDeclaration`/
  #    `localization-manifest-proof` role) -----------------------------------

  # exampleAnswersStockServer -- reproduces examples/server.nix FIELD FOR
  # FIELD (same UUIDs, same hostname, same key comment) -- see
  # tests/unit/203-installer-structural-equality-examples.sh, which proves
  # `compileAnswers exampleAnswersStockServer` is structurally EQUAL to
  # `import ../examples/server.nix`, not merely similarly shaped.
  exampleAnswersStockServer = {
    storage = {
      mode = "guided";
      device = "/dev/disk/by-uuid/11111111-1111-1111-1111-111111111111";
      mountPoint = "/data";
      fsType = "ext4";
      options = "defaults,nofail,x-systemd.device-timeout=1";
      swapDevice = "/dev/disk/by-uuid/22222222-2222-2222-2222-222222222222";
      swapOptions = "nofail,x-systemd.device-timeout=1";
    };
    identity = {
      username = "gunnar";
      groups = [ "sudo" ];
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@ubuntnix-server"
      ];
    };
    locale = "en_US.UTF-8";
    keyboard = "us";
    timezone = "UTC";
    desktop = false;
    thirdParty = false;
    networking = {
      hostname = "ubuntnix-server";
      interface = "eth0";
      dhcp = true;
    };
  };

  # exampleAnswersStockDesktop -- reproduces examples/desktop.nix field for
  # field, mirroring exampleAnswersStockServer above exactly (see that
  # binding's own comment).
  exampleAnswersStockDesktop = {
    storage = {
      mode = "guided";
      device = "/dev/disk/by-uuid/33333333-3333-3333-3333-333333333333";
      mountPoint = "/data";
      fsType = "ext4";
      options = "defaults,nofail,x-systemd.device-timeout=1";
      swapDevice = "/dev/disk/by-uuid/44444444-4444-4444-4444-444444444444";
      swapOptions = "nofail,x-systemd.device-timeout=1";
    };
    identity = {
      username = "gunnar";
      groups = [ "sudo" ];
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly gunnar@ubuntnix-desktop"
      ];
    };
    locale = "en_US.UTF-8";
    keyboard = "us";
    timezone = "UTC";
    desktop = true;
    thirdParty = false;
    networking = {
      hostname = "ubuntnix-desktop";
      interface = "eth0";
      dhcp = true;
    };
  };

  # exampleAnswersLuksDesktopThirdParty -- a THIRD, deliberately different
  # fixture (issue #113's own acceptance criteria: "LUKS-encrypted
  # desktop", "third-party-on"): full-disk-encryption storage mode plus
  # the third-party-software checkbox enabled, on a desktop profile --
  # exercises `crypttab`/`archive.components` compilation, neither of
  # which the two stock fixtures above ever touch.
  exampleAnswersLuksDesktopThirdParty = {
    storage = {
      mode = "luks";
      device = "/dev/disk/by-uuid/55555555-5555-5555-5555-555555555555";
      mountPoint = "/";
      fsType = "ext4";
      options = "defaults";
      luksName = "cryptroot";
      luksOptions = "luks,discard";
    };
    identity = {
      username = "alex";
      groups = [ "sudo" ];
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICLoremIpsumExampleKeyOnly alex@ubuntnix-desktop"
      ];
      hashedPasswordSecret = "alexPassword";
    };
    locale = "en_US.UTF-8";
    keyboard = "us";
    timezone = "Europe/Oslo";
    desktop = true;
    thirdParty = true;
    networking = {
      hostname = "ubuntnix-luks-desktop";
      interface = "eth0";
      dhcp = true;
    };
  };
in
{
  flake.lib.installer = {
    inherit validateAnswers compileAnswers
      exampleAnswersStockServer exampleAnswersStockDesktop
      exampleAnswersLuksDesktopThirdParty;
  };

  systems = [ "x86_64-linux" ];

  perSystem = { system, ... }:
    let
      inherit (config.flake.lib.stdenv) runInUbuntuBase;

      renderJSON = answers: builtins.toJSON (compileAnswers answers) + "\n";
    in
    {
      # installer-compiler-proof: forces compileAnswers (via
      # validateAnswers) against all three example answer sets at EVAL
      # time -- see nix/localization.nix's own
      # `localization-manifest-proof` for why constructing this derivation
      # is enough, without a real `nix build`, to make CI's "flake" job
      # (`flake check --no-build`) exercise this file's validation/
      # compilation logic for real. A NEGATIVE proof (a bad answers
      # attrset actually throwing) is deliberately not wired up as a
      # `packages.*` output either, for the identical reason every sibling
      # showcase module's own header gives: `validateAnswers` throws at
      # EVALUATION time, and exposing a throwing call under `packages`
      # would poison `nix flake check` for the whole flake.
      # tests/unit/200-installer-flake-wiring.sh statically greps this
      # file's own code for the real `throw` instead, mirroring
      # tests/unit/180's/182's own posture.
      packages.installer-compiler-proof = runInUbuntuBase {
        inherit system;
        name = "installer-compiler-proof";
        script = ''
          {
            echo "MARKER=ubuntnix-installer-compiler-proof-v1"
            echo "--- stock-server ---"
            cat <<'UBX_MANIFEST_EOF'
          ${renderJSON exampleAnswersStockServer}
          UBX_MANIFEST_EOF
            echo "--- stock-desktop ---"
            cat <<'UBX_MANIFEST_EOF'
          ${renderJSON exampleAnswersStockDesktop}
          UBX_MANIFEST_EOF
            echo "--- luks-desktop-thirdparty ---"
            cat <<'UBX_MANIFEST_EOF'
          ${renderJSON exampleAnswersLuksDesktopThirdParty}
          UBX_MANIFEST_EOF
          } > "$out"
        '';
      };
    };
}
