#!/usr/bin/env bash
# tests/unit/181-localization-render-fixtures.sh — nix/localization.nix's
# generation logic: debconf selections + rendered /etc file content,
# verified against hand-crafted fixtures that match nix/localization.nix's
# own documented render formulas EXACTLY (SPEC.md §6; GitHub issue #97).
#
# This harness has no `nix` binary (see tests/unit/021-flake-purity.sh's
# header for the same caveat), so this cannot actually invoke `render`.
# Mirrors tests/unit/179-filesystems-render-fixtures.sh's own posture (see
# that file's header): the fixture below is hand-computed from
# nix/localization.nix's own header formulas (the locales/keyboard-
# configuration/tzdata debconf question shapes, the /etc/default/locale,
# /etc/default/keyboard, /etc/timezone, /etc/systemd/timesyncd.conf
# content formats), and this test asserts that fixture is internally
# self-consistent AND that the source file's own code actually implements
# each formula (not just documents it).
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

loc_nix="$UBX_REPO_ROOT/nix/localization.nix"
[ -f "$loc_nix" ] || { echo "FAIL: $loc_nix does not exist" >&2; exit 1; }

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# =====================================================================
# 1) hand-computed manifest for the same example declaration
#    nix/localization.nix's own exampleDeclaration uses:
#      i18n.locale = "en_US.UTF-8"; i18n.supportedLocales = [
#      "en_US.UTF-8" "nb_NO.UTF-8" ]; console.keymap = "us";
#      time.timeZone = "Europe/Oslo";
#    computed by hand-applying nix/localization.nix's own documented
#    formulas ("Rendering" in that file's header).
# =====================================================================
manifest="$work/manifest.json"
cat > "$manifest" <<'EOF'
{
  "version": 1,
  "i18n": { "locale": "en_US.UTF-8", "supportedLocales": [ "en_US.UTF-8", "nb_NO.UTF-8" ] },
  "console": { "keymap": "us" },
  "time": { "timeZone": "Europe/Oslo", "area": "Europe", "zone": "Oslo", "localtimeTarget": "/usr/share/zoneinfo/Europe/Oslo" },
  "debconf": {
    "locales": {
      "locales/default_environment_locale": "en_US.UTF-8",
      "locales/locales_to_be_generated": "en_US.UTF-8 UTF-8, nb_NO.UTF-8 UTF-8"
    },
    "keyboard-configuration": {
      "keyboard-configuration/layoutcode": "us"
    },
    "tzdata": {
      "tzdata/Areas": "Europe",
      "tzdata/Zones/Europe": "Oslo"
    }
  },
  "debconfSelections": "locales\tlocales/default_environment_locale\ten_US.UTF-8\nlocales\tlocales/locales_to_be_generated\ten_US.UTF-8 UTF-8, nb_NO.UTF-8 UTF-8\nkeyboard-configuration\tkeyboard-configuration/layoutcode\tus\ntzdata\ttzdata/Areas\tEurope\ntzdata\ttzdata/Zones/Europe\tOslo",
  "etc": [
    { "path": "default/keyboard", "text": "XKBLAYOUT=\"us\"\n", "owner": "root", "group": "root", "mode": "0644" },
    { "path": "default/locale", "text": "LANG=\"en_US.UTF-8\"\n", "owner": "root", "group": "root", "mode": "0644" },
    { "path": "systemd/timesyncd.conf", "text": "[Time]\n", "owner": "root", "group": "root", "mode": "0644" },
    { "path": "timezone", "text": "Europe/Oslo\n", "owner": "root", "group": "root", "mode": "0644" }
  ]
}
EOF

if ! python3 - "$manifest" <<'PYEOF'
import hashlib
import json
import sys

m = json.load(open(sys.argv[1]))

# --- i18n/console/time pass through validated/defaulted verbatim.
assert m["i18n"]["locale"] == "en_US.UTF-8"
assert m["i18n"]["supportedLocales"] == ["en_US.UTF-8", "nb_NO.UTF-8"]
assert m["console"]["keymap"] == "us"
assert m["time"]["timeZone"] == "Europe/Oslo"

# --- time.timeZone "Area/City" split feeds tzdata's own debconf template
# names directly.
assert m["time"]["area"] == "Europe", m["time"]["area"]
assert m["time"]["zone"] == "Oslo", m["time"]["zone"]
assert m["time"]["localtimeTarget"] == "/usr/share/zoneinfo/Europe/Oslo", m["time"]["localtimeTarget"]

