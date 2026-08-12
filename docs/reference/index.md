# Reference

```{admonition} Auto-generated
:class: note

The {doc}`options` page below is **auto-generated in CI** by
`docs/gen_reference.py`, which scans the current state of the tree (the
`nix/` directory, where every real `mkOption` declaration lives today) for
`mkOption` declarations and renders them as Markdown. It is regenerated on
every build and is never committed to the repository (see the repo-root
`.gitignore`), so it can never drift from the code — per `SPEC.md` G10.

Every domain today (networking, users, secrets, pro, archive, ...) is
expressed in `nix/*.nix` as an internal `lib.types.submodule` used for
structural validation, not yet wired to a single public
`options.ubuntnix.*` surface, so the paths on the generated page are
per-submodule field names rather than one unified `ubuntnix.*` namespace.
Once a public `options.ubuntnix.*` surface lands, this page's extractor
becomes a natural candidate to move from a textual regex scan to a
nix-eval-based one that can resolve real dotted paths, submodule nesting,
and merged descriptions.
```

This section holds reference material that is derived directly from the
tree rather than hand-written: today, the generated options and modules
page. Hand-written guides (installation, module authoring, operational
workflows) live one level up — see {doc}`../index`.

```{toctree}
:maxdepth: 2
:hidden:

options
```
