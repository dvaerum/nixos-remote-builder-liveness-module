# 0010: per-peer SSH options via one shared ssh_config file

## Decision

A new per-peer option, `peers.<name>.extraSshConfig` (a list of raw
`ssh_config(5)` lines), is rendered into a `Host <hostname>` block in one
shared, Nix-store-rendered config file
(`nix-dynamic-builders-ssh-config`). Both `nix-daemon`'s real
`ssh-ng://` build dispatch (via `NIX_SSHOPTS`'s `-F`) and the probe's own
connection (`refresh.sh`'s `ssh_opts`'s `-F`, replacing the previous
`-F /dev/null`) read this same file. Each peer's block also carries an
explicit `IdentityFile` line pointing at that peer's own resolved key.

## Why

`NIX_SSHOPTS` is daemon-wide -- Nix has no per-machine ssh-options field
in the machines-file format at all (confirmed against
`src/libstore/machines.cc`'s fixed 8-column line format, same source
already cited in `docs/decisions/0008`). So "a jump host for peer A but
not peer B" can't be expressed as two different `NIX_SSHOPTS` values.
SSH's own `Host`-pattern matching already solves exactly this --
different blocks, scoped by hostname, in one config file -- so instead
of fighting `NIX_SSHOPTS`'s single-value nature, this generates one file
with one block per peer and lets SSH's own matching do the scoping.

The file is built by Nix (`pkgs.writeText`, same pattern as the existing
`keyMapFile`) from the already-static `peers.<name>.extraSshConfig`
option -- no new runtime writer, no new permission question: Nix store
paths are inherently world-readable, so both `nix-daemon` (root) and the
probe (the unprivileged `nix-dynamic-builders` user, see
`docs/decisions/0009`) can read it with zero extra wiring.

**`IdentityFile` is set in the file itself, not just passed as `-i` on
the probe's own command line, because a `ProxyJump` hop re-invokes `ssh`
as a separate process against the same `-F` file** -- that nested
invocation never sees the outer process's `-i` flag, only what the
config file's own matching `Host` block says. Without this, a
jump-host peer's bastion hop would have no identity to authenticate
with at all.

## Consequence

Proven end-to-end (not just rendered-unit grepping) in
`tests/nixos/liveness.nix`: a peer ("proxied") whose own configured
hostname doesn't resolve to anything at all, reachable ONLY because its
`extraSshConfig`'s `Hostname carol` directive redirects the connection
to a real, otherwise-reachable peer. This is the only way to prove the
shared config file is genuinely read by the probe's own `ssh`
invocation, not just correctly rendered and never consulted -- confirmed
RED first (reverting the probe's `-F` wiring back to `/dev/null` made
this exact assertion time out and fail the build), then GREEN once
restored.

A real `ProxyJump` to a genuinely separate bastion host was not
exercised end-to-end here (would need a third real hop in the test
topology); the `Hostname`-redirect proof exercises the same underlying
mechanism (the config file's `Host` block being consulted at all) that
`ProxyJump` itself depends on.

**Known gap, out of scope here:** if a jump host itself needs its own
distinct identity (different from the target peer's key), there's no
structured option for that -- `extraSshConfig` only lets you add lines
inside that ONE peer's own `Host <hostname>` block, not a second,
separate `Host <bastion>` block. An admin needing that can still get
there via their own `programs.ssh.extraConfig` at the host level
(outside this module), or an SSH agent holding the bastion's key.
