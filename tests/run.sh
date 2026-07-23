#!/usr/bin/env bash
# ubuntnix test harness entry point.
#
# Discovers and runs every executable test under tests/unit/ and, when
# UBX_E2E=1, tests/e2e/ (QEMU-based end-to-end tests; see tests/README.md).
# A test is any executable file; it passes iff it exits 0.
set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
export UBX_REPO_ROOT="$root"

suites=("$root/tests/unit")
[ "${UBX_E2E:-0}" = "1" ] && suites+=("$root/tests/e2e")

pass=0 fail=0 skip=0 failed=()
for suite in "${suites[@]}"; do
  [ -d "$suite" ] || continue
  while IFS= read -r t; do
    "$t"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      pass=$((pass + 1))
      echo "PASS ${t#"$root"/}"
    elif [ "$rc" -eq 77 ]; then
      # tests/README.md's documented e2e contract: "E2E tests may require
      # KVM and declare it by exiting 77 (skip) when unavailable." A skip
      # is neither a pass nor a failure -- it must not fail the suite (an
      # environment legitimately lacking qemu/KVM, like this project's own
      # dev harness, would otherwise never be able to green-light anything
      # that opts into UBX_E2E=1), but it also must not be silently
      # indistinguishable from a real pass in the summary below.
      skip=$((skip + 1))
      echo "SKIP ${t#"$root"/}"
    else
      fail=$((fail + 1))
      failed+=("${t#"$root"/}")
      echo "FAIL ${t#"$root"/}"
    fi
  done < <(find "$suite" -type f -perm -u+x | sort)
done

echo
echo "ran $((pass + fail + skip)) tests: $pass passed, $fail failed, $skip skipped"
if [ "$fail" -gt 0 ]; then
  printf 'failed: %s\n' "${failed[@]}"
  exit 1
fi
[ "$pass" -gt 0 ] || { echo "no tests found — refusing to pass an empty suite"; exit 1; }
