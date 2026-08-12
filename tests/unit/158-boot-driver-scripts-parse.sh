#!/usr/bin/env bash
# tests/unit/158-boot-driver-scripts-parse.sh —
# every `*DriverScript` in nix/boot.nix must still be VALID BASH after Nix's
# own indented-string (`''...''`) dedent is applied.
#
# Why this exists (GitHub issue #153). Nix dedents an indented string by the
# MINIMUM indentation across all of its non-blank lines. The driver scripts
# rely on that: a `<<'MARKER'` heredoc terminator only closes the heredoc when
# it sits at column 0 of the *generated* script, so the scripts deliberately
# indent heredoc bodies and their terminators LESS than the surrounding shell
# (4 spaces vs 8) — after a dedent of 4 the terminator lands at column 0.
#
# That makes the dedent amount a shared, whole-string invariant, and it is
# fragile in a way nothing else caught: a single new line added at column 0
# anywhere in the string drops the minimum indentation to 0, so Nix stops
# dedenting entirely, EVERY existing heredoc terminator stays indented, the
# first such heredoc swallows the rest of the file, and the script becomes
# unparseable. Nix itself still evaluates happily (it is just a string), the
# flake check passes, the image builds, and the breakage only surfaces as a
# QEMU e2e that boots to a login prompt and then times out with a completely
# silent driver — an expensive, hard-to-read failure. Exactly that happened
# when the M4 assertions gained a heredoc whose terminator was written at
# column 0.
#
# So: reproduce Nix's dedent here and run `bash -n` over the result. Nix
# interpolations (`${...}`) are replaced with a placeholder token first, since
# their values are not knowable statically — this checks the script's SHELL
# SYNTAX (quoting, heredocs, block structure), which is precisely the class of
# breakage described above.
set -u

cd "$UBX_REPO_ROOT" || exit 1

boot_nix="$UBX_REPO_ROOT/nix/boot.nix"
[ -f "$boot_nix" ] || { echo "FAIL: $boot_nix does not exist" >&2; exit 1; }

# Pick a bash we can actually exec. Some sandboxes put a non-executable bash
# ahead of the real one on PATH (and $BASH may itself be that one), which would
# fail for reasons unrelated to the scripts under test.
bash_bin=""
for candidate in "${BASH:-}" /usr/bin/bash /bin/bash bash; do
  [ -n "$candidate" ] || continue
  if "$candidate" -c ':' > /dev/null 2>&1; then
    bash_bin="$candidate"
    break
  fi
done
if [ -z "$bash_bin" ]; then
  echo "SKIP: no executable bash available to syntax-check the driver scripts" >&2
  exit 77
fi

work="$(mktemp -d)"
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# Extract each `<name>DriverScript = ''...''` from nix/boot.nix, applying Nix's
# indented-string semantics, and write each to $work/<name>.sh. Prints one
# "<name> <dedent>" line per script found.
BOOT_NIX="$boot_nix" OUT_DIR="$work" python3 > "$work/index.txt" << 'UBX_EXTRACT_PY_EOF'
import os
import re
import sys

src = open(os.environ["BOOT_NIX"], encoding="utf-8").read()
out_dir = os.environ["OUT_DIR"]

found = 0
for m in re.finditer(r"^  (\w*DriverScript) = ''$", src, re.M):
    name = m.group(1)
    i = m.end()  # just after the opening ''
    # Find the closing '' — skipping Nix's escapes: ''${ (literal ${) and ''' (literal '').
    j = i
    while True:
        j = src.find("''", j)
        if j == -1:
            print(f"UNTERMINATED {name}", file=sys.stderr)
            sys.exit(1)
        if src[j:j + 3] in ("''$", "'''"):
            j += 3
            continue
        break
    body = src[i:j]

    lines = body.split("\n")
    if lines and lines[0] == "":
        lines = lines[1:]
    indents = [len(l) - len(l.lstrip(" ")) for l in lines if l.strip()]
    dedent = min(indents) if indents else 0
    lines = [l[dedent:] if l.strip() else "" for l in lines]
    text = "\n".join(lines)

    # Nix escapes, then blank out interpolations (values are not static).
    text = text.replace("''$", "$").replace("'''", "''")
    result = []
    k = 0
    while k < len(text):
        if text[k:k + 2] == "${":
            depth = 1
            k += 2
            while k < len(text) and depth:
                if text[k] == "{":
                    depth += 1
                elif text[k] == "}":
                    depth -= 1
                k += 1
            result.append("NIXINTERP")
        else:
            result.append(text[k])
            k += 1
    text = "".join(result)

    with open(os.path.join(out_dir, name + ".sh"), "w", encoding="utf-8") as f:
        f.write(text)
    print(f"{name} {dedent}")
    found += 1

if not found:
    print("NO DRIVER SCRIPTS FOUND", file=sys.stderr)
    sys.exit(1)
UBX_EXTRACT_PY_EOF

extract_rc=$?
if [ "$extract_rc" -ne 0 ]; then
  echo "FAIL: could not extract driver scripts from nix/boot.nix (exit $extract_rc)" >&2
  exit 1
fi

fails=0
count=0
while read -r name dedent; do
  [ -n "$name" ] || continue
  count=$((count + 1))
  script="$work/$name.sh"

  if ! err="$("$bash_bin" -n "$script" 2>&1)"; then
    echo "FAIL: $name is not valid bash after Nix's dedent (dedent=$dedent):" >&2
    while IFS= read -r errline; do
      printf '    %s\n' "$errline" >&2
    done <<< "$err"
    echo "    hint: a line at column 0 inside the ''...'' string drops the dedent to 0," >&2
    echo "    which leaves every heredoc terminator indented and unparseable." >&2
    fails=$((fails + 1))
    continue
  fi

  # A heredoc terminator that is still indented in the GENERATED script never
  # closes its heredoc. bash -n catches that as an EOF error above, but check
  # it explicitly so the diagnosis is obvious rather than inferred.
  while read -r marker; do
    [ -n "$marker" ] || continue
    if ! grep -qx "$marker" "$script"; then
      echo "FAIL: $name: heredoc terminator '$marker' never appears at column 0 of the generated script" >&2
      fails=$((fails + 1))
    fi
  done < <(grep -oE "<<'[A-Za-z_][A-Za-z0-9_]*'" "$script" | sed "s/^<<'//; s/'$//" | sort -u)
done < "$work/index.txt"

if [ "$count" -eq 0 ]; then
  echo "FAIL: no *DriverScript strings were extracted from nix/boot.nix" >&2
  exit 1
fi

if [ "$fails" -eq 0 ]; then
  echo "OK: all $count *DriverScript string(s) in nix/boot.nix parse as bash after Nix's indented-string dedent, with every heredoc terminator landing at column 0"
fi

exit "$fails"
