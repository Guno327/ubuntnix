# Ubuntu Pro: declarative attach, esm-apps, and Livepatch

```{admonition} Planner/executor implemented (M4); a real attach needs a real token (tracked separately)
:class: note

`nix/pro.nix`, `bin/ubx-pro`, and `bin/ubx-pro-apply` all exist in the
repository as of milestone **M4** (`SPEC.md` §8.2 "Ubuntu Pro", §5, §11 M4;
GitHub issue #82): the declaration surface, JSON manifest, convergence
planner, and convergence executor described below are all real and
unit-tested (`tests/unit/170` through `174`). `bin/ubx-pro`/
`bin/ubx-pro-apply` ARE wired into `ubx rebuild switch|test|boot`,
`rollback`, and `diff` — mirroring `bin/ubx-secrets`/`bin/ubx-secrets-apply`'s
own wiring (issue #78) almost exactly, with one deliberate ordering rule:
the pro domain runs **immediately after** the secrets domain in
`execute_domains`, because a real `pro attach` reads the token off the
secrets domain's own freshly-materialized `/run/secrets/<name>` file — see
`bin/ubx`'s own `execute_domains` header. What is demonstrably **not**
exercised on a real machine yet: this dev/CI harness has no real `pro`
client and no real Ubuntu Pro subscription token at all, so every test here
runs `bin/ubx-pro-apply` behind a small recording **mock** `pro` binary
(`--pro-bin`) instead of the real one — a genuinely live attach against a
real, owned subscription is tracked separately as GitHub issue #87
("needs-owner"). This plumbing does not block on that: a missing real `pro`
client, or a not-yet-materialized token, is always skipped cleanly (never
failed) — see `bin/ubx-pro-apply`'s own header, "Availability".
```

## Why this exists

`SPEC.md` §2's G9 goal states it plainly: *"Ubuntu Pro is required (free
personal tokens exist, so this does not gate adoption): esm-apps patch
coverage for universe, Livepatch for the kernel."* §8.2 adds: *"Attachment
happens at install time... and the token is managed thereafter through the
secrets mechanism; Pro enablement itself is declarative,"* and *"Livepatch
enabled by default."* This page is that declarative half: a machine
declares `ubuntnix.pro.enable` (plus which of the two services it wants) and
this project's own planner/executor pair converges a real, running
system to match it — the exact "none" downtime "converge via API" row
`SPEC.md` §4.3's switching table already establishes for every other live
domain (etc, systemd units, secrets, snaps).

## The declaration surface

`nix/pro.nix` declares `ubuntnix.pro`:

```nix
ubuntnix.pro = {
  enable = true;               # default false
  tokenSecret = "proToken";    # default "proToken" -- a secrets.<name>
                                # reference (SPEC.md §8.1's own example
                                # secret), NEVER the token itself
  esmApps.enable = true;       # default true WHEN pro.enable (SPEC.md §5/§9)
  livepatch.enable = true;     # default true WHEN pro.enable (SPEC.md §8.2/§8.3)
};
```

