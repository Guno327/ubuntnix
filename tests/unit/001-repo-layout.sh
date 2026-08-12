#!/usr/bin/env bash
# The repository always carries its spec, license, and harness plumbing.
set -eu
cd "$UBX_REPO_ROOT"

for f in SPEC.md LICENSE README.md CONTRIBUTING.md tests/run.sh \
         .github/workflows/ci.yml; do
  [ -e "$f" ] || { echo "missing required file: $f"; exit 1; }
done

grep -q "Decision ledger" SPEC.md || {
  echo "SPEC.md lost its decision ledger"; exit 1;
}

# A test committed without the executable bit is silently never run by
# tests/run.sh's `find ... -type f -perm -u+x` discovery, and the suite
# still greens (GitHub issue #154) -- catch it here instead.
for d in tests/unit tests/e2e; do
  [ -d "$d" ] || continue
  non_exec=$(find "$d" -type f ! -perm -u+x)
  [ -z "$non_exec" ] || {
    echo "non-executable file(s) under $d (never discovered by tests/run.sh):";
    echo "$non_exec";
    exit 1;
  }
done

# Tests are named NNN-description "to keep ordering readable"
# (tests/README.md); two tests sharing an NNN prefix defeats that and is
# an easy collision to introduce by accident (GitHub issue #154).
for d in tests/unit tests/e2e; do
  [ -d "$d" ] || continue
  dups=$(find "$d" -maxdepth 1 -type f -name '[0-9][0-9][0-9]-*' -printf '%f\n' \
           | cut -c1-3 | sort | uniq -d)
  [ -z "$dups" ] || {
    echo "duplicate NNN test-name prefix(es) under $d: $dups";
    exit 1;
  }
done
