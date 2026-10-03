# 0008: nix-daemon's real build dispatch shares the probe's trust store

## Decision

`nix-daemon`'s own `NIX_SSHOPTS` environment variable is set to `-o
UserKnownHostsFile=${knownHostsFile} -o StrictHostKeyChecking=accept-new`
-- the exact same file and policy `refresh.sh`'s own liveness probe
already uses. Daemon-wide (`systemd.services.nix-daemon.environment`),
not per-peer: Nix has no per-machine ssh-options field at all, so this
is the only lever available regardless.

## Why

**A real deployment hit this: a peer correctly detected as reachable
still failed every real build dispatch.** Confirmed via Nix's own
source (`src/libstore/ssh.cc`, `src/libstore/machines.cc`, Nix
2.34.8): the liveness probe and `nix-daemon`'s real `ssh-ng://`
build-dispatch connection are two *entirely separate* SSH connections
with two separate trust stores. The probe explicitly points at its own
private `knownHostsFile` (`refresh.sh`'s `-F /dev/null -o
UserKnownHostsFile=...`). The machines-file line's host-key field is
deliberately left as `"-"` (TOFU, not pre-pinned -- see
`docs/decisions/0002`), so `nix-daemon`'s own connection never receives
a matching `UserKnownHostsFile` override and falls back entirely to
whatever ambient system SSH config happens to exist -- which this
module never touches. On a fresh host with no other SSH trust already
established for that peer, the daemon's connection fails outright
(non-interactive, can't prompt for a yes/no host-key answer), and Nix's
own graceful "just build locally" fallback silently hid the failure --
confirmed-reachable never actually meant "a build can get there."

**`NIX_SSHOPTS` is read first, before anything else, for every
`ssh-ng://` connection `nix-daemon` makes** (`ssh.cc`'s
`addCommonSSHOpts`). Pointing it at the same file the probe already
TOFU-populates closes the gap with one shared trust source, not a
second independent one to keep in sync.

## Alternatives considered

**Populate the machines-file line's host-key field (field 8) instead.**
Rejected: this needs the real key known in advance, which conflicts
with the whole point of TOFU -- the same tension `docs/decisions/0002`
already rejected pre-pinning for.

## Consequence

A real end-to-end test (a forced-remote build via `nix-build
--max-jobs 0`, chosen specifically because it can't silently fall back
to local the way the real system that surfaced this bug did) was
attempted and had to be abandoned: `nix-daemon.service` showed
`inactive (dead)` with an empty journal throughout, confirmed unrelated
to this fix by reproducing the identical failure with the fix entirely
absent (`docs/decisions/0004`'s own tradeoffs already note containers
can't do everything a full VM can -- this appears to be one more
instance). What's verified instead: the fix is correctly wired into the
rendered `nix-daemon` unit. That's a narrower guarantee than the full
proof this fix deserves, not a substitute for it.

**Update (`docs/decisions/0011`):** a later, independent real-protocol
test pinned this down precisely -- `nix-daemon.service` isn't actually
unable to start (`systemctl start` reaches `active (running)` directly);
cold socket activation is just too slow relative to a connecting
client's own timeout, and even once running, a real connection hits a
missing container capability (`chown("/nix/store")` fails with
`Operation not permitted`). Still the same class of nspawn limitation
this ADR already accepted, now diagnosed to the exact syscall instead of
an opaque "won't start".
