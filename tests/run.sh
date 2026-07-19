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

pass=0 fail=0 failed=()
for suite in "${suites[@]}"; do
  [ -d "$suite" ] || continue
  while IFS= read -r t; do
    if "$t"; then
      pass=$((pass + 1))
      echo "PASS ${t#"$root"/}"
    else
      fail=$((fail + 1))
      failed+=("${t#"$root"/}")
      echo "FAIL ${t#"$root"/}"
    fi
  done < <(find "$suite" -type f -perm -u+x | sort)
done

echo
echo "ran $((pass + fail)) tests: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
  printf 'failed: %s\n' "${failed[@]}"
  exit 1
fi
[ "$pass" -gt 0 ] || { echo "no tests found — refusing to pass an empty suite"; exit 1; }
