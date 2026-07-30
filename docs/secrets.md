# Secrets: git-crypt, key onboarding, and revocation

```{admonition} Mechanism + groundwork only (M4); installer wiring is M7
:class: note

`secrets/.gitattributes`, `secrets/index.nix` (a template), and
`bin/ubx-secrets-key` exist in the repository as of milestone **M4**
(`SPEC.md` §8.1, GitHub issue #79) — the git-crypt encryption boundary and
the per-machine GPG identity / collaborator-onboarding mechanism are real
and unit-tested (`tests/unit/166-secrets-gitcrypt-gitattributes.sh` through
`168-secrets-gitcrypt-roundtrip.sh`). `bin/ubx-flake-init` (GitHub issue
#114) COMPOSES this page's mechanism — the `secrets/` template and
`ubx-secrets-key machine-init` — together with `git init`/`git-crypt
init`/an initial commit into the single idempotent `/flake` bootstrap flow
SPEC.md §10's installer step 3 describes; see {doc}`install`. **Wiring
that flow to run unattended, automatically, at a real machine's first
boot is still milestone M7, out of scope for this issue** (see `SPEC.md`
§11's own M4/M7 split) — `ubx-flake-init` itself is real and unit-tested
(`tests/unit/205-ubx-flake-init.sh`) today, it is just not yet invoked by
anything running on a real installed machine. See {doc}`workflows`'s own
"Secrets workflow" section for how this fits into the declare → converge →
activate picture, and {doc}`etc`/{doc}`users` for the two closest sibling
primitives this one's planner/executor split mirrors (once that split
exists here too — see nix/secrets.nix's and `bin/ubx-secrets`/
`bin/ubx-secrets-apply`'s own headers, issue #78).
```

## Why this exists

`SPEC.md` §8.1 makes secrets first-class, not bolted on, and settles on
git-crypt (not sops-nix/agenix-style per-secret asymmetric encryption, not
a separate secrets manager) for one concrete reason: a `secrets/` folder
that is **plaintext in the working tree for keyholders, ciphertext
everywhere else the repository is stored** (on disk of anyone without a
key, on any remote, in every commit object) is the ONE property this
issue's mechanism needs, and git-crypt is the standard, audited tool that
gives it via nothing more exotic than a `.gitattributes` filter and a
GPG-collaborator list. This page documents that mechanism and the
per-machine/per-user key lifecycle around it; {doc}`workflows` documents
how a declared secret then flows from a decrypted `secrets/` file to a
real `/run/secrets/<name>` — that is `nix/secrets.nix` + `bin/ubx-secrets`
+ `bin/ubx-secrets-apply`'s own job (issue #78), not this issue's.

## The encryption boundary: `secrets/.gitattributes`

```
* filter=git-crypt diff=git-crypt
.gitattributes !filter !diff
index.nix !filter !diff
```

Every path under `secrets/` is git-crypt-encrypted by default (line 1);
exactly two files are carved back out to stay in cleartext. gitattributes'
own rule — the **last** matching pattern in a file wins — is why the
carve-outs are listed after the blanket rule, not before.

- **`.gitattributes` itself** is exempt by git-crypt's own documented
  convention: git needs to read this file's own filter/diff attributes
  *before* it can decide how to treat anything else here, so an encrypted
  `.gitattributes` would be a chicken-and-egg deadlock for a fresh clone
  that has not run `git-crypt unlock` yet.
- **`index.nix` is exempt too — a deliberate decision this issue makes**,
  covered next.

### Why `index.nix` is left clear

