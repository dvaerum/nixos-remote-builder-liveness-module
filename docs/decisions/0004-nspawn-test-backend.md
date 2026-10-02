# 0004: `systemd-nspawn` containers, not QEMU VMs, for the test suite

## Decision

`tests/nixos/liveness.nix` declares its test machines under the
nixosTest framework's `containers = { ... }` attribute (backed by
`systemd-nspawn`), not `nodes = { ... }` (backed by QEMU) -- same test
script, same machine abstraction (`machine.succeed(...)`,
`wait_for_unit(...)`, etc.), different backend underneath.

## Why

This is the only test tier this module has (see `AGENTS.md`): no
separate fast/slow split, just the one real end-to-end run gated by
`nix flake check -L`. As the module grew from one peer to several, plus
key generation, plus a live feature-query round trip, the scenario count
kept growing -- a 3+ host scenario on a from-scratch QEMU boot is a much
heavier loop to iterate against than the same scenario under nspawn,
which shares the host kernel and starts in a fraction of the time.

Confirmed via nixpkgs source (`nixos/lib/testing/{nodes,driver-
configuration}.nix`, the manual's `writing-nixos-tests.section.md`, and
nixpkgs' own `nixos/tests/nixos-test-driver/containers.nix`) that this
is a fully supported, documented part of the stable testing library --
not gated behind a Nix `experimental-features` flag the way flakes are,
just a less commonly reached-for backend. Container-to-container
networking over a shared `virtualisation.vlans` entry is the same
mechanism VMs use and was confirmed working peer-to-peer in nixpkgs'
own test before relying on it here.

The trade-offs the manual documents for containers over VMs -- no
setuid binaries, no `specialisation` switching, sharing the host kernel
instead of a separate one -- don't apply to anything this module does.

## Consequence

Converting the backend surfaced (not introduced) four real, pre-existing
bugs that had never been caught because this repository had never had
`nix flake check -L` run successfully before, on any backend:

- the test asserted `wait_for_unit("sshd.service")`, but current nixpkgs
  socket-activates sshd (`sshd.socket` is what's actually active at that
  point; `sshd.service` is a transient per-connection unit)
- the probe's `ssh` invocation choked on a bad-permissions
  `systemd-ssh-proxy` `ssh_config.d` drop-in pulled in via the system
  `ssh_config`'s default `Include`; fixed with `-F /dev/null`, since
  `refresh.sh` already pins every option it needs explicitly and was
  never meant to depend on ambient system config anyway
- the receiving-side user had no password option set, which NixOS
  renders as the shadow "locked" sentinel (`!`); current OpenSSH refuses
  any login, pubkey included, once it sees that, independent of PAM --
  fixed via `hashedPassword = "*"` (unmatchable, not administratively
  locked)
- the liveness probe's `ssh ... true` could never see a reachable peer
  as reachable at all: the receiving side's forced `command=` always
  overrides what the client asks to run, so the real exit code being
  checked was `nix-store --serve`'s own (always non-zero against a
  probe that sends it no protocol data), not `true`'s

None of these are nspawn-specific -- they would have failed identically
under the QEMU backend the first time it was actually exercised. Finding
them during this conversion, rather than later, is incidental to why the
backend was switched, not the reason for it.

Added dependency: `pkgs.fzf`, for `nix-dynamic-builders-show-key --fzf`
(unrelated to the backend switch itself, picked up in the same phase of
work).
