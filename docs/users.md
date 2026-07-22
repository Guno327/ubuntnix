# Users: declaration, planning, execution

```{admonition} Implemented standalone (M2); activation wiring deferred
:class: note

`nix/users.nix` and `bin/ubx-users` exist in the repository as of milestone
**M2** (`SPEC.md` §4.3 "Users" row, §6, §7; issue #28): the declaration
surface, eval-time validation, JSON manifest rendering, the convergence
planner, and the thin command-sequence executor are all real and
unit-tested (`tests/unit/100-ubx-users-fixtures.sh` through
`105-ubx-users-cli.sh`). **Wiring `ubx-users execute`'s output into a real
running system's activation path is explicitly deferred**, the same way
issue #31's apt/dpkg/snap guards were unit-tested standalone with image
wiring left for later (see {doc}`guards`'s own "What is deferred"). Nothing
on this page describes a behavior you can observe on a running ubuntnix
system yet.
```

## Why this exists

`SPEC.md` §6 names `users` one of the closed, parity-audited primitives —
the level below anything a module could compose — and §4.3's switching
table gives it a downtime budget of **none**: `ubx rebuild switch` must be
able to converge a machine's accounts live, the same way it converges
`/etc` and systemd units. That requires exactly the split this page
documents: a pure **planner** that decides *what* needs to change by
diffing a declared set against real observed state, and a thin
**executor** that turns a decided plan into the *exact* commands that
apply it — kept as two separate steps so the planner (all of the actual
convergence logic: create/modify decisions, uid/gid allocation, membership
diffing, drift detection) is testable in complete isolation, with fixture
`passwd`/`group`/`shadow` files, no root, no live system, and no `nix`
binary required.

## Scope: what's in M2, what's deferred to M4

`SPEC.md` §11 M2 is explicit: *"users primitive (interim auth via SSH
keys — secret-backed passwords complete in M4)"*. Concretely:

- **In scope now**: group membership, login shell, home-directory
  creation (`createHome` + `home` path), uid strategy (explicit uid
  optional; a `system` flag selects the allocation range), and
  `authorizedKeys` — a plain list of SSH public key strings materialized to
  `~<user>/.ssh/authorized_keys`.
- **Out of scope until M4**: `hashedPasswordSecret` (`SPEC.md` §6's own
  example shows it) — sourcing a password hash from the secrets index
  needs `secrets/index.nix` (§8.1) to exist first. Declaring it here early
  would just be a field with nothing behind it.

## The declaration surface

`nix/users.nix` declares two submodule types — `ubuntnix.users.<name>` and
`ubuntnix.groups.<name>` (the latter for a standalone group declaration,
e.g. a custom group with an explicit gid that no user need reference) —
and validates a declared set against them via `lib.evalModules`, the same
machinery a real NixOS-style option uses. It is deliberately **not** yet
wired to an `options.ubuntnix.*` a machine flake evaluates directly — see
that file's own header — but the types (`flake.lib.users.userType`/
`groupType`) are exposed so a future machine-config evaluator can adopt
them as-is.

| Option | Type | Default | Meaning |
|---|---|---|---|
| `users.<name>.groups` | list of group name | `[]` | Supplementary (secondary) groups. |
| `users.<name>.shell` | absolute path | `/usr/bin/bash` | Login shell. |
| `users.<name>.createHome` | bool | `true` | `useradd -m` vs `-M`. |
| `users.<name>.home` | absolute path or `null` | `null` (→ `/home/<name>`) | Home directory. |
| `users.<name>.uid` | non-negative int or `null` | `null` (auto-allocate) | Explicit uid; always honored verbatim. |
| `users.<name>.system` | bool | `false` | Selects the system vs. normal allocation range for an unset `uid`. |
| `users.<name>.authorizedKeys` | list of key-line string | `[]` | SSH public keys, materialized to `~/.ssh/authorized_keys`. |
| `groups.<name>.gid` | non-negative int or `null` | `null` (auto-allocate) | Explicit gid; always honored verbatim. |
| `groups.<name>.system` | bool | `false` | Selects the system vs. normal allocation range for an unset `gid`. |

