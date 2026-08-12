#!/usr/bin/env bash
# tests/unit/234-docs-status-consistency.sh -- pins docs/modules.md,
# docs/index.md, docs/systemd.md, and docs/guards.md against reasserting
# that shipped functionality is deferred/absent (GitHub issue #155).
#
# WHY THIS TEST EXISTS: before issue #155, four docs pages claimed
# functionality was not-yet-built when the code backing it had already
# shipped:
#   - docs/modules.md said "There is no flake and no `modules/` tree in
#     this repository yet", while flake.nix and nix/lib.nix (which uses
#     flake-parts-lib.mkSubmoduleOptions) were both real, and the SAME page
#     went on to document `profiles.server`/`profiles.desktop` as landed.
#   - docs/index.md said the repo was "partway through milestone M2" with
#     "no modules and no real Nix evaluation/composition for `/etc`,
#     systemd units, or a rootfs image yet", while nix/etc.nix,
#     nix/systemd.nix, and nix/compose.nix all existed and were proven in
#     CI (etc-proof/systemd-proof/compose-image-proof/boot-image-proof),
#     and docs/install.md (fixed under issue #148) already said "M1
#     through M6 have shipped".
#   - docs/systemd.md said wiring into `ubx rebuild switch` was "explicitly
#     deferred" and that "Nothing on this page describes a behavior
#     observable on a running ubuntnix system yet", while bin/ubx's
#     execute_domains() actually invokes bin/ubx-systemd-apply (and
#     bin/ubx-etc-apply) for real, pinned by
#     tests/unit/137-ubx-systemd-apply-real-invocation.sh.
#   - docs/guards.md said image installation was "blocked on issue #10's
#     file-injection mechanism", while nix/boot.nix's
#     switchLoopExtraFilesScript (issue #10's mechanism, landed) really
#     does divert apt/apt-get/dpkg and install the ubx-guard-* scripts --
#     though only in the switch-loop proof image, not any server/desktop
#     profile image (a real, narrower gap this test also pins).
#
# This is the same self-consistency-enforcement pattern
# tests/unit/216-install-docs-consistency.sh (issue #148) established:
# grep for the exact stale phrases, guarded by the real code that
# contradicts them actually being present, so the test goes quiet (SKIP)
# rather than false-failing if a milestone genuinely regresses. Each page
# also gets a POSITIVE check -- the real mechanism must be named, not just
# the stale phrase absent -- so a rewrite that goes vague instead of
# accurate doesn't silently satisfy this test.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

# ---------------------------------------------------------------------------
# 1. docs/modules.md -- flake + modules.md self-contradiction
# ---------------------------------------------------------------------------
modules_doc="docs/modules.md"
if [ ! -f "$modules_doc" ]; then
  echo "FAIL: $modules_doc does not exist" >&2
  fails=$((fails + 1))
else
  if [ -e "flake.nix" ] && grep -q "mkSubmoduleOptions" nix/lib.nix 2>/dev/null; then
    if grep -qi "there is no flake and no \`modules/\` tree" "$modules_doc"; then
      fail "$modules_doc reasserts 'there is no flake ... in this repository yet', but flake.nix and nix/lib.nix (flake-parts-lib.mkSubmoduleOptions) both exist"
    fi
    for needle in "flake.nix" "nix/lib.nix"; do
      grep -q -- "$needle" "$modules_doc" || {
        fail "$modules_doc no longer names '$needle' -- it should say plainly that the flake skeleton is real"
      }
    done
  else
    echo "SKIP-ish: flake.nix/nix/lib.nix mkSubmoduleOptions not found -- nothing to contradict in $modules_doc" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 2. docs/index.md -- stale M2 project-status admonition
# ---------------------------------------------------------------------------
index_doc="docs/index.md"
if [ ! -f "$index_doc" ]; then
  echo "FAIL: $index_doc does not exist" >&2
  fails=$((fails + 1))
else
  if [ -e "nix/etc.nix" ] && [ -e "nix/systemd.nix" ] && [ -e "nix/compose.nix" ]; then
    if grep -qi "no modules and no real nix evaluation/composition" "$index_doc"; then
      fail "$index_doc reasserts 'no modules and no real Nix evaluation/composition for /etc, systemd units, or a rootfs image yet', but nix/etc.nix, nix/systemd.nix, and nix/compose.nix all exist"
    fi
    if grep -qi "partway through milestone m2" "$index_doc"; then
      fail "$index_doc reasserts 'partway through milestone M2', but docs/install.md (issue #148) already says M1 through M6 have shipped"
    fi
    for needle in "nix/etc.nix" "nix/systemd.nix" "nix/compose.nix"; do
      grep -q -- "$needle" "$index_doc" || {
        fail "$index_doc no longer names '$needle' -- it should say plainly which real mechanism backs the project-status claim"
      }
    done
  else
    echo "SKIP-ish: nix/etc.nix, nix/systemd.nix, nix/compose.nix not all present -- nothing to contradict in $index_doc" >&2
  fi

  # -- Guides list must include every toctree page, including users.
  if grep -q '^users$' "$index_doc" && ! grep -q '{doc}`users`' "$index_doc"; then
    fail "$index_doc's toctree lists 'users' but the prose Guides list has no {doc}\`users\` entry"
  fi
