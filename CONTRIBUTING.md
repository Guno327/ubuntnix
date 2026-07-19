# Contributing

ubuntnix is developed by AI agents (a PM integrating work from parallel
Engineer agents) under human ownership. The conventions below bind agents
and human contributors equally.

## Workflow

- **GitHub is the source of truth.** Every work item is an issue with scope
  and acceptance criteria before code exists. PRs reference their issue.
- **`main` is never committed to directly.** All work flows through feature
  branches (`feat/…`, `fix/…`, `test/…`, `chore/…`) merged by PR after CI
  passes.
- **Tests first.** Write failing tests from the issue's acceptance criteria,
  then implement against them. PRs without tests do not merge unless the
  issue explicitly declares the change untestable and why.
- A red `main` pre-empts all feature work.

## Commits

- [Conventional Commits](https://www.conventionalcommits.org/): `feat:`,
  `fix:`, `docs:`, `test:`, `ci:`, `chore:`, `refactor:`.
- Small and coherent; AI-authored commits carry a `Co-Authored-By:` trailer
  naming the model.

## Versioning

Semantic Versioning; releases cut via GitHub Releases with tags `vX.Y.Z`.

## Design authority

`SPEC.md` is the specification and decision ledger. Changes that conflict
with it require amending the spec (by PR) first — see its §14 ledger for
how decisions are recorded and superseded.