`secrets/index.nix` (SPEC.md §8.1's own declared-secrets shape) is left
**unencrypted**, not git-crypt-protected, even though it lives inside
`secrets/`. Three independent reasons, any one of which would be enough on
its own:

1. **It carries references only, never material.** Every field
   `index.nix` declares — `src` (a `./some-filename` path, revealing at
   most a chosen filename, never bytes), `owner`, `group`, `mode`, `dst`,
   `environmentVariable` — is exactly the closed set `nix/secrets.nix`'s
   own manifest render already treats as safe to pass through (see that
   file's header, "THE ABSOLUTE INVARIANT"). There is nothing in
   `index.nix` that needs at-rest confidentiality; the actual secret
   *bytes* live in the sibling material files the blanket `*` rule above
   still fully encrypts.
2. **`nix flake check` / CI must be able to evaluate it without a
   git-crypt key.** `nix/secrets.nix`'s `mkManifest` needs to read
   `index.nix`'s declared shape wherever Nix evaluation runs — which is
   not guaranteed to be a git-crypt-unlocked keyholder's own machine (a
   fresh CI checkout, a contributor's clone before they've been onboarded
   as a collaborator at all). A Nix path literal (`./pro-token`) only
   needs the file to *exist* on disk for `lib.types.path` to accept it,
   never for its content to be meaningful plaintext — and a locked
   (never-unlocked) git-crypt working tree still has the file *present*,
   just as ciphertext bytes, which is enough. An encrypted `index.nix`
   would instead make evaluation fail outright for every clone that isn't
   already unlocked, which is the one file every consumer of this folder
   (human or CI) needs to read regardless of key status.
3. **Diffability and review.** git-crypt's own documentation calls out
   that encrypted blobs diff/merge as opaque binary noise. `index.nix` is
   the file in this folder that legitimately changes on every ordinary
   "add/rename/re-own a secret" pull request; keeping it clear keeps that
   reviewable as an ordinary text diff, while the material files
   (rotated far less often, and never meaningfully "diffed" even when
   readable) stay opaque to anyone without a key.

`tests/unit/166-secrets-gitcrypt-gitattributes.sh` asserts the blanket
rule and both carve-outs directly against `secrets/.gitattributes`' own
text (a static check, deliberately not shelling out to `git check-attr` —
this test suite's own rule is that unit tests need no git repository state
at all to run) — this is a documented, machine-checked property, not just
a comment.

## Per-machine and per-user GPG identities

`SPEC.md` §8.1: *"The installer generates a machine keypair (stored
root-only outside the store) and adds it as a git-crypt collaborator; the
user's personal key is added for editing on workstations. A lost machine
is revoked individually (remove key, rotate affected secrets,
re-encrypt)."* `bin/ubx-secrets-key` is the mechanism behind the first two
clauses of that sentence.

### `ubx-secrets-key machine-init`

```
ubx-secrets-key machine-init [--gnupg-home DIR] [--uid UID] [--repo DIR] [--no-collaborator]
```

Idempotently generates this machine's own GPG identity in a root-only
`GNUPGHOME` **outside the Nix store** (default
`/var/lib/ubuntnix/secrets-gpg` — `/var` is one of `SPEC.md` §4.2's
writable state partitions, the same kind of machine-local, install-time,
reboot-persistent material that section's "machine-local mutable
exceptions" already enumerates for the SSH host key / `machine-id`), then
(unless `--no-collaborator` or `--repo` is omitted) adds its public key as
a git-crypt collaborator of `--repo` via `git-crypt add-gpg-user`.

- **Algorithm**: GPG's `future-default` (an ed25519 signing primary + a
  cv25519 encryption subkey) — fast to generate, low entropy demand,
  suitable for a freshly-installed machine at first boot with nothing else
  yet feeding `/dev/random`.
- **No passphrase.** The machine key must be usable *unattended*, at
  activation time (`ubx rebuild switch` decrypting `secrets/` with no
  human present to type anything in). Its only protection is the
  filesystem: `GNUPGHOME` is created `0700`, every file under it `0600`,
  owned `root:root` whenever this script actually runs as root (chmod
  always runs; chown only as real root — the same posture
  `bin/ubx-secrets-apply` already documents for its own owner/group
  writes). This is a deliberate, named tradeoff, not an oversight: an
  unattended decryption key that *needed* a passphrase could never
  actually decrypt anything at boot. The **Revocation** section below is
  what bounds the blast radius of that tradeoff.
- **Idempotent per `--uid`.** A second `machine-init` run against the same
  `--gnupg-home` and the same (default: `ubuntnix-machine-<hostname>
  <root@<hostname>>`) identity string finds the existing key and skips
  generation entirely — this is what makes it safe to invoke on every
  boot/rebuild, not just once at install time. A *different* `--uid`
  against the same `GNUPGHOME` generates a genuinely separate, second
  identity (idempotence is per-identity, not "at most one key ever" — a
  machine's own key and an onboarded user's imported key can coexist in
  the same keyring if a caller chooses to import them there).

