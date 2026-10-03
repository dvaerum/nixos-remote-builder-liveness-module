# 0011: dispatch.sh's default branch must exec nix-daemon --stdio, not nix-store --serve

## Decision

`dispatch.sh`'s default branch (anything other than the feature-query
sentinel) execs `nice -"$nice_level" nix-daemon --stdio`, not
`nix-store --serve --write`.

## Why

**Found during a real deployment, not this project's own test suite.**
A peer correctly passed the shared-trust-store fix (`docs/decisions/0008`)
-- host-key checking succeeded -- but the real build dispatch still
failed with `error: failed to start SSH connection to '<peer>'`, right
after a successful SSH authentication, with the remote side's log
showing `protocol mismatch`.

Root cause, confirmed against Nix 2.34.8's own C++ source (not assumed):
`refresh.sh` always writes machines-file entries as `ssh-ng://`
(`refresh.sh`'s fragment-write `printf`). Nix's `ssh-ng://` store
(`SSHStoreConfig`, `src/libstore/ssh-store.cc:204-205`) always execs
`<remoteProgram> --stdio` on the far end, with `remoteProgram` defaulting
to `nix-daemon` (`src/libstore/include/nix/store/ssh-store.hh:28-29`) --
it speaks Nix's modern daemon *worker protocol*. `nix-store --serve` is
the remote command the OLDER, unrelated `ssh://` store type expects
instead (`LegacySSHStoreConfig`, `src/libstore/legacy-ssh-store.cc:58-59`,
default `remoteProgram` = `nix-store`) -- a completely different,
incompatible wire protocol. `dispatch.sh` was execing the wrong one:
**this meant real `ssh-ng://` build dispatch to any peer running this
module's own receiving side had never actually worked**, independent of
host-key trust, since before the module's first commit.

**Why the liveness probe itself still worked correctly despite this:**
the probe only ever checks SSH's own exit code (255 = connection/auth
failure, anything else = "reachable", see `refresh.sh`'s own comment) --
it never depends on the forced command's protocol being compatible with
anything, just that it starts and exits non-255. Both `nix-store --serve`
and `nix-daemon --stdio` satisfy that equally, so the probe's own
end-to-end tests (this project's entire existing suite) never had a
reason to fail.

**Why `nix-daemon --stdio` doesn't need any new trust/permission wiring**
on the receiving side, confirmed against `src/nix/unix/daemon.cc`'s
`runDaemon()`: run by a non-root user with no `NIX_REMOTE` override, it
resolves to the local `daemon` store type and transparently forwards the
connection to the *real* system `nix-daemon`'s own Unix socket
(`forwardStdioConnection`) -- the exact same path `nix-store --serve`
already relied on. The existing `nix.settings.trusted-users =
["nix-remote-builder"]` (`userConfig.nix`) already covers it.

## Consequence: a real wire-protocol test, pinning down docs/decisions/0008's nspawn limitation precisely

`docs/decisions/0008`'s "Consequence" section recorded an abandoned real
end-to-end build-dispatch test, diagnosed only as "`nix-daemon.service`
never starts in this project's `systemd-nspawn` test containers", and
substituted a narrower rendered-unit check instead.

Nix's `ssh-ng://` *client* code is a plain `nix` CLI store implementation
(`SSHStoreConfig`), independent of whether the **dispatching** side's own
`nix-daemon.service` is running -- so `tests/nixos/liveness.nix` can run
`nix store ping --store 'ssh-ng://nix-remote-builder@carol?ssh-key=...'`
directly from a plain shell, with no systemd service of its own on that
side at all. This genuinely exercises real SSH auth and a real forced-
command dispatch on the **receiving** side -- confirmed via `-vvvv`:
a clean `publickey` auth, then `dispatch.sh`'s forced command actually
executing.

**It still can't complete a full round-trip in this environment** -- not
because `nix-daemon.service` "never starts" (it does: `systemctl start
nix-daemon.service` reaches `Active: active (running)` just fine), but
because the moment a *real* connection reaches it, the daemon's own
`LocalStore` initialization calls `chown("/nix/store", ...)`, which fails
with `Operation not permitted` (confirmed via the daemon's own journal
entry: `unexpected Nix daemon error: error: changing ownership of path
"/nix/store": Operation not permitted`) -- `systemd-nspawn` containers
don't grant the capability that needs, the same class of limitation
`docs/decisions/0004` already accepted as this backend's trade-off.
Socket-activating the daemon cold is *also* too slow relative to the SSH
client's own connect timeout (the service still reaches `active` a few
hundred ms later) -- worked around with an explicit `systemctl start`
before the real assertion, since a production deployment's daemon is
realistically always already running continuously anyway.

**The actual regression test doesn't need the full round-trip to
succeed.** Nix's own `legacy-ssh-store.cc` emits the literal string
`"error: protocol mismatch"` when an `ssh-ng://` client's handshake hits
a `nix-store --serve` peer -- confirmed empirically to appear ONLY when
`dispatch.sh`'s fix is reverted (genuine RED), and to never appear with
the fix applied, regardless of the unrelated `chown` wall past it
(genuine GREEN). Asserting that string's absence is precisely the
regression this ADR fixes, without depending on this environment's one
remaining, unrelated, already-accepted limitation.
