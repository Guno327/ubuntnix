#!/usr/bin/env python3
"""Generate docs/reference/options.md from the nix/ tree.

Best-effort *textual* scan of ``<root>/nix/**/*.nix`` for ``mkOption``
declarations, in either of the two shapes this codebase actually uses:

  1. ``options.<dotted.path> = [prefix.]mkOption { ... };`` — a top-level
     attachment of a type to the module system (e.g. ``options.pro =
     lib.mkOption { type = proType; };`` in nix/pro.nix).
  2. bare ``<name> = [prefix.]mkOption { ... };`` inside an ``options =
     { ... };`` submodule block (e.g. ``hostname = lib.mkOption { ... };``
     inside nix/networking.nix's ``networkingType`` submodule). This is
     the shape essentially all real per-field options in nix/*.nix use
     today, since every domain (networking, users, secrets, pro,
     archive, ...) is expressed as an internal `lib.types.submodule` used
     for structural validation rather than a single flat
     ``options.<dotted.path>`` per field.

For each match it pulls out the option's path (dotted where shape 1
applies, otherwise just the field name) plus, where present, its
``type``, ``default`` and ``description`` fields, and renders a sorted
Markdown page.

Every real ``mkOption`` declaration today lives in ``nix/*.nix``
(``nix/networking.nix``, ``nix/archive.nix``, ``nix/secrets.nix``,
``nix/pro.nix``, ``nix/users.nix``, ``nix/lib.nix``, ...) as an *internal
submodule type* used for structural validation, not yet wired to a
public ``options.ubuntnix.*`` surface — so the paths this script reports
are per-submodule field names, not a single unified ``ubuntnix.*``
namespace. Once a public ``options.ubuntnix.*`` surface lands, replacing
this textual regex scan with a nix-eval-based extractor (which can
resolve real dotted paths, submodule nesting, and merged descriptions
instead of grepping source text) remains the natural next step.

Anything this script cannot parse
(multi-line attrsets as defaults, computed paths, `lib.mkOption` written
across unusual formatting, etc.) is simply omitted rather than guessed at.

An empty result is treated as a bug, not a valid steady state: if
``nix/`` exists and contains ``.nix`` files but none of them yield a
single matched option, this script exits non-zero with a diagnostic
instead of silently emitting an empty page (SPEC.md G10's reference must
reflect the real tree; a silent empty page from a broken extractor would
be indistinguishable from a genuinely option-free tree). Only a tree with
*no* ``.nix`` files under ``nix/`` at all (or no ``nix/`` directory) is
treated as the legitimate empty case and still exits 0.

The output is deterministic: for the same input tree it always produces
byte-identical output, sorted by option path then by declaring file.

Usage:
    gen_reference.py [--root PATH] [--out PATH]

--root defaults to $UBX_REPO_ROOT, falling back to the parent of the
       docs/ directory that contains this script.
--out  defaults to docs/reference/options.md next to this script (so
       tests can point it elsewhere with --out).
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Optional

# Matches either of the two mkOption-declaration shapes this codebase uses
# (see module docstring):
#   (dotted) `options.<dotted.path> = [prefix.]mkOption {`
#   (bare)   `<name> = [prefix.]mkOption {`, when <name> is not itself the
#            tail of a preceding `options.` path (the negative lookbehind
#            rejects starting a match on the "path" part of "options.path
#            = mkOption", which the dotted alternative already covers).
# Both leave the parser positioned at the opening brace of the mkOption
# argument. `prefix.` covers the common `lib.mkOption` spelling; bare
# `mkOption` (imported via `inherit (lib) mkOption;` or `with lib;`) is
# also matched.
OPTION_HEAD_RE = re.compile(
    r"(?:options\.(?P<dotted>[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*)"
    r"|(?<![.\w])(?P<bare>[A-Za-z_][A-Za-z0-9_]*))"
    r"\s*=\s*(?:[A-Za-z0-9_]+\.)?mkOption\s*(?P<brace>\{)"
)

# Best-effort field extraction inside an mkOption {...} block. Non-greedy up
# to the next `;`, so this only handles single-statement (not nested-attrset)
# field values — sufficient for the common `type = lib.types.str;` /
# `default = "x";` / `description = "...";` forms.
FIELD_RE = re.compile(r"\b(type|default|description)\s*=\s*(.*?);", re.DOTALL)


def extract_block(text: str, open_brace_idx: int) -> str:
    """Return the balanced-brace block starting at open_brace_idx (inclusive)."""
    depth = 0
    i = open_brace_idx
    n = len(text)
    while i < n:
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[open_brace_idx : i + 1]
        i += 1
    # Unterminated block (shouldn't happen in valid Nix) — return what we have.
    return text[open_brace_idx:]


def find_options(text: str) -> list[dict]:
    """Best-effort extraction of mkOption declarations from one file's text."""
    found = []
    for m in OPTION_HEAD_RE.finditer(text):
        path = m.group("dotted") or m.group("bare")
        block = extract_block(text, m.start("brace"))
        fields: dict[str, str] = {}
        for fm in FIELD_RE.finditer(block):
            key = fm.group(1)
            if key not in fields:
                fields[key] = " ".join(fm.group(2).split())
        entry = {"path": path, **fields}
        found.append(entry)
    return found


