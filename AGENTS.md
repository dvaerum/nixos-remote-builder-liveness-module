# AGENTS.md

Instructions for any coding agent (human or AI) working in this repo.

## What this is

A NixOS module that gives `nix.settings.builders` a live, self-updating
peer: a systemd timer probes a peer machine's SSH reachability every
60s and atomically rewrites a plain runtime file that `nix-daemon`
re-reads fresh on every build dispatch (confirmed against
`src/libstore/machines.cc` -- zero caching). See `docs/decisions/` for
the design reasoning behind each real choice (live `@file` vs static
`nix.buildMachines`, TOFU host-key checking, the shared mutual
keypair) -- don't re-derive decisions already recorded there.

There is no software package here, only a NixOS module + a shell
script sourced straight from this tree. No build artifact, no
language toolchain, nothing to version-pin beyond the flake itself.

## Project structure

```
flake.nix          nixosModules.default + checks.<system>.liveness
nixosModule/        options.nix (services.nixDynamicBuilders.*), config.nix (the actual
                    systemd units/users/nix.settings wiring), default.nix (glue)
refresh.sh          the liveness-probe script itself, wrapped via
                    pkgs.writeShellApplication in config.nix -- edit this file
                    directly, not an inline string in config.nix
tests/nixos/        liveness.nix -- a real two-VM nixosTest: both peers probe
                    each other over real SSH, assert the machines file tracks
                    actual reachability both ways (up AND the peer going down)
tests/fixtures/      test-ed25519 -- a throwaway keypair generated solely for
                    the test above; not a real secret, safe to read/regenerate
docs/decisions/      one ADR per real design decision, with sources cited
```

## Workflow

- Gate before committing: `nix flake check -L`. This is the whole test
  suite -- there's no separate fast/slow tier here, just the one real
  end-to-end VM test. It's slow (builds two NixOS VMs from scratch on
  a cold cache) -- that's expected, not a sign something's wrong.
- `nix fmt` (nixfmt-rfc-style) before committing any `.nix` change.
- Changing `refresh.sh`: re-run `nix flake check` -- the test actually
  exercises this script inside a real VM, not just the Nix wiring
  around it.
- Changing an option in `options.nix`: update `README.md`'s options
  table by hand (no `docs/options.md` generator here, unlike the
  sibling `nixos-postgres-maintenance-module` -- this module's option
  surface is small enough that a generator would be more machinery
  than the thing it documents).

## Versioning

None. There's no package build and no CLI contract to version --
consumers pin this module the normal flake-input way, by git revision
(`nixos-remote-builder-liveness-module.url =
"github:dvaerum/nixos-remote-builder-liveness-module"`, locked in the
consumer's own `flake.lock`). A breaking change to
`services.nixDynamicBuilders.*` just needs a clear commit message and,
if the break is non-obvious, a line in `README.md`'s Setup section --
not a version bump, since nothing reads or depends on a version number
anywhere in this repo.

## Documentation

- Record a real design decision as a new, numbered ADR in
  `docs/decisions/NNNN-<title>.md` -- decision, alternatives
  considered, WHY with sources, not a changelog.
- Don't duplicate information across docs -- link to the canonical
  home instead of copying. `README.md` is the user-facing entry point;
  `docs/decisions/` is where the WHY actually lives.
