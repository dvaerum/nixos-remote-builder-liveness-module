# 0002: TOFU host-key checking, not a pinned key

## Decision

The dispatching side connects with
`-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<dedicated file>`
-- trust-on-first-use against a known_hosts file scoped to this
mechanism alone, not a known_hosts entry pinned in the Nix module
itself.

## Why

The machines-file format does support inlining the peer's SSH host key
directly (sidestepping `known_hosts` entirely), which would be the
stronger guarantee -- but it requires knowing the peer's host key
up front, at the time this module is configured. For a peer that isn't
reliably reachable yet (the common case this module exists for: a
second machine that isn't always on), that key may not be knowable at
configuration time at all.

`accept-new` is a real, meaningful security property on its own: it
rejects a host key that later **changes** unexpectedly -- the actual
MITM protection that matters for an already-established pairing. What
it doesn't protect against is the very first connection ever made to a
given hostname, same as any other TOFU scheme (`ssh` itself, for
example).

## Consequence / future work

Once a peer is reliably reachable, this could be tightened to a pinned
host key in the machines-file line (replacing the `-` placeholder in
the format) for stronger first-contact guarantees. Not done by default
here because it would turn "peer isn't up yet" into a hard
configuration blocker instead of a soft, self-resolving one.

## Trust model, stated plainly

Both directions of this module (dispatching and receiving) only make
sense between machines under the same administration, trusted roughly
as much as running `sudo` on each other locally:

- Remote build **results** carry no signature check on return (unlike
  a substituter path, which `trusted-public-keys` verifies) -- they're
  accepted as-is over the SSH channel.
- The receiving side's authorized key is restricted via a forced
  `command=` + `restrict` in `authorized_keys`, so it can only ever
  invoke `nix-store --serve`, never open a shell -- but that still
  grants the ability to import and serve build inputs as a trusted
  user (`nix.settings.trusted-users`), which is a meaningful privilege
  on its own.

Do not point `peers.<name>.hostname` at a machine you would not otherwise be
willing to run arbitrary `sudo` commands on.
