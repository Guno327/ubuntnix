#!/usr/bin/env bash
# tests/unit/208-installer-parity-assert.sh -- fixture-based unit test for
# tests/lib/ubx-installer-parity-assert.sh, the guest-side assert
# script for the M7 installer-parity exit criterion (SPEC.md sec11; GitHub
# issue #119). Runs the script fully offline against a synthetic fixture
# root (no qemu, no nix, no network, no real root access) by pointing it
# at UBX_PARITY_ROOT / UBX_DPKG / UBX_PRO -- see that script's own header
# comment for why those overrides exist and how they stay correct on a
# real installed system too.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

script="$UBX_REPO_ROOT/tests/lib/ubx-installer-parity-assert.sh"
[ -x "$script" ] || {
  echo "FAIL: $script does not exist or is not executable" >&2
  exit 1
}

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# -- build a COMPLETE, VALID fixture root -----------------------------------
#
# Returns the path to a freshly-built good fixture root (a new mktemp -d
# each call, so callers can freely mutate their own copy without affecting
# others).
build_good_fixture() {
  root="$(mktemp -d -p "$work")"

  mkdir -p "$root/ubx/generations/1" "$root/ubx/bin"
  echo "1" > "$root/ubx/generations/current"
  : > "$root/ubx/generations/1/marker"

  cat > "$root/ubx/bin/ubx" << 'EOF'
#!/bin/sh
if [ "${1:-}" = "rebuild" ] && [ "${2:-}" = "test" ]; then
  echo "no changes"
  exit 0
fi
echo "unknown invocation: $*" >&2
exit 1
EOF
  chmod +x "$root/ubx/bin/ubx"

  mkdir -p "$root/flake/.git/git-crypt/keys"
  echo "secrets/** filter=git-crypt diff=git-crypt" > "$root/flake/.gitattributes"
  echo "dummy-key-material" > "$root/flake/.git/git-crypt/keys/default"

  mkdir -p "$root/boot/grub"
  : > "$root/boot/grub/grub.cfg"

  printf 'openssh-server\ncloud-init\nnetplan.io\n' > "$root/ubx/generations/1/seed-packages.txt"
  printf 'ubuntu-desktop\n' > "$root/ubx/generations/1/seed-exceptions.txt"

  cat > "$root/dpkg" << 'EOF'
#!/bin/sh
if [ "${1:-}" = "-l" ]; then
  echo "ii  openssh-server  1.0  amd64"
  echo "ii  cloud-init      1.0  all"
  echo "ii  netplan.io      1.0  amd64"
  exit 0
fi
exit 1
EOF
  chmod +x "$root/dpkg"

  cat > "$root/pro" << 'EOF'
#!/bin/sh
if [ "${1:-}" = "status" ]; then
  echo '{"attached": true}'
  exit 0
fi
exit 1
EOF
  chmod +x "$root/pro"

  echo "$root"
}

run_script() {
  local root="$1"
  shift
  UBX_PARITY_ROOT="$root" UBX_DPKG="$root/dpkg" UBX_PRO="$root/pro" "$script" "$@"
}

# -- good fixture: must PASS -------------------------------------------------
good_root="$(build_good_fixture)"
out="$(run_script "$good_root" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "good fixture: expected exit 0, got $rc (output: $out)"
case "$out" in
  *"UBX-INSTALLER-PARITY-PASS"*) ;;
  *) fail "good fixture: expected UBX-INSTALLER-PARITY-PASS in output, got: $out" ;;
esac

# -- good fixture with UBX_PARITY_EXPECT_PRO unset: Pro check is skipped ----
# even if a 'pro' stub would report not-attached, because the check must
# never even run without UBX_PARITY_EXPECT_PRO=1.
skip_root="$(build_good_fixture)"
cat > "$skip_root/pro" << 'EOF'
#!/bin/sh
echo '{"attached": false}'
exit 0
EOF
chmod +x "$skip_root/pro"
out="$(run_script "$skip_root" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "pro-unset: expected exit 0 (Pro check skipped), got $rc (output: $out)"
case "$out" in
  *"UBX-INSTALLER-PARITY-PASS"*) ;;
  *) fail "pro-unset: expected UBX-INSTALLER-PARITY-PASS, got: $out" ;;
esac

