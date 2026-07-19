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
