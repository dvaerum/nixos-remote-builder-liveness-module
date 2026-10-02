# 0003: Multiple peers, per-host identity keys, live supportedFeatures

## Decision

`services.nixDynamicBuilders.peer` (one fixed submodule) becomes
`services.nixDynamicBuilders.peers` (an `attrsOf` submodule, keyed by an
arbitrary peer name that also defaults the peer's hostname). Each peer
gets its own entry in `nix.settings.builders`'s machines file, written as
its own fragment and reassembled into the single file nix-daemon reads --
not a single peer's worth of state pretending to be the whole file.

SSH key material drops the sops-nix dependency entirely.
`services.nixDynamicBuilders.sshKey` (global, mandatory -- no implicit
default) and `peers.<name>.sshKey` (per-peer override, default `false`)
are both a tri-state: `true` generates a key (shared default globally,
distinct per-peer at peer level) the first time it's needed if one
doesn't already exist; `false` disables the shared default (every peer
must then set its own, or evaluation fails naming which peer didn't); a
path/string uses an exact pre-existing key. No two hosts ever share the
same private key file -- only ever a public half, copied manually via
the new `nix-dynamic-builders-show-key` command.

`peers.<name>.supportedFeatures` stops being the value actually
advertised to nix-daemon in the common case. It's now a fallback, used
only if a live query fails; the real value is fetched every tick from
the peer itself, over the same restricted SSH channel. This is what the
receiving side's forced `authorized_keys` command (`dispatch.sh`)
exists for: it no longer runs the literal string `nix-store --serve
--write` unconditionally, but branches on `$SSH_ORIGINAL_COMMAND` --
one sentinel command runs `nix config show system-features` instead,
still fully `restrict`-ed, with every other input falling through to the
real serve command (load-bearing, not just tidy: nix-daemon constructs
its own `ssh-ng://` dispatch call independently of this module, so
anything that isn't the exact sentinel must still reach the real
command or live builds break).

## Why

**Multiple peers.** A fleet of more than two machines (a laptop and two
desktops, say) has no reason to be artificially limited to one dispatch
target per host -- the liveness-gating mechanism this module exists for
(see `docs/decisions/0001`) applies identically to any number of peers,
each probed and gated independently. The only real design question was
whether concurrent per-peer timers writing to one shared machines file
could race each other; fragment-per-peer plus a reassembly pass (each
peer only ever writes its own fragment, reassembly only ever reads)
avoids that without any locking.

**No two hosts share a private key.** The original single-shared-mutual-
keypair design meant the literal same private key file existed on both
sides of a pairing -- compromising one host's copy compromises the
other's identity too, even though nothing about THAT host was at fault.
Each host generating (or being given) its own key, with only the public
half ever leaving the host, confines a compromise to the host it
actually happened on.

**No sops dependency.** sops-nix is a reasonable way to deliver a
pre-existing secret, but it's an unnecessary hard dependency for a
module whose whole point is working across machines that aren't always
reachable or already configured with a secrets pipeline. Self-generation
on first use removes the manual `ssh-keygen` step without removing the
option to supply a pre-existing key for anyone who wants one (path/string
value), while keeping the module itself free of any particular secrets-
manager's assumptions.

**`supportedFeatures` goes live, `mandatoryFeatures` doesn't.** Per
`src/libstore/machines.cc`'s machine-matching rule, `supportedFeatures`
describes a fact about the peer (what it can actually do), while
`mandatoryFeatures` is the *dispatching* host's own policy choice (only
send builds here if they explicitly need X) -- there is nothing on the
peer to query for the latter, since it was never a property of the peer
in the first place. A value that's a fact about a real external system
should track that system, not a value typed once and left to drift;
`nix config show system-features` is the peer's own authoritative,
already-computed answer (the same value it uses for its own local
builds), not a second thing this module invents.

## Alternatives considered

**Per-peer receiving-side system users**, instead of one shared
`nix-remote-builder` account with one `authorized_keys` line per peer.
Rejected: the forced `command=`/`restrict` pair already fully constrains
each key regardless of which account it lands on, so a separate account
per peer would add systemd units, home directories, and
`trusted-users` entries for no additional isolation.

**Parsing `/etc/nix/nix.conf` directly** for `supportedFeatures` instead
of `nix config show`. Rejected: the live daemon is the authoritative
source (it reflects whatever the running daemon actually resolved,
including any `extra-system-features` merge directives), while a text
file is one step further from the thing that actually matters and more
fragile to parse correctly.

## Consequence

A host's peer relationships are no longer symmetric by construction --
each side can independently choose self-generated, pre-existing, shared,
or per-peer-distinct key material, and each side's receiving user accepts
any number of peers' keys. The trade-off is a two-step bootstrap for a
brand-new peer relationship (deploy with a placeholder `publicKey`,
extract the real one via `show-key`, redeploy) where the old static,
pre-shared-keypair design didn't need one -- documented in README's Setup
section.