### `ubx-secrets-key add-user`

```
ubx-secrets-key add-user --pubkey FILE --repo DIR [--gnupg-home DIR]
```

"The user's personal key is added for editing on workstations" —
implemented as **import, never generate**: the user exports their own
already-existing key (`gpg --export --armor KEYID > mykey.asc`, done on
their own machine, with their own private key never leaving it), and
`add-user` imports that public key and adds it as a git-crypt collaborator
the same way `machine-init` does for a machine's own key. This asymmetry
is deliberate and mirrors SPEC.md §8.1's own wording exactly: the
installer *generates* a machine key; a user's personal key is only ever
*added*.

### Idempotent collaborator-add, either way

Both subcommands share `add_collaborator`, which — before calling
`git-crypt add-gpg-user` — checks whether the target key's own
encryption-capable subkey ID already appears as a recipient inside an
existing `.git-crypt/keys/*/0/*.gpg` collaborator file (that ID is part of
an OpenPGP "public-key encrypted session key" packet's own cleartext
header — readable with `gpg --list-packets`, no decryption or private key
needed). Already present → the add is skipped. This keeps re-running
either subcommand a real no-op instead of a spurious new (differently
enciphered, since GPG encryption is non-deterministic) collaborator file
on every re-run — `git-crypt add-gpg-user` twice for the same key would be
*harmless* either way (same resulting access), but would otherwise show up
as unwanted repository churn.

## Revocation

`SPEC.md` §8.1: *"A lost machine is revoked individually (remove key,
rotate affected secrets, re-encrypt)."* This is an operational procedure —
a lost machine's own key obviously cannot revoke itself — run by any
*other* keyholder:

1. **Remove the lost key as a collaborator.** git-crypt has no built-in
   "remove collaborator" command (removing a `.git-crypt/keys/*/0/*.gpg`
   file does not itself change the still-committed symmetric key that key
   could already decrypt from history) — the only way to actually revoke
   access is step 3 below, generating a **new** symmetric key the lost
   machine's own private key was never granted access to, and re-adding
   only the collaborators that should still have access.
2. **Rotate every secret the lost machine could have decrypted.** Because
   `git-crypt`'s at-rest ciphertext, once committed, was encrypted with a
   symmetric key the lost machine already held, that history is
   permanently readable to it — rotation (replacing the material files'
   own bytes with fresh values, and updating whatever consumed the old
   ones: re-issuing a token, re-generating a WireGuard key, etc.) is what
   actually neutralizes a stolen/lost key, not merely "removing" it.
3. **Re-encrypt with a fresh symmetric key and a pruned collaborator
   list.** In practice: `git-crypt init` a new key ID (or a fresh repo
   history if the exposure is severe enough that even ciphertext should
   not persist), re-add every *remaining* legitimate collaborator
   (`machine-init --repo` / `add-user --pubkey --repo` for each), commit
   the rotated material from step 2 encrypted under the new key, and
   retire the old key ID entirely.

A lost machine is revoked **individually** — this list never has to touch
any other machine's or user's own key, exactly `SPEC.md` §8.1's own
wording: removing one collaborator and rotating the secrets it could see
does not require regenerating anyone else's identity.

## The keyholder model

- **Machines** hold one identity each (`machine-init`), generated at
  (eventually, M7) install time, unattended, root-only outside the store.
  A machine only needs to *decrypt* — it consumes `secrets/` at activation
  time, it does not edit it.
- **Users** hold personal keys generated on their own workstation by
  ordinary GPG tooling, outside this script's own reach entirely; only the
  already-exported *public* half ever crosses into this project's own
  onboarding flow (`add-user`). A user with a personal key added can
  `git-crypt unlock` and edit `secrets/` on any machine holding their
  private key — "for editing on workstations," per `SPEC.md` §8.1 —
  including staging a *new* secret's material file for the first time.
- **Every collaborator — machine or user — can decrypt everything** under
  `secrets/`; git-crypt's own GPG-collaborator model is repo-wide, not
  per-secret. Finer-grained, per-secret access control is out of scope for
  this issue (and, per `SPEC.md` §8.1, out of scope for the whole
  mechanism) — the boundary this project draws is "keyholder vs.
  everyone else," not "which keyholder sees which secret."
