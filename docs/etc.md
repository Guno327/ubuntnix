# The generated `/etc`

```{admonition} Partially implemented (M2, issue #26): compile + plan only
:class: note

`nix/etc.nix` and `bin/ubx-etc` exist in the repository as of milestone
**M2** (`SPEC.md` §4.2 "generated `/etc`", §4.3 switching-table row 1;
issue #26) and everything described below is real: declared entries
compile to a content-addressed tree plus a JSON manifest, the machine-
local mutable exceptions are enumerated and enforced, and `bin/ubx-etc
plan` computes a deterministic create/update/remove/drift diff against
observed system state. Nothing here yet **applies** that plan to a real
`/etc` — no file is ever written, chowned, chmod'd, or deleted by
anything on this page. That executor (`bin/ubx-etc-apply`), and the `ubx
rebuild` verb that wires it into an actual switch, are separate, later
work (`bin/ubx-generations`' own header: "Activation ... is `ubx` verb
work for a later issue").
```

## The declaration surface

A module (once real module evaluation exists — see {doc}`modules`) will
declare files under `/etc` with the `ubuntnix.etc` primitive:

```nix
ubuntnix.etc."ssh/sshd_config" = {
  text = ''
    PermitRootLogin no
  '';
  # source = ./files/sshd_config;   # exactly one of text/source
  owner = "root";                    # default "root"
  group = "root";                    # default "root"
  mode  = "0644";                    # default "0644"
};
```

The attribute name is a path **relative to `/etc`** (`"ssh/sshd_config"`,
never `"/etc/ssh/sshd_config"` or a leading `/`). Every declared entry is
validated at evaluation time (`nix/etc.nix`'s `validate`): the path must
be relative with no `.`/`..`/empty segment and only `[A-Za-z0-9._-]`
characters per segment; exactly one of `text`/`source` must be set;
`owner`/`group` must look like real Unix names; `mode` must be a
4-digit-octal *string* (`"0644"`, not the bare integer `0644`, which Nix
would silently read as decimal); and the path must not collide with a
machine-local mutable exception (below) — declaring one is a hard eval
error, not a warning.

## Machine-local mutable exceptions

Per `SPEC.md` §4.2, a short, enumerated list of paths under `/etc`
**cannot** be flake-declared at all — they are created at install/first
boot, must survive across every generation switch, and (when sensitive)
must never be world-readable:

| Path | Sensitive | Why it's an exception |
|---|---|---|
| `machine-id` | no | systemd generates a unique, per-install identifier at first boot; regenerating it every switch would break D-Bus/journald/every consumer that expects it stable. |
| `ssh/ssh_host_{rsa,ecdsa,ed25519}_key` | **yes** | `ssh-keygen -A` generates one host keypair per type on first install; overwriting it every switch breaks every client that pinned the old fingerprint, and baking a private key into the read-only store would mean every machine from the same generation shares it. |
| `ssh/ssh_host_{rsa,ecdsa,ed25519}_key.pub` | no | the public half of each key above; kept as an exception alongside its private key so the pair can never split across the generated/mutable boundary. |
| `adjtime` | no | hwclock's running drift-correction measurement, rewritten across boots; declaring/regenerating it would discard real clock-drift data. |

This list is committed as data, **not Nix**, at `etc.exceptions.json`
(repository root, sibling to `archive.lock.json`) — readable both by
`nix/etc.nix` (via `builtins.fromJSON`) and by `bin/ubx-etc` with no
`nix` binary at all. Each entry records `path`, `owner`, `group`, `mode`,
`sensitive`, and a `reason` explaining why it can't be declared; a
`sensitive: true` entry whose `mode` is world-readable fails schema
validation outright.

The exception rule is enforced **twice**, independently:

1. **At evaluation** (`nix/etc.nix`'s `validate`): declaring an exception
   path under `ubuntnix.etc` is an eval-time `throw`.
2. **At planning** (`bin/ubx-etc plan`): if either input manifest still
   names an exception path (which (1) should make unreachable — a manifest
   that has one indicates a bug or a hand-tampered file), `plan` refuses
   outright, printing every offending path and exiting non-zero **without
   printing any plan at all** — fail-closed, not "skip the bad entry".

An exception path that merely exists in the *observed* state (real files
on disk `bin/ubx-etc observe` walked) is simply never considered for
create/update/remove/drift — expected, not reported.

List the exceptions from the command line:

```console
$ ubx-etc exceptions
adjtime
machine-id
ssh/ssh_host_ecdsa_key
ssh/ssh_host_ecdsa_key.pub
ssh/ssh_host_ed25519_key
ssh/ssh_host_ed25519_key.pub
ssh/ssh_host_rsa_key
ssh/ssh_host_rsa_key.pub
```

## Compiling: `nix/etc.nix`'s `render`

`render { system; name; entries; }` validates `entries`, then routes
every declared entry's bytes through a real Nix store object
(`builtins.toFile` for `text`, the given path/derivation for `source`) —
deliberately never spliced as raw shell text, which could be corrupted by
a heredoc delimiter coincidentally present in declared content. The
result is:

```text
$out/manifest.json     { version = 1; entries = [ { path; sha256; owner; group; mode }, ... ] }
$out/tree/<path>       one regular file per declared entry, content only
```

`owner`/`group`/`mode` live **only** in the manifest — the tree's own
on-disk permission bits (whatever the store leaves them at) are never
consulted by anything downstream; applying real ownership/permissions to
a real file is the (not-yet-implemented) executor's job.

## Planning: `bin/ubx-etc plan`

`plan` is a pure diff over three manifests, all in the identical schema
`render` emits:

- `--old-manifest` — generation N's manifest (which paths were
  previously *managed*, used only to scope `remove`);
- `--new-manifest` — generation N+1's manifest (the target state);
- `--observed-manifest` — what is actually on disk right now (produced by
  `bin/ubx-etc observe --dir /etc`, or hand-crafted for tests).

| Case | Action |
|---|---|
| in new, absent from observed | `create` |
| in new, observed content differs | `update-content` |
| in new, content matches but owner/group/mode differs | `update-metadata` |
| in new, everything matches | *(no line — already converged)* |
| in old but not new, present in observed | `remove` |
| in old but not new, absent from observed | *(no line — nothing to remove)* |
| in observed only (neither manifest), not an exception | `drift` |

Output is deterministic, tab-separated, sorted by path:

```text
ACTION<TAB>PATH<TAB>OWNER<TAB>GROUP<TAB>MODE<TAB>SHA256
```

`remove` lines carry `-` for the four target fields (nothing to target);
`drift` lines carry the *observed* values (diagnostic only). Basing the
diff on `--observed-manifest` rather than trusting `--old-manifest`
matches `SPEC.md` §4.3's activation model exactly: a file hand-edited
outside `ubx` since the last switch (drift) still converges correctly on
the next switch, because the comparison is always against reality, not
against the last generation's own record of itself. `--old-manifest` is
consulted for exactly one thing — scoping `remove` to paths this project
itself declared before, never an unmanaged file (`SPEC.md` §4.2's removal
guarantee).

An empty (fully converged) plan exits `0` and prints nothing — a no-op
plan is success, not an error.

## Where to track progress

`nix/etc.nix` and `bin/ubx-etc plan`/`observe`/`exceptions` land at
milestone **M2** (`SPEC.md` §11, issue #26). Applying a plan to a real
`/etc` with real privileges (`bin/ubx-etc-apply`) and wiring the whole
thing into `ubx rebuild switch|boot|test` are later work, tracked
alongside {doc}`generations`' own activation/GC follow-ups.