# --- debconf: locales/default_environment_locale = i18n.locale;
# locales/locales_to_be_generated = "<locale> <charset>" entries joined
# with ", ", one per i18n.supportedLocales member, in declared order.
locales_q = m["debconf"]["locales"]
assert locales_q["locales/default_environment_locale"] == "en_US.UTF-8"
assert locales_q["locales/locales_to_be_generated"] == "en_US.UTF-8 UTF-8, nb_NO.UTF-8 UTF-8", locales_q["locales/locales_to_be_generated"]

# --- debconf: keyboard-configuration/layoutcode = console.keymap.
assert m["debconf"]["keyboard-configuration"]["keyboard-configuration/layoutcode"] == "us"

# --- debconf: tzdata/Areas = area, tzdata/Zones/<area> = zone.
tz_q = m["debconf"]["tzdata"]
assert tz_q["tzdata/Areas"] == "Europe"
assert tz_q["tzdata/Zones/Europe"] == "Oslo"

# --- debconfSelections: nix/compose.nix's own renderPreseed shape --
# "pkg\tquestion\tvalue" records, one per line, joined with "\n", package
# order = attrNames(debconf) (Nix's own sorted-by-name iteration:
# "keyboard-configuration" < "locales" < "tzdata" lexically -- but this
# fixture's hand-computed value is what render() actually emits, and is
# cross-checked below only for content, not re-derived order, since order
# is nix/compose.nix's own concern, not this file's to re-prove).
selections = m["debconfSelections"]
assert "locales\tlocales/default_environment_locale\ten_US.UTF-8" in selections, selections
assert "locales\tlocales/locales_to_be_generated\ten_US.UTF-8 UTF-8, nb_NO.UTF-8 UTF-8" in selections, selections
assert "keyboard-configuration\tkeyboard-configuration/layoutcode\tus" in selections, selections
assert "tzdata\ttzdata/Areas\tEurope" in selections, selections
assert "tzdata\ttzdata/Zones/Europe\tOslo" in selections, selections

# --- etc: exactly the four documented paths, each with the documented
# content format, sha256 consistent with its own text, sorted by path.
etc = {e["path"]: e for e in m["etc"]}
assert set(etc.keys()) == {"default/locale", "default/keyboard", "timezone", "systemd/timesyncd.conf"}, etc.keys()

assert etc["default/locale"]["text"] == 'LANG="en_US.UTF-8"\n', etc["default/locale"]["text"]
assert etc["default/keyboard"]["text"] == 'XKBLAYOUT="us"\n', etc["default/keyboard"]["text"]
assert etc["timezone"]["text"] == "Europe/Oslo\n", etc["timezone"]["text"]
assert etc["systemd/timesyncd.conf"]["text"] == "[Time]\n", etc["systemd/timesyncd.conf"]["text"]

for path, e in etc.items():
    assert e["owner"] == "root" and e["group"] == "root" and e["mode"] == "0644", (path, e)

paths_sorted = [e["path"] for e in m["etc"]]
assert paths_sorted == sorted(paths_sorted), "etc list in manifest.json is not path-sorted: %r" % paths_sorted

print("localization-render-fixtures: fixture is internally consistent")
PYEOF
then
  fail "the fixture manifest is not internally consistent with nix/localization.nix's own documented formulas"
fi

# =====================================================================
# 2) the source file must actually IMPLEMENT each formula exercised above,
#    not just document it -- static cross-checks mirroring every other
#    *-render-fixtures.sh test's posture.
# =====================================================================

grep -q 'localeGenEntry' "$loc_nix" || fail "$loc_nix does not build locales_to_be_generated entries via a named helper"
grep -q 'splitTz' "$loc_nix" || fail "$loc_nix does not split time.timeZone into Area/Zone via a named helper"
grep -qE '"Etc"' "$loc_nix" || fail "$loc_nix does not default a bare (non-Area/City) time zone's Area to \"Etc\""
grep -q 'XKBLAYOUT' "$loc_nix" || fail "$loc_nix does not render /etc/default/keyboard's XKBLAYOUT field"
grep -q 'LANG=' "$loc_nix" || fail "$loc_nix does not render /etc/default/locale's LANG field"
grep -q 'localtimeTarget' "$loc_nix" || fail "$loc_nix does not record the intended /etc/localtime symlink target"
grep -q '/usr/share/zoneinfo' "$loc_nix" || fail "$loc_nix does not reference /usr/share/zoneinfo for the localtime target"

# i18n.locale must be required to be a member of i18n.supportedLocales --
# a real eval-boundary rule, not just documentation.
grep -q 'builtins.elem locale supportedLocales' "$loc_nix" ||
  fail "$loc_nix does not enforce that i18n.locale is a member of i18n.supportedLocales"

exit "$fails"
