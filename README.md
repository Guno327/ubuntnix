# ubuntnix

[![CI](https://github.com/Guno327/ubuntnix/actions/workflows/ci.yml/badge.svg)](https://github.com/Guno327/ubuntnix/actions/workflows/ci.yml)

**A fully declarative, immutable Ubuntu.** One Nix flake is the complete
source of truth for a machine — its packages (snaps and debs), system
configuration, services, users, and home directories — composed into
read-only, atomically-switchable generations. The running system is genuine
Ubuntu: the real archive, the real kernel, snapd with strict *and* classic
snaps, server and desktop alike.

ubuntnix is a **shim — a pure function**:

```
f(upstream Canonical artifacts, user configuration) → immutable Ubuntu system
```

It repackages nothing and reinvents none of Ubuntu's plumbing: modules
compile declarations onto stock mechanisms (netplan, GRUB, systemd), all
software comes from Canonical (the Nix ecosystem contributes source-code
libraries only), and Ubuntu Pro backs the security story.

## Status

**Pre-M1.** The complete specification — vision, architecture, decision
ledger, and the milestone path to V1.0 — lives in [SPEC.md](SPEC.md).
Progress is tracked in [GitHub issues and milestones](https://github.com/Guno327/ubuntnix/issues).

**V1.0 target:** take our ISO, follow the installer, and get the exact
system an upstream Ubuntu Desktop/Server install would have produced — same
software, same defaults — except fully managed through ubuntnix, with your
config in `/flake`.

## Development

This project is operated by AI agents under human ownership; see
[CONTRIBUTING.md](CONTRIBUTING.md) for the conventions (conventional
commits, feature branches, tests-first). The test suite runs via
`./tests/run.sh`.

## License

[GPL-3.0](LICENSE)