`tokenSecret` is a plain secret **name** — a reference into the secrets
primitive `nix/secrets.nix`/`bin/ubx-secrets`/`bin/ubx-secrets-apply` already
establish (issue #78), exactly `SPEC.md` §8.1's own `secrets.<name>` shape.
It is typed as a bare identifier string (`lib.types.strMatching`), not a
path — there is structurally nothing in this option capable of holding a
token value. `esmApps.enable`/`livepatch.enable` both default to whatever
`enable` itself is set to: attaching to Pro at all, with neither service
turned on, would defeat the point (`SPEC.md` §5/§9's own default security
posture), so opting in to Pro opts in to both services unless a declaration
explicitly turns one back off.

## THE ABSOLUTE INVARIANT: the token value never enters this pipeline

`SPEC.md` §8.1's "no secret material ever enters a store object" applies
here at every single stage:

- `nix/pro.nix`'s rendered manifest carries only `tokenSecretPath` — a
  plain, deterministic **path string** derived from the declared name
  (`"/run/secrets/" + tokenSecret`), computed without reading, forcing, or
  touching a real secrets index or real secret bytes at all.
- `bin/ubx-pro`'s planner (`plan`) never reads a token's bytes either — its
  emitted `attach` action carries only `tokenSecretName` (the bare name,
  re-derived from that path's basename), never a value.
- `bin/ubx-pro-apply` (the executor) is the **only** place real token bytes
  are ever read, and only at real `--apply` time, off the materialized
  `/run/secrets/<name>` file — mirroring `bin/ubx-secrets-apply`'s own
  `ubx_secrets_render_env` seam (see that script's header, "Env-file
  rendering: value never appears in the printed command list"). Even its
  own `--dry-run` output never embeds the token — only the resolved file's
  *path* is printed, never its *content*.

`tests/unit/171-pro-purity-guard.sh` is the machine-checked half of this —
mirrors `tests/unit/160-secrets-purity-guard.sh`'s own role for
`nix/secrets.nix`: it greps `nix/pro.nix`'s own code for anything that looks
like it reads real secret material, and asserts a real token value planted
in a test fixture never surfaces in a plan or in `bin/ubx-pro-apply`'s
dry-run output.

## The manifest schema

`renderManifestJSON (mkManifest declared)` produces:

```json
{
  "version": 1,
  "enable": true,
  "tokenSecretPath": "/run/secrets/proToken",
  "esmApps": true,
  "livepatch": true
}
```

`esmApps`/`livepatch` are already gated by `enable` at render time (both
`false` whenever `enable` is `false`) — a disabled-Pro manifest is never
ambiguous about whether a service is "declared off" vs. "irrelevant because
Pro itself is off."

## The convergence planner: `bin/ubx-pro plan`

```
ubx-pro plan --manifest FILE --observed FILE [--out FILE]
```

A pure function of its two inputs — the declared manifest above, plus an
**observed** state document:

```json
{
  "version": 1,
  "attached": false,
  "services": { "esm-apps": "enabled", "livepatch": "disabled" }
}
```

— that produces a deterministic JSON **plan**:

```json
{
  "version": 1,
  "empty": false,
  "actions": [
    { "op": "attach", "tokenSecretName": "proToken" },
    { "op": "enable", "service": "esm-apps" },
    { "op": "enable", "service": "livepatch" }
  ]
}
```

Actions are always emitted in a **fixed order** — attach, then
enable/disable in declaration order (esm-apps, then livepatch) — mirroring
`bin/ubx-snap`'s own "ack before install before hold" fixed-order posture. A
declared `enable: false` while currently attached plans a lone `detach`
action instead, with **no** separate per-service disable actions alongside
it (detaching already tears every Pro service down with it). Re-planning
against an already-converged observed state — including the same observed
state `bin/ubx-pro observe` would produce from a real, fully-converged `pro
status` — is always a real no-op (`"empty": true`, `"actions": []`):
`tests/unit/172-ubx-pro-plan.sh` exercises attach, both services' enable/
disable, detach, and idempotent re-planning against a fixture `pro status`
end to end.

### `bin/ubx-pro observe`

```
ubx-pro observe [--status-file FILE] [--pro-bin CMD] [--out FILE]
```

Reads a real (or, in every test, a fixture) `pro status --format json`
document and extracts the subset this planner cares about (`attached`, plus
`esm-apps`/`livepatch`'s own `status` fields — every other reported service,
e.g. `esm-infra`/`fips`, is simply ignored, since this project declares
convergence for only these two, `SPEC.md` §5/§8.2). `--status-file` is what
every unit test uses (zero root/network/`pro` binary needed); without it,
`observe` shells out to `<pro-bin> status --format json` instead — the one
codepath this test suite never exercises, mirroring
`bin/ubx-snap-apply`'s own "the literal default is never exercised by
tests/unit/" precedent for its own `UBX_SNAP_CMD` seam.

## The convergence executor: `bin/ubx-pro-apply`

```
ubx-pro-apply --plan FILE [--run-secrets-dir DIR] [--secret-name NAME] [--pro-bin CMD] [--apply | --dry-run]
```

Consumes a plan `bin/ubx-pro plan` emits and issues the corresponding `pro`
calls, in the plan's own order, through the injectable `--pro-bin`/
`UBX_PRO_CMD` seam — the same `UBX_*_CMD` convention `bin/ubx-snap-apply`'s
own `UBX_SNAP_CMD` already establishes. `--run-secrets-dir` + the plan's own
`tokenSecretName` are how an `attach` action's real token path is
**reconstructed**, never trusted verbatim off the plan — exactly
`bin/ubx-secrets-apply`'s own "why paths are RECONSTRUCTED, not read
verbatim off the plan" posture, and exactly what lets `--run-secrets-dir`
point at a temp directory in tests.

### Availability: skip cleanly, never fail

Unlike `bin/ubx-secrets-apply`/`bin/ubx-snap-apply` (which always assume
their own backing tool exists), a real `--apply` here is gated behind two
independent, best-effort checks — both skip **cleanly** (a named message to
stderr, exit 0) rather than failing the whole convergence:

1. **a real `pro` client on `PATH`** — this dev/CI harness genuinely has
   none; GitHub issue #87 (needs-owner) tracks getting a real one attached
   with a real subscription. This plumbing must not block on that.
2. **the attach token actually materialized** at
   `--run-secrets-dir/<tokenSecretName>` — a plan can legitimately be
   computed and applied before the secrets domain (which runs immediately
   before this one in `bin/ubx`'s own `execute_domains`) has actually
   written it yet.

`--dry-run` (the default) always prints every action regardless of either
check, with a `NOTE` appended when one would have caused a real `--apply`
run to skip something.

## Wiring into `ubx rebuild`/`rollback`/`diff`

`bin/ubx`'s `plan_domains` computes the pro domain's plan the same shape
every other "none"-downtime domain uses: an old/new declared manifest (via
`--pro-manifest`, threaded through the same generation-sidecar mechanism
`--systemd-ref`/`--secrets-manifest` already use — see
`bin/ubx-rebuild-lib`'s own header, "The systemd-manifest sidecar") plus an
observed-state default **synthesized** from the OLD generation's own
declared manifest (assuming it is already fully converged — override with
`--pro-observed`, or a real `bin/ubx-pro observe` call). `report_domains`
prints it last, after the secrets domain (the same append-at-the-end
convention this project's domain list already follows).

`execute_domains` applies it through `bin/ubx-pro-apply`, `--apply`-gated
exactly like the secrets block immediately above it — `switch`/`test` both
apply for real when `--apply` is given (there is no snap-purge-style "test
never really applies" carve-out: `bin/ubx-pro-apply`'s own clean-skip
posture already makes a `test` run always safe to retry/roll back from),
`--dry-run` (the default) only prints. `--pro-bin` threads the same
mock-vs-real seam all the way from `ubx rebuild`'s own command line down to
`bin/ubx-pro-apply` itself. `tests/unit/174-ubx-rebuild-pro-wiring.sh`
exercises `switch`/`test`/`boot`/`rollback`/`diff` end to end behind a mock
`pro` client, including proving the ordering requirement directly: the
mock's very first recorded call is a real `attach` reading the token the
secrets block, running immediately before it, just materialized.

## Install-time attach: `bin/ubx-pro-token`

`SPEC.md` §10 installer step 4: *"prompts for an Ubuntu Pro token
(required; free personal tokens), stores it via the secrets mechanism, and
attaches"* (GitHub issue #115). This is the ONE-SHOT install-time step that
gets a real token into a freshly-initialized `/flake` and drives the very
first real attach — distinct from, and running strictly before, the
declarative `ubuntnix.pro.*`/`bin/ubx-pro plan`/`bin/ubx-pro-apply`
convergence loop described above (which only starts converging once the
machine's first real generation, with `ubuntnix.pro.enable` actually set,
builds and switches).

```
ubx-pro-token [--flake DIR] (--token VALUE | --token-file FILE)
              [--secret-name NAME] [--run-secrets-dir DIR]
              [--pro-bin CMD] [--dry-run]
```

It composes, rather than reimplements, three already-landed mechanisms:

- `secrets/index.nix`'s own `proToken = { src = ./pro-token; ... }`
  declaration ({doc}`secrets`, issue #79) names exactly where the token's
  bytes belong — `<flake>/secrets/pro-token` — which `bin/ubx-flake-init`
  (issue #114, this page's sibling {doc}`install` step 3) has already
  materialized the git-crypt-encrypting template for by the time this step
  runs;
- `secrets/.gitattributes`' `*` rule is what actually encrypts
  `secrets/pro-token` at rest the moment this script `git add`s and commits
  it — `ubx-pro-token` never touches git-crypt/GPG machinery itself, it
  relies entirely on step 3 having already run;
- `bin/ubx-pro-apply`'s own real, tested `attach` codepath (above) is the
  only place a `pro attach` call is actually issued — `ubx-pro-token` hands
  it a minimal, hand-built one-action plan (`{"op": "attach",
  "tokenSecretName": ...}`) rather than going through `bin/ubx-pro plan`,
  because that planner's own input (a manifest rendered from a live,
  evaluated `ubuntnix.pro.*` configuration) does not exist yet at this
  point in a real install — nothing has been built or switched to.

Since `bin/ubx-secrets-apply` has not run yet either at this installer
step, `ubx-pro-token` also materializes `--run-secrets-dir/<secret-name>`
(default `/run/secrets/proToken`) itself, with the same `0400` mode
`secrets/index.nix`'s own `proToken.mode` declares, purely so
`bin/ubx-pro-apply`'s existing attach codepath has a file to read from in
the one place it already knows to look.

Exactly this page's own "THE ABSOLUTE INVARIANT": the token value never
appears in this script's own stdout/stderr, in any printed command, or
anywhere in the git object store except as git-crypt ciphertext —
`tests/unit/206-ubx-pro-token.sh` proves the committed blob is not the
plaintext token, greps the *entire* git object store for the raw value,
and proves a real attach call (behind the same `--pro-bin` mock seam
`bin/ubx-pro-apply` already establishes) actually fires with the stored
token. Safe to re-run: an unchanged token is a real no-op commit; a
different token (rotation) overwrites and re-commits, and still drives a
fresh attach call each time — this script's own job is "make sure it's
stored and attached," not "was it already attached" (that distinction is
`bin/ubx-pro plan`'s job, once the declarative loop above takes over).

See {doc}`secrets` for the underlying secrets primitive this page's token
reference sources from, and {doc}`ubx` for the shared domain-plan/
`execute_domains` orchestration concepts this page's wiring section
assumes.
