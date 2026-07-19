# ubuntnix test harness

`./tests/run.sh` is the single entry point CI and developers use.

## Layout

- `tests/unit/` — fast, hermetic tests. Any executable file; passes iff it
  exits 0. Named `NNN-description` to keep ordering readable.
- `tests/e2e/` — end-to-end tests (opt-in via `UBX_E2E=1`). These will
  drive QEMU: boot a built image, exercise `ubx` switch/rollback flows, and
  assert on the running system. The QEMU harness lands with M1's boot test
  and grows with each milestone.

## Rules

- Tests are written **first**, from the acceptance criteria of the issue
  they verify (see CONTRIBUTING.md).
- An empty suite fails: the harness refuses to green-light nothing.
- Unit tests must not require root, network, or KVM. E2E tests may require
  KVM and declare it by exiting 77 (skip) when unavailable.