# -- assert a broken fixture fails with UBX-INSTALLER-PARITY-FAIL and a
# message containing the given needle.
assert_fails() {
  local desc="$1" root="$2" needle="$3"
  shift 3
  out="$(run_script "$root" "$@" 2>&1)"
  rc=$?
  [ "$rc" -eq 1 ] || {
    fail "$desc: expected exit 1, got $rc (output: $out)"
    return
  }
  case "$out" in
    *"UBX-INSTALLER-PARITY-FAIL"*) ;;
    *) fail "$desc: expected UBX-INSTALLER-PARITY-FAIL in output, got: $out" ;;
  esac
  case "$out" in
    *"$needle"*) ;;
    *) fail "$desc: expected output to mention '$needle', got: $out" ;;
  esac
}

# (a) missing generation marker
root="$(build_good_fixture)"
rm -f "$root/ubx/generations/1/marker"
assert_fails "(a) missing generation marker" "$root" "generation marker"

# (b) non-executable/missing ubx/bin/ubx
root="$(build_good_fixture)"
chmod -x "$root/ubx/bin/ubx"
assert_fails "(b) non-executable ubx binary" "$root" "ubx/bin/ubx"

root="$(build_good_fixture)"
rm -f "$root/ubx/bin/ubx"
assert_fails "(b) missing ubx binary" "$root" "ubx/bin/ubx"

# (c) /flake not a git repo
root="$(build_good_fixture)"
rm -rf "$root/flake/.git"
assert_fails "(c) flake not a git repo" "$root" "git repository"

# (d) .gitattributes without filter=git-crypt
root="$(build_good_fixture)"
echo "*.txt text" > "$root/flake/.gitattributes"
assert_fails "(d) gitattributes missing git-crypt filter" "$root" "filter=git-crypt"

# (e) empty/missing git-crypt keys dir
root="$(build_good_fixture)"
rm -rf "$root/flake/.git/git-crypt/keys"
mkdir -p "$root/flake/.git/git-crypt/keys"
assert_fails "(e) empty git-crypt keys dir" "$root" "git-crypt"

root="$(build_good_fixture)"
rm -rf "$root/flake/.git/git-crypt/keys"
assert_fails "(e) missing git-crypt keys dir" "$root" "git-crypt"

# (f) missing boot/grub/grub.cfg
root="$(build_good_fixture)"
rm -f "$root/boot/grub/grub.cfg"
assert_fails "(f) missing grub.cfg" "$root" "grub.cfg"

# (g) a seed package NOT in the dpkg stub output (missing-seed)
root="$(build_good_fixture)"
printf 'openssh-server\ncloud-init\nnetplan.io\nsome-missing-pkg\n' > "$root/ubx/generations/1/seed-packages.txt"
assert_fails "(g) missing seed package" "$root" "missing-seed-packages=[ some-missing-pkg"

# (h) an exception package present in the dpkg stub output
root="$(build_good_fixture)"
cat > "$root/dpkg" << 'EOF'
#!/bin/sh
if [ "${1:-}" = "-l" ]; then
  echo "ii  openssh-server  1.0  amd64"
  echo "ii  cloud-init      1.0  all"
  echo "ii  netplan.io      1.0  amd64"
  echo "ii  ubuntu-desktop  1.0  amd64"
  exit 0
fi
exit 1
EOF
chmod +x "$root/dpkg"
assert_fails "(h) unexpected exception package present" "$root" "unexpected-exception-packages=[ ubuntu-desktop"

# (i) UBX_PARITY_EXPECT_PRO=1 with pro reporting not-attached
root="$(build_good_fixture)"
cat > "$root/pro" << 'EOF'
#!/bin/sh
echo '{"attached": false}'
exit 0
EOF
chmod +x "$root/pro"
out="$(UBX_PARITY_ROOT="$root" UBX_DPKG="$root/dpkg" UBX_PRO="$root/pro" UBX_PARITY_EXPECT_PRO=1 "$script" 2>&1)"
rc=$?
[ "$rc" -eq 1 ] || fail "(i) pro not attached: expected exit 1, got $rc (output: $out)"
case "$out" in
  *"UBX-INSTALLER-PARITY-FAIL"*"Pro"*) ;;
  *) fail "(i) pro not attached: expected FAIL mentioning Pro, got: $out" ;;
esac

# (j) ubx rebuild test printing a diff / non-"no changes" output
root="$(build_good_fixture)"
cat > "$root/ubx/bin/ubx" << 'EOF'
#!/bin/sh
if [ "${1:-}" = "rebuild" ] && [ "${2:-}" = "test" ]; then
  echo "+++ would change /etc/hostname"
  exit 0
fi
echo "unknown invocation: $*" >&2
exit 1
EOF
chmod +x "$root/ubx/bin/ubx"
assert_fails "(j) rebuild reports a diff" "$root" "rebuild test"

exit "$fails"
