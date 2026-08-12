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
# Extended for GitHub issue #156 (the three remaining undocumented-module
# pages: crypttab, localization, filesystems) with the identical
# grep-for-contradiction-plus-positive-check pattern, guarding against the
# SAME class of drift in the other direction too: docs/filesystems.md and
# docs/localization.md must not understate what is real (both modules are
# genuinely baked into nix/profiles.nix's server/desktop parity images and
# CI-built/e2e-booted, not just eval-time proofs), while docs/crypttab.md
# must not overstate what is real (nix/crypttab.nix/bin/ubx-crypttab* are
# unit-tested groundwork only -- not wired into bin/ubx's execute_domains,
# no example-config declaration, no e2e coverage -- unlike its filesystems/
# localization siblings).
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
  # The single quotes here are deliberate and required: the pattern is the
  # LITERAL MyST role {doc}`users`, backticks and all. shellcheck reads
  # those backticks as a command substitution it thinks we wanted expanded
  # (SC2016) -- a false positive, since expanding anything here would break
  # the grep. Quoting it differently would change what we search for.
  # shellcheck disable=SC2016
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

# ---------------------------------------------------------------------------
# 5. docs/crypttab.md -- must exist, name the real mechanism, and, once
#    bin/ubx's execute_domains really invokes bin/ubx-crypttab-apply
#    (GitHub issue #170), must say so plainly and must NOT still claim the
#    domain is unwired -- mirrors section 3's docs/systemd.md pattern
#    above (an UNDERCLAIM is now the risk for this page, the opposite of
#    the overclaim risk this section used to guard against before #170
#    landed).
# ---------------------------------------------------------------------------
crypttab_doc="docs/crypttab.md"
crypttab_apply_invocation_test="tests/unit/236-ubx-crypttab-apply-real-invocation.sh"
if [ ! -f "$crypttab_doc" ]; then
  fail "$crypttab_doc does not exist (GitHub issue #156: nix/crypttab.nix/bin/ubx-crypttab*/bin/ubx-crypttab-apply have no documentation page)"
else
  for needle in "nix/crypttab.nix" "bin/ubx-crypttab" "bin/ubx-crypttab-apply"; do
    grep -q -- "$needle" "$crypttab_doc" || {
      fail "$crypttab_doc no longer names '$needle' -- it should say plainly which real, unit-tested mechanism backs this page"
    }
  done

  if grep -q "ubx-crypttab-apply" bin/ubx 2>/dev/null && [ -e "$crypttab_apply_invocation_test" ]; then
    if grep -qiE "not currently wired into anything|no later issue wires this domain|it is also \*\*not\*\* currently wired" "$crypttab_doc"; then
      fail "$crypttab_doc still claims the crypttab domain is unwired, but bin/ubx's execute_domains really invokes bin/ubx-crypttab-apply, pinned by $crypttab_apply_invocation_test"
    fi
    grep -q -- "235-ubx-rebuild-crypttab-wiring\|236-ubx-crypttab-apply-real-invocation" "$crypttab_doc" || {
      fail "$crypttab_doc no longer names a crypttab-wiring pinning test (tests/unit/235-ubx-rebuild-crypttab-wiring.sh or $crypttab_apply_invocation_test) -- it should cite the test(s) that pin the real invocation"
    }
  else
    echo "SKIP-ish: bin/ubx does not invoke ubx-crypttab-apply, or $crypttab_apply_invocation_test is missing -- nothing to contradict in $crypttab_doc" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 6. docs/filesystems.md and docs/localization.md -- must exist, name the
#    real mechanism, and must NOT understate the real parity-image wiring
#    (both modules' render output is genuinely baked into
#    nix/profiles.nix's server-parity-image/desktop-parity-image, unlike
#    a module that only has an isolated eval-time proof)
# ---------------------------------------------------------------------------
check_base_module_doc() {
  doc_path="$1"
  nix_file="$2"
  lib_attr="$3"

  if [ ! -f "$doc_path" ]; then
    fail "$doc_path does not exist (GitHub issue #156: $nix_file has no documentation page)"
    return
  fi

  grep -q -- "$nix_file" "$doc_path" || {
    fail "$doc_path no longer names '$nix_file' -- it should say plainly which real, unit-tested module backs this page"
  }

  # -- Only meaningful once nix/profiles.nix genuinely wires this module's
  #    render output into the parity images -- if that wiring is ever
  #    removed, this check should go quiet, not false-fail (mirrors this
  #    test's own "SKIP-ish" posture elsewhere in this file).
  if grep -q -- "config.flake.lib.${lib_attr}.render" nix/profiles.nix 2>/dev/null; then
    grep -qi "server-parity-image\|desktop-parity-image\|examples/server.nix\|examples/desktop.nix" "$doc_path" || {
      fail "$doc_path does not mention the server/desktop parity images, but nix/profiles.nix really calls config.flake.lib.${lib_attr}.render against examples/server.nix/examples/desktop.nix -- this page should say so, not leave it as an isolated eval-time proof"
    }
  else
    echo "SKIP-ish: nix/profiles.nix does not call config.flake.lib.${lib_attr}.render -- nothing to contradict in $doc_path" >&2
  fi
}

check_base_module_doc "docs/filesystems.md" "nix/filesystems.nix" "fileSystems"
check_base_module_doc "docs/localization.md" "nix/localization.nix" "localization"

# ---------------------------------------------------------------------------
# 7. docs/index.md -- the three new pages (issue #156) must be wired into
#    both the prose Guides list and the toctree, the same {doc}`...`
#    consistency check section 2 already applies to `users`
# ---------------------------------------------------------------------------
for page in crypttab filesystems localization; do
  if grep -q "^${page}\$" "$index_doc"; then
    # shellcheck disable=SC2016
    grep -q "{doc}\`${page}\`" "$index_doc" || {
      fail "$index_doc's toctree lists '$page' but the prose Guides list has no {doc}\`$page\` entry"
    }
  else
    fail "$index_doc's toctree does not list '$page' (GitHub issue #156)"
  fi
done

if [ "$fails" -eq 0 ]; then
  echo "OK: docs/modules.md, docs/index.md, docs/systemd.md, docs/guards.md, docs/crypttab.md, docs/filesystems.md, and docs/localization.md do not reassert stale absent/deferred claims contradicted by the real tree, guards.md still correctly scopes guard installation to the switch-loop proof image, crypttab.md correctly claims its real ubx rebuild/execute_domains wiring (GitHub issue #170), and filesystems.md/localization.md correctly claim their real parity-image wiring"
fi

exit "$fails"
