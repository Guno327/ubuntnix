"""Sphinx configuration for the ubuntnix documentation site.

Built in CI (see .github/workflows/docs.yml) with:

    python3 docs/gen_reference.py
    sphinx-build -W --keep-going -b html docs docs/_build/html

`-W` promotes warnings to errors, so keep this configuration and all
content pages warning-clean. All content pages are MyST Markdown (.md),
parsed via myst_parser.
"""

project = "ubuntnix"
copyright = "2026, the ubuntnix project"
author = "the ubuntnix project"

extensions = [
    "myst_parser",
]

source_suffix = {
    ".md": "markdown",
}

master_doc = "index"

# ubuntnix is pre-M1 (see SPEC.md); no released version yet.
version = ""
release = ""

exclude_patterns = [
    "_build",
    "Thumbs.db",
    ".DS_Store",
]

# The generated options reference (docs/reference/options.md) is produced by
# gen_reference.py in CI and is not committed (see .gitignore); it is
# expected to exist by the time sphinx-build runs.

html_theme = "sphinx_rtd_theme"

html_theme_options = {
    "collapse_navigation": False,
    "navigation_depth": 3,
}

# Keep MyST to the plain CommonMark-plus-directives subset used by our
# content pages; no extra MyST syntax extensions are enabled since none of
# the current pages need them.
myst_enable_extensions = []