fi

# ---------------------------------------------------------------------------
# 3. docs/systemd.md -- activation wiring claimed deferred, but real
# ---------------------------------------------------------------------------
systemd_doc="docs/systemd.md"
systemd_apply_invocation_test="tests/unit/137-ubx-systemd-apply-real-invocation.sh"
if [ ! -f "$systemd_doc" ]; then
  echo "FAIL: $systemd_doc does not exist" >&2
  fails=$((fails + 1))
else
  if grep -q "ubx-systemd-apply" bin/ubx 2>/dev/null && [ -e "$systemd_apply_invocation_test" ]; then
    if grep -qi "wiring this into a real running system's \`ubx rebuild switch\`.\{0,40\}deferred" "$systemd_doc"; then
      fail "$systemd_doc claims 'ubx rebuild switch' wiring is deferred, but bin/ubx's execute_domains() really invokes bin/ubx-systemd-apply, pinned by $systemd_apply_invocation_test"
    fi
    if grep -qi "nothing on this page describes a behavior observable on a running ubuntnix system yet" "$systemd_doc"; then
      fail "$systemd_doc still claims nothing on the page is observable on a running system, but execute_domains() really runs bin/ubx-systemd-apply"
    fi
    grep -q -- "137-ubx-systemd-apply-real-invocation" "$systemd_doc" || {
      fail "$systemd_doc no longer names $systemd_apply_invocation_test -- it should cite the test that pins the real invocation"
    }
  else
    echo "SKIP-ish: bin/ubx does not invoke ubx-systemd-apply, or $systemd_apply_invocation_test is missing -- nothing to contradict in $systemd_doc" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 4. docs/guards.md -- "blocked on issue #10" claim, and the narrowed
#    switch-loop-only wiring claim that replaced it
# ---------------------------------------------------------------------------
guards_doc="docs/guards.md"
if [ ! -f "$guards_doc" ]; then
  echo "FAIL: $guards_doc does not exist" >&2
  fails=$((fails + 1))
else
  if grep -q "ubx_m2_install_guard" nix/boot.nix 2>/dev/null; then
    if grep -qi "blocked.\{0,10\}on issue #10's file-injection mechanism" "$guards_doc"; then
      fail "$guards_doc still claims image wiring is blocked on issue #10's file-injection mechanism, but nix/boot.nix's switchLoopExtraFilesScript (ubx_m2_install_guard) already performs that wiring"
    fi
    grep -q -- "switchLoopExtraFilesScript\|switch-loop proof" "$guards_doc" || {
      fail "$guards_doc no longer names the switch-loop proof image -- it should say plainly where guard installation is real today"
    }
  else
    echo "SKIP-ish: nix/boot.nix has no ubx_m2_install_guard -- nothing to contradict in $guards_doc" >&2
  fi

  # -- Preserve the TRUE half: no server/desktop profile image installs the
  #    guards yet. This is a positive check for the narrowed claim, not
  #    just an absence check, so a future edit can't silently overclaim
  #    that guards ship in production images.
  guard_hits="$(grep -rl "ubx-guard" nix/*.nix 2>/dev/null || true)"
  only_boot_nix=1
  for f in $guard_hits; do
    [ "$f" = "nix/boot.nix" ] || only_boot_nix=0
  done
  if [ "$only_boot_nix" = "1" ] && [ -n "$guard_hits" ]; then
    grep -qi "no server or desktop profile image installs the guards" "$guards_doc" || {
      fail "$guards_doc should still say plainly that no server/desktop profile image installs the guards yet (grep -rl ubx-guard nix/*.nix hits only nix/boot.nix)"
    }
  fi
fi

if [ "$fails" -eq 0 ]; then
  echo "OK: docs/modules.md, docs/index.md, docs/systemd.md, and docs/guards.md do not reassert stale absent/deferred claims contradicted by the real tree, and guards.md still correctly scopes guard installation to the switch-loop proof image"
fi

exit "$fails"
