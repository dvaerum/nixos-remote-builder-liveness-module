# AGENTS.md

Instructions for any coding agent (human or AI) working in this repo.

## What this is

A NixOS module that gives `nix.settings.builders` a live, self-updating
peer: a systemd timer probes a peer machine's SSH reachability every
60s and atomically rewrites a plain runtime file that `nix-daemon`
re-reads fresh on every build dispatch (confirmed against
`src/libstore/machines.cc` -- zero caching). A host can have any number
of peers, each independently probed. See `docs/decisions/` for the
design reasoning behind each real choice (live `@file` vs static
`nix.buildMachines`, TOFU host-key checking, per-host identity keys and
why `supportedFeatures` is live-fetched, the `systemd-nspawn` test
backend) -- don't re-derive decisions already recorded there.

There is no software package here, only a NixOS module + a shell
script sourced straight from this tree. No build artifact, no
language toolchain, nothing to version-pin beyond the flake itself.

## Project structure

```
flake.nix          nixosModules.default + checks.<system>.liveness
nixosModule/        options.nix (services.nixDynamicBuilders.*), config.nix (the actual
                    systemd units/users/nix.settings wiring), default.nix (glue)
refresh.sh          the liveness-probe script, one instance per configured
                    peer, wrapped via pkgs.writeShellApplication in config.nix
                    -- edit this file directly, not an inline string
dispatch.sh         the receiving side's forced authorized_keys command --
                    branches between nix-store --serve and a live
                    supportedFeatures query, see docs/decisions/0003
show-key.sh         nix-dynamic-builders-show-key's script body -- prints a
                    public key for the Setup bootstrap flow in README.md
tests/nixos/        liveness.nix -- a real multi-peer nixosTest (systemd-nspawn,
                    see docs/decisions/0004): several peers probe each other
                    over real SSH, assert the assembled machines file tracks
                    actual reachability per peer independently, live feature
                    queries, self-generated keys, and show-key
tests/fixtures/      test-ed25519 -- a throwaway keypair generated solely for
                    the test above; not a real secret, safe to read/regenerate
docs/decisions/      one ADR per real design decision, with sources cited
```

## Workflow

- Gate before committing: `nix flake check -L`. This is the whole test
  suite -- there's no separate fast/slow tier here, just the one real
  end-to-end test, now on `systemd-nspawn` containers rather than QEMU
  (see `docs/decisions/0004`) -- noticeably faster per iteration than a
  from-scratch VM boot, but still a real multi-host run, not a stand-in.
- `nix fmt` (nixfmt-rfc-style) before committing any `.nix` change.
- Changing `refresh.sh` or `dispatch.sh`: re-run `nix flake check -L` --
  the test actually exercises these scripts inside real containers, not
  just the Nix wiring around them.
- New non-`.nix` files referenced via `builtins.readFile` (like
  `dispatch.sh`/`show-key.sh`) must be `git add`-ed before Nix can see
  them at all -- flakes only evaluate git-tracked files.
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