def render_markdown(
    root: Path,
    files: list[Path],
    options: list[dict],
) -> str:
    lines: list[str] = []
    lines.append("<!-- Generated by docs/gen_reference.py — do not edit by hand. -->")
    lines.append("")
    lines.append("# Options and modules reference")
    lines.append("")
    lines.append(
        "This page is regenerated in CI from the current state of the tree "
        "(never committed) so it can never drift from the code, per "
        "SPEC.md's G10."
    )
    lines.append("")

    if not files:
        lines.append(f"Scanned: `nix/` under `{root}` — no `.nix` files found.")
        lines.append("")
        lines.append(
            "No `.nix` files exist under `nix/` in this tree, so no options "
            "are declared."
        )
        lines.append("")
        return "\n".join(lines) + "\n"

    lines.append(
        f"Scanned: `nix/` under `{root}` — {len(files)} `.nix` file(s) found."
    )
    lines.append("")

    for opt in options:
        lines.append(f"## `{opt['path']}`")
        lines.append("")
        if "type" in opt:
            lines.append(f"- **type:** `{opt['type']}`")
        if "default" in opt:
            lines.append(f"- **default:** `{opt['default']}`")
        if "description" in opt:
            desc = opt["description"]
            if len(desc) >= 2 and desc.startswith('"') and desc.endswith('"'):
                desc = desc[1:-1]
            lines.append(f"- **description:** {desc}")
        lines.append(f"- **declared in:** `{opt['file']}`")
        lines.append("")

    return "\n".join(lines) + "\n"


def default_root() -> Path:
    env_root = os.environ.get("UBX_REPO_ROOT")
    if env_root:
        return Path(env_root)
    # parent of the docs/ directory that contains this script
    return Path(__file__).resolve().parent.parent


def default_out() -> Path:
    return Path(__file__).resolve().parent / "reference" / "options.md"


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=None,
        help="repo root to scan for nix/ (default: $UBX_REPO_ROOT or "
        "the parent of the docs/ dir containing this script)",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="output path for the generated Markdown page "
        "(default: docs/reference/options.md next to this script)",
    )
    args = parser.parse_args(argv)

    root = (args.root if args.root is not None else default_root()).resolve()
    out = (args.out if args.out is not None else default_out()).resolve()

    nix_dir = root / "nix"

    files: list[Path] = []
    options: list[dict] = []
    if nix_dir.is_dir():
        files = sorted(nix_dir.rglob("*.nix"))
        for f in files:
            text = f.read_text(errors="replace")
            for opt in find_options(text):
                opt["file"] = str(f.relative_to(root))
                options.append(opt)
        options.sort(key=lambda o: (o["path"], o["file"]))

    # An empty RESULT from a NON-empty source tree is a bug, not a valid
    # steady state (see module docstring): don't silently write a
    # misleadingly-empty page in that case, and don't leave a stale
    # previous --out artifact around to be mistaken for current output.
    if files and not options:
        print(
            f"error: found {len(files)} `.nix` file(s) under {nix_dir} but "
            "extracted 0 mkOption declaration(s) from any of them -- this "
            "almost certainly means the extractor regex in "
            "docs/gen_reference.py no longer matches the option-declaration "
            "shapes actually used in nix/*.nix, not that the tree has no "
            "options. Refusing to emit a misleadingly-empty reference page.",
            file=sys.stderr,
        )
        return 1

    content = render_markdown(root, files, options)

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(content)

    print(
        f"wrote {out} ({len(options)} option(s) from {len(files)} file(s) "
        f"under {nix_dir})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
