#!/usr/bin/env bash
# docs/gen_reference.py must be deterministic, must actually derive its
# output from the nix/ tree it scans (the REAL location of every mkOption
# declaration in this repo -- see GitHub issue #152; there is no
# `modules/` tree), must be LOUD (non-zero exit) if a tree that has
# `.nix` sources somehow yields zero extracted options (an extractor bug,
# not a legitimate empty state), and must still degrade gracefully (exit
# 0, emit a valid empty-state page) when a tree has no `.nix` files under
# nix/ at all. See SPEC.md G10 and docs/reference/index.md.
set -eu
cd "$UBX_REPO_ROOT"

gen="$UBX_REPO_ROOT/docs/gen_reference.py"
[ -e "$gen" ] || { echo "missing $gen"; exit 1; }

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# --- fixture tree with a couple of declared options -------------------
fixture="$work/fixture"
mkdir -p "$fixture/nix"
cat >"$fixture/nix/basic.nix" <<'EOF'
{ lib, ... }:
{
  options.networking.hostname = lib.mkOption {
    type = lib.types.str;
    default = "ubuntnix";
    description = "The machine's hostname.";
  };
}
EOF

out1="$work/out1.md"
out2="$work/out2.md"

python3 "$gen" --root "$fixture" --out "$out1"
python3 "$gen" --root "$fixture" --out "$out2"

# (a) determinism: two runs against the same tree are byte-identical.
if ! diff -q "$out1" "$out2" >/dev/null; then
  echo "gen_reference.py is not deterministic across repeated runs"
  exit 1
fi

# (b) derivation-from-tree: the declared option path shows up in the page.
grep -q 'networking.hostname' "$out1" || {
  echo "declared option networking.hostname missing from generated page"
  exit 1
}

# ... and changing the fixture tree changes the rendered output.
cat >"$fixture/nix/extra.nix" <<'EOF'
{ lib, ... }:
{
  options.networking.domain = lib.mkOption {
    type = lib.types.str;
    default = "example.com";
    description = "The machine's domain.";
  };
}
EOF

out3="$work/out3.md"
python3 "$gen" --root "$fixture" --out "$out3"

grep -q 'networking.domain' "$out3" || {
  echo "newly declared option networking.domain missing after fixture change"
  exit 1
}

if diff -q "$out1" "$out3" >/dev/null; then
  echo "output unchanged after fixture tree changed"
  exit 1
fi

# (b2) bare-name shape: real nix/*.nix files declare almost all of their
# options as `<name> = lib.mkOption { ... };` inside an `options = {
# ... };` submodule block, NOT as `options.<dotted.path> = mkOption`
# (that dotted shape is only used for the top-level wrapper, e.g.
# `options.pro = lib.mkOption { type = proType; };`). The extractor must
# handle both shapes, or it will miss almost every real option.
cat >"$fixture/nix/submodule.nix" <<'EOF'
{ lib, ... }:
let
  fooType = lib.types.submodule {
    options = {
      bareFieldName = lib.mkOption {
        type = lib.types.str;
        default = "x";
        description = "A field declared the way real nix/*.nix files do it.";
      };
    };
  };
in
{
  options.foo = lib.mkOption { type = fooType; default = { }; };
}
EOF

out4="$work/out4.md"
python3 "$gen" --root "$fixture" --out "$out4"
grep -q 'bareFieldName' "$out4" || {
  echo "bare-name mkOption declaration (the shape almost all real nix/*.nix options use) was not extracted"
  exit 1
}

# (c) empty tree: no nix/ dir at all still exits 0 and emits the
# documented empty-state page rather than erroring out.
empty_root="$work/empty"
mkdir -p "$empty_root"
out_empty="$work/out_empty.md"

if ! python3 "$gen" --root "$empty_root" --out "$out_empty"; then
  echo "gen_reference.py exited non-zero on a tree with no nix/"
  exit 1
fi

[ -e "$out_empty" ] || { echo "no output written for empty tree"; exit 1; }
grep -q 'no options are declared' "$out_empty" || {
  echo "empty-state page missing its no-options-declared message"
  exit 1
}

# (d) loud failure: a tree whose nix/ dir DOES contain .nix source files,
# but none of them yield a single matched mkOption, must exit non-zero
# with a diagnostic rather than silently emitting an empty-looking page
# (that would be indistinguishable from a genuinely option-free tree and
# would hide an extractor regression -- see GitHub issue #152).
no_options_root="$work/no-options"
mkdir -p "$no_options_root/nix"
cat >"$no_options_root/nix/stub.nix" <<'EOF'
{ lib, ... }:
{
  # No mkOption declarations here at all.
  imports = [ ];
}
EOF
out_no_options="$work/out_no_options.md"

if python3 "$gen" --root "$no_options_root" --out "$out_no_options" 2>"$work/stderr.txt"; then
  echo "gen_reference.py exited 0 on a nix/ tree with .nix sources but zero extracted options (should be loud, not silent)"
  exit 1
fi
[ -s "$work/stderr.txt" ] || {
  echo "gen_reference.py exited non-zero but printed no diagnostic to stderr"
  exit 1
}

# (e) real repo: this is the actual regression target of issue #152 --
# every prior case above only ever ran gen_reference.py against synthetic
# fixtures, so a generator that scanned the wrong directory (`modules/`,
# which does not exist in this repo) could pass all of them while still
# emitting a permanently-empty page against the real tree. Run it against
# $UBX_REPO_ROOT itself and assert real options, from real nix/*.nix
# files, actually show up.
out_real="$work/out_real.md"
python3 "$gen" --root "$UBX_REPO_ROOT" --out "$out_real"

real_option_count="$(grep -c '^## `' "$out_real")"
[ "$real_option_count" -gt 0 ] || {
  echo "gen_reference.py extracted 0 options from the real repo tree (\$UBX_REPO_ROOT) -- G10 requires this page to reflect the current state of the tree, and nix/*.nix has real mkOption declarations"
  exit 1
}

# Specific, real option names declared in specific real nix/*.nix files
# (verified present as of issue #152; see nix/networking.nix,
# nix/pro.nix, nix/archive.nix, nix/users.nix, nix/secrets.nix).
for needle in hostname tokenSecret restricted authorizedKeys environmentVariable; do
  grep -q -- "$needle" "$out_real" || {
    echo "real option '$needle' (declared in nix/*.nix) missing from the generated reference for the real repo tree"
    exit 1
  }
done