```nix
ubuntnix.users.gunnar = {
  groups = [ "sudo" "docker" ];
  shell = "/usr/bin/bash";
  authorizedKeys = [ "ssh-ed25519 AAAA... gunnar@laptop" ];
};
ubuntnix.groups.docker = { gid = 2000; };
```

`nix/users.nix`'s `mkManifest { users = ...; groups = ...; }` validates
this (throwing with *every* violation found, not just the first — mirrors
`nix/archive.nix`'s own `validate`) and `renderManifestJSON` flattens it to
the JSON manifest `bin/ubx-users` consumes:

```json
{
  "version": 1,
  "users": [
    { "name": "gunnar", "uid": null, "system": false,
      "shell": "/usr/bin/bash", "home": null, "createHome": true,
      "groups": ["docker", "sudo"],
      "authorizedKeys": ["ssh-ed25519 AAAA... gunnar@laptop"] }
  ],
  "groups": [
    { "name": "docker", "gid": 2000, "system": false }
  ]
}
```

`home`/`uid`/`gid` left `null` mean "the planner decides" — see below.
Arrays are always sorted by name: Nix attribute sets are internally kept
sorted, so this falls out of `builtins.attrNames` for free, without an
explicit sort call.

## The planner: `ubx-users plan`

```
ubx-users plan --manifest FILE --passwd FILE --group FILE --shadow FILE
               [--exceptions FILE] [--home-state FILE] [--out FILE]
```

A pure function of its inputs — the declared manifest, plus observed (or,
in tests, fixture) copies of `/etc/passwd`, `/etc/group`, `/etc/shadow` —
that emits a deterministic JSON **plan** on stdout (or `--out`), never
touching a real system. Exit 0 with an empty plan (`"empty": true`) on an
already-converged fixture; exit 1 iff `errors` is non-empty.

### What counts as "managed"

The planner only ever looks at two things: the declared users/groups
themselves, and the set of **required groups** — every declared group,
plus every group any declared user's `groups` list references. It never
inspects, reports on, or plans a change to any *other* passwd/group entry
(`SPEC.md` §7: "never plan changes to non-declared users or system
accounts not under management"). An ordinary base-system group nobody
declared and no declared user references — `adm`, say — is invisible to
the planner entirely, whatever its membership looks like.

### Errors vs. drift

A hard `errors` entry (nonzero exit) is reserved for exactly one class of
problem: **a declared, explicit uid or gid that a foreign (non-declared)
account already holds** — on create, or when converging an existing
declared user/group's explicit id toward a new value. This is
`SPEC.md`'s own acceptance line for this issue: *"declared uid already
taken by a foreign user → error, not silent adoption."* Nothing is ever
planned in this case; the run fails loudly instead.

Every other anomaly **within the managed domain** is `drift`:
informational, inspectable, never auto-corrected (`SPEC.md` §7's
converge-report posture) —

- `malformed_passwd_line` / `malformed_group_line` — a fixture/observed
  line that doesn't parse; excluded from further processing, not guessed
  at.
- `missing_shadow_entry` — a declared, already-existing user has no
  corresponding `/etc/shadow` line.
- `group_gid_mismatch` — a required group already exists with a gid that
  disagrees with an explicit declared one. Not auto-corrected: changing an
  existing group's gid is disruptive (orphaned file ownership) and is left
  for a human to resolve deliberately.
- `undeclared_group_member` — a required (managed) group's observed
  membership includes a user this manifest doesn't declare. Reported, but
  **never removed** — the planner only ever adds/removes *declared* users'
  own membership, never touches a foreign account's.

### uid/gid allocation

An explicit `uid`/`gid` is always honored verbatim. Left `null`, the
planner allocates the lowest free id in the range the `system` flag
selects, mirroring Debian/Ubuntu shadow-utils' own `/etc/login.defs`
defaults (unchanged on stock Ubuntu 24.04):

| | system range | normal range |
|---|---|---|
| uid | 100–999 | 1000–59999 |
| gid | 100–999 | 1000–59999 |

### Machine-local exceptions

`--exceptions FILE`: `{ "<user>": ["shell", "home", "uid", "groups",
"authorizedKeys"] }` — per-user field names the planner leaves alone even
if the declared value disagrees with what it observes. `SPEC.md` §4.2's
"machine-local mutable exceptions" concept, narrowed to this primitive's
own fields.

### authorizedKeys materialization

There is no such thing in `passwd`/`group`/`shadow` — `--home-state FILE`
(optional) is the one fixture input that isn't shadow-file-shaped:
`{ "<user>": ["key line", ...] }`, the authorized_keys lines *currently*
observed for that user. A plan entry (target `~/.ssh` at `0700`, target
`authorized_keys` at `0600`, full intended key content) is only emitted
when it differs from this — an already-materialized user with matching
observed content produces no plan entry at all, which is what makes the
"no-op on an already-converged fixture" case reachable even for a manifest
that declares keys.

## The executor: `ubx-users execute`

```
ubx-users execute --plan FILE [--format shell|json] [--out FILE]
```

Translates an already-computed plan into the **exact command sequence**
that converges a real system to it — `groupadd`/`useradd`/`usermod`/
`gpasswd`, plus the authorized_keys directory/file writes — using standard
Ubuntu tools' own semantics (shell changes go through `usermod -s`, the
administrative equivalent of interactive `chsh`). Fixed, deterministic
step order: `groups.create`, `users.create`, `users.modify`,
`membership.remove`, `membership.add`, `authorized_keys` — group creation
always precedes user creation, since a brand-new group a new user
references must exist before `useradd -G` can add them to it; membership
removals precede additions.

`--format shell` (default) emits a literal POSIX shell script (an
authorized_keys write is a real `cat > path <<'EOF' ... EOF` heredoc, not
a synthesized pseudo-command); `--format json` emits the same sequence as
structured `{"op": ..., ...}` steps for programmatic consumption.

**`execute` never runs anything itself.** This is a deliberate M2 scope
line, not an oversight — mirrors issue #31's guards, which were
unit-tested standalone with real-image wiring left for later (see
{doc}`guards`'s own "What is deferred"). The intended shape once
activation wiring lands: `ubx rebuild switch` computes a plan against the
running system's real `/etc/passwd`/`/etc/group`/`/etc/shadow`, and (after
surfacing it, per `SPEC.md` §7's converge-report posture) feeds it to
`ubx-users execute`, whose output actually runs as part of that switch —
live, no downtime, exactly `SPEC.md` §4.3's "Users | converge passwd/groups
state | none" row.

## Plan schema

```json
{
  "version": 1,
  "empty": false,
  "users": {
    "create": [
      { "name": "...", "uid": 1000, "system": false, "shell": "...",
        "home": "...", "createHome": true, "groups": ["..."] }
    ],
    "modify": [
      { "name": "...", "changes": {
          "shell": {"from": "...", "to": "..."},
          "home": {"from": "...", "to": "..."},
          "uid": {"from": 1000, "to": 1001}
      } }
    ]
  },
  "groups": { "create": [ { "name": "...", "gid": 2000, "system": false } ] },
  "membership": {
    "add": [ { "user": "...", "group": "..." } ],
    "remove": [ { "user": "...", "group": "..." } ]
  },
  "authorized_keys": [
    { "user": "...", "dir": ".../.ssh", "path": ".../.ssh/authorized_keys",
      "dir_mode": "0700", "file_mode": "0600", "keys": ["..."] }
  ],
  "drift": [ { "kind": "...", "...": "..." } ],
  "errors": [ "..." ]
}
```

`"empty"` is true iff `users`/`groups`/`membership`/`authorized_keys` are
all empty — the already-converged case. `errors` non-empty is the only
thing that makes `plan` exit non-zero; `drift` is always non-fatal.
