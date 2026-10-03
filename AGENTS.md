# AGENTS.md

Instructions for any coding agent (human or AI) working in this repo.

## What this is

A NixOS module that gives `nix.settings.builders` a live, self-updating
peer: a systemd timer probes a peer machine's SSH reachability every
60s and atomically rewrites a plain runtime file that `nix-daemon`
re-reads fresh on every build dispatch (confirmed against
`src/libstore/machines.cc` -- zero caching). A host can have any number
of peers, each independently probed. Dispatching to peers
(`services.nixDynamicBuilders`) and accepting connections from peers
(`services.nixDynamicBuilderUser`) are two independently-enableable
services -- see `docs/decisions/0005`. See `docs/decisions/` for the
design reasoning behind each real choice (live `@file` vs static
`nix.buildMachines`, TOFU host-key checking, per-host identity keys and
why `supportedFeatures` is live-fetched, the `systemd-nspawn` test
backend) -- don't re-derive decisions already recorded there.

There is no software package here, only a NixOS module + a shell
script sourced straight from this tree. No build artifact, no
language toolchain, nothing to version-pin beyond the flake itself.

## Project structure

```
flake.nix          nixosModules.default + checks.<system>.{liveness,examples,optionsDocUpToDate}
nixosModule/        options.nix + config.nix: services.nixDynamicBuilders.* (dispatching to
                    peers -- probing, the machines file, outbound SSH keys, show-key).
                    userOptions.nix + userConfig.nix: services.nixDynamicBuilderUser.*
                    (accepting connections from peers -- the nix-remote-builder account,
                    authorized_keys, trusted-users). featureQuerySentinel.nix: the one
                    literal both config.nix and userConfig.nix must agree on, shared
                    rather than duplicated. default.nix: glue (imports all four).
refresh.sh          the liveness-probe script, one instance per configured
                    peer, wrapped via pkgs.writeShellApplication in config.nix
                    -- edit this file directly, not an inline string
dispatch.sh         the receiving side's forced authorized_keys command --
                    branches between nix-daemon --stdio and a live
                    supportedFeatures query, see docs/decisions/0003
show-key.sh         nix-dynamic-builders-show-key's script body -- prints a
                    public key for the Setup bootstrap flow in README.md
examples/           working, tested services.nixDynamicBuilders.*/
                    services.nixDynamicBuilderUser.* scenarios -- one self-contained
                    module fragment per file, indexed by examples/default.nix, each
                    imported for real by tests/nixos/examples.nix
tests/nixos/        liveness.nix -- a real multi-peer nixosTest (systemd-nspawn,
                    see docs/decisions/0004): several peers probe each other
                    over real SSH, assert the assembled machines file tracks
                    actual reachability per peer independently, live feature
                    queries, self-generated keys, and show-key.
                    examples.nix -- every examples/ file actually evaluates
                    and wires up the units it claims to.
tests/fixtures/      test-ed25519, test-ed25519-2 -- two throwaway keypairs
                    generated solely for the tests above (two, not one, so a
                    test can prove two genuinely different real keys both get
                    accepted, not the same fixture key reused under two
                    names); not real secrets, safe to read/regenerate
docs/decisions/      one ADR per real design decision, with sources cited
docs/options.md      generated option reference -- see "Documentation" below
generate-doc.nix    regenerates docs/options.md -- see "Documentation" below
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
- Any new file referenced from Nix (`.nix` or not -- `dispatch.sh`,
  `show-key.sh`, a new `examples/*.nix`) must be `git add`-ed before Nix
  can see it at all -- flakes only evaluate git-tracked files.
- Changing an option in `options.nix` or `userOptions.nix`: every option
  needs a `description` -- `generate-doc.nix` builds with
  `documentation.nixos.options.warningsAreErrors` behavior (a missing
  description is a hard build failure, not a warning), so this is
  caught by the same gate as everything else, not a separate lint.
  Regenerate the doc afterwards (see "Documentation" below).
- Adding or changing an option that a real deployment would plausibly
  use: add or update an `examples/*.nix` scenario and its assertions in
  `tests/nixos/examples.nix` -- same reasoning as
  `nixos-postgres-maintenance-module`'s own `examples/`: a
  renamed/removed option should fail CI through a real example, not
  just silently go stale in prose.

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
  `docs/decisions/` is where the WHY actually lives; `docs/options.md`
  is generated, not hand-maintained -- edit `nixosModule/options.nix`
  and regenerate instead of editing the doc directly:

  ```
  nix-build generate-doc.nix && cp result docs/options.md
  ```
