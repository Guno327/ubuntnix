#!/usr/bin/env bash
# tests/unit/217-workflow-job-timeouts.sh -- every job in
# .github/workflows/ci.yml and .github/workflows/docs.yml must declare an
# explicit `timeout-minutes:`, for GitHub issue #150.
#
# WHY THIS TEST EXISTS: before issue #150, ci.yml declared 15 jobs (14 in
# ci.yml + the docs.yml build/deploy pair makes 16 total across both
# workflows) and NOT ONE of them set `timeout-minutes`. A job with no
# `timeout-minutes` inherits GitHub Actions' own default: 6 HOURS. That
# was not hypothetical -- on `main` @ 5c097d6, the "Archive resolution
# (apt solver, end-to-end)" job's "Re-resolve with unchanged inputs
# (run 2) and diff for byte-identity" step hung for ~80 minutes (this job
# normally finishes in ~8m) with nothing in the workflow file able to cut
# it off short of that undiscovered 6h ceiling. The run just sat
# `in_progress`, indistinguishable in GitHub's UI from healthy slowness,
# burning a runner and hiding the real failure behind a wall-clock wait no
# human was going to sit through.
#
# Issue #150's fix gives every job in both workflow files its own
# `timeout-minutes`, sized per-job from observed typical runtime with
# headroom (see each job's own comment in ci.yml/docs.yml for the specific
# number and reasoning). That fix is trivially easy to silently regress:
# a future job added to either file with no `timeout-minutes` line falls
# straight back to the undiscovered 6h default, and nothing else in this
# suite would ever notice -- shellcheck/nix/CI itself do not care whether
# a YAML workflow job has a timeout, and a workflow file with a missing
# key is still perfectly valid YAML. This test is the tripwire: it
# enumerates every job actually declared in each workflow file (not a
# hardcoded list of today's job names, so a NEW job added later without a
# timeout fails this test by construction) and fails, naming the specific
# offending workflow file + job, if any job lacks `timeout-minutes`.
#
# -- No PyYAML dependency ---------------------------------------------------
#
# PyYAML happens to be importable in some dev environments but nothing
# else in this tree imports it (grep the repo -- every other YAML-adjacent
# check here, e.g. tests/unit/181-networking-netplan-render.sh and
# tests/unit/204-cloudinit-coexistence-r12.sh, treats netplan/cloud-init
# YAML as opaque text via grep, never `import yaml`), and this issue's own
# brief is explicit: do not add a dependency on it being present. GitHub
# Actions workflow YAML is, in practice, a very restricted, consistently
# two-space-indented dialect (this repo's own two workflow files confirm
# that), so a job boundary can be found reliably with plain line-based
# parsing: a job starts at a line matching EXACTLY two leading spaces
# followed by an identifier and a colon (`^  [A-Za-z0-9_-]+:`), directly
# under the top-level `jobs:` key. Everything from one such line up to (but
# not including) the next one, or end of file, is that job's body; a
# `timeout-minutes:` key belongs to the job (not a nested step) only if it
# appears at exactly four leading spaces within that body, matching how
# every other job-level key (`name:`, `runs-on:`, `needs:`, `if:`, `steps:`,
# ...) is indented in both files today.
set -u

cd "$UBX_REPO_ROOT" || exit 1

fails=0
fail() {
  echo "FAIL: $1" >&2
  fails=$((fails + 1))
}

workflows=(
  ".github/workflows/ci.yml"
  ".github/workflows/docs.yml"
)

total_jobs=0

for wf in "${workflows[@]}"; do
  [ -f "$wf" ] || {
    fail "$wf does not exist"
    continue
  }

  # -- Locate the top-level `jobs:` key (column 0) -----------------------
  jobs_line="$(grep -n '^jobs:' "$wf" | head -1 | cut -d: -f1)"
  if [ -z "$jobs_line" ]; then
    fail "$wf has no top-level 'jobs:' key -- cannot enumerate its jobs"
    continue
  fi

  # -- Collect every job-name line (exactly two leading spaces, an
  #    identifier, a colon) after `jobs:`, plus the total line count, via a
  #    single python3 pass -- this is plain line/regex work, not YAML
  #    parsing, per this file's header on why PyYAML is deliberately not
  #    used here.
  result="$(python3 - "$wf" "$jobs_line" <<'PYEOF'
import re
import sys

path, jobs_line = sys.argv[1], int(sys.argv[2])
with open(path) as f:
    lines = f.readlines()

job_name_re = re.compile(r'^  ([A-Za-z0-9_-]+):\s*(#.*)?$')
timeout_re = re.compile(r'^    timeout-minutes:\s*\d+\s*$')

# 0-indexed line numbers strictly after the `jobs:` line itself.
starts = []
for i in range(jobs_line, len(lines)):
    m = job_name_re.match(lines[i])
    if m:
        starts.append((i, m.group(1)))

if not starts:
    print("NOJOBS")
    sys.exit(0)

missing = []
for idx, (start, name) in enumerate(starts):
    end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines)
    body = lines[start:end]
    if not any(timeout_re.match(line) for line in body):
        missing.append(name)

print("JOBS=%d" % len(starts))
for name in missing:
    print("MISSING=%s" % name)
PYEOF
)"

  if [ "$result" = "NOJOBS" ]; then
    fail "$wf: found 'jobs:' but no job entries under it -- enumeration logic may be broken, or the file is empty of jobs"
    continue
  fi

  job_count="$(echo "$result" | grep '^JOBS=' | cut -d= -f2)"
  total_jobs=$((total_jobs + job_count))

  while IFS= read -r line; do
    case "$line" in
      MISSING=*)
        job="${line#MISSING=}"
        fail "$wf: job '$job' has no timeout-minutes -- it inherits GitHub Actions' 6h default, exactly the gap issue #150 closed (an unrelated job on this same workflow hung ~80m undetected before this test existed)"
        ;;
    esac
  done <<<"$result"
done

# -- Sanity: this test is only meaningful if it actually found jobs to
#    check. If both workflow files somehow enumerated zero jobs, the loop
#    above already recorded a failure for each, so this only guards against
#    a change to $workflows itself leaving nothing to check at all.
if [ "$total_jobs" -eq 0 ] && [ "$fails" -eq 0 ]; then
  fail "no jobs were found across ${workflows[*]} -- nothing was actually checked"
fi

if [ "$fails" -eq 0 ]; then
  echo "OK: all $total_jobs jobs across ${workflows[*]} declare timeout-minutes"
fi

exit "$fails"
