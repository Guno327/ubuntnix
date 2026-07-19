#!/usr/bin/env bash
# docs/gen_reference.py must be deterministic, must actually derive its
# output from the modules/ tree it scans, and must degrade gracefully
# (still exit 0, still emit a valid page) when no modules/ tree exists yet
# (true of this repo pre-M1). See SPEC.md G10 and docs/reference/index.md.
set -eu
cd "$UBX_REPO_ROOT"

gen="$UBX_REPO_ROOT/docs/gen_reference.py"
[ -e "$gen" ] || { echo "missing $gen"; exit 1; }

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# --- fixture tree with a couple of declared options -------------------
fixture="$work/fixture"
mkdir -p "$fixture/modules/net"
cat >"$fixture/modules/net/basic.nix" <<'EOF'
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
cat >"$fixture/modules/net/extra.nix" <<'EOF'
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

# (c) empty tree: no modules/ dir at all still exits 0 and emits the
# documented empty-state page rather than erroring out.
empty_root="$work/empty"
mkdir -p "$empty_root"
out_empty="$work/out_empty.md"

if ! python3 "$gen" --root "$empty_root" --out "$out_empty"; then
  echo "gen_reference.py exited non-zero on a tree with no modules/"
  exit 1
fi

[ -e "$out_empty" ] || { echo "no output written for empty tree"; exit 1; }
grep -q 'no options are declared' "$out_empty" || {
  echo "empty-state page missing its no-options-declared message"
  exit 1
}
