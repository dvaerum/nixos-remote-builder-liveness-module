# 0005: The receiving-side account becomes its own service

## Decision

`services.nixDynamicBuilders` splits in two. `services.nixDynamicBuilders`
keeps everything about *dispatching* to peers: probing, the machines file,
outbound SSH keys, `show-key`. A new, independently-enableable
`services.nixDynamicBuilderUser` owns everything about *accepting*
connections from peers: the `nix-remote-builder` user/group, its
`authorized_keys`, `nix.settings.trusted-users`, and the `dispatch.sh`
wiring.

The two services no longer share one `peers.<name>` schema. Fields that
describe dispatching to a peer (`hostname`, `system`, `maxJobs`,
`speedFactor`, `supportedFeatures`, `mandatoryFeatures`, `sshKey`, the SSH
tunables, `publicKeyWorldReadable`) stay under
`services.nixDynamicBuilders.peers.<name>`. Fields that describe accepting
a peer (`publicKey`, `niceLevel`) move to
`services.nixDynamicBuilderUser.peers.<name>`. A host configuring a real
bidirectional peer relationship now names that peer under both option
trees -- nothing links the two beyond convention.

## Why

**The two directions were always independent facts, just forced through
one `enable` flag.** Dispatching to a peer only ever needs the `ssh`
client; accepting a peer's connection only ever needs a local account and
an SSH server. Nothing about the probing/machines-file mechanism requires
this host to also be reachable, and nothing about being reachable requires
this host to probe anyone. The single shared `enable` was a historical
accident of the module growing from a single-peer, single-direction
design (see `docs/decisions/0003`), not a real coupling.

**A receive-only host is a real, plausible deployment shape.** A
dedicated build-serving box -- provisioned purely to accept builds from a
fleet, never to dispatch anywhere itself -- had no way to enable just
that half before this change; enabling `services.nixDynamicBuilders` to
get the receiving-side account also silently created refresh timers,
outbound SSH key material, and a `show-key` command this host would never
use. The reverse (dispatch-only, never accepting) has the same shape:
an orchestrator host that only ever reaches out to build farm members,
never itself a build target.

**Splitting the `peers` schema, not sharing one list.** The alternative
-- one shared `services.nixDynamicBuilders.peers.<name>` still carrying
every field, with `services.nixDynamicBuilderUser` just reading
`publicKey`/`niceLevel` back out of it -- was rejected because it leaves
the receiving-side options sitting inside the namespace of a service that
might be entirely disabled. A receive-only host would have to set
`services.nixDynamicBuilders.peers.<name>.publicKey` despite
`services.nixDynamicBuilders.enable` staying `false`, which both reads
backwards and means the two services were never actually independent --
just independently-ignorable.

**`services.openssh.enable = lib.mkDefault true` inside
`userConfig.nix`.** Discovered by actually writing and testing a
receive-only example (`examples/receive-only.nix`), not anticipated in
advance: `environment.etc."ssh/authorized_keys.d/<user>"` -- the
mechanism `authorizedKeys.keys` actually depends on -- is itself gated
behind `services.openssh.enable` in nixpkgs' own `sshd.nix`. The
dispatching side never needed to care (it only ever runs the `ssh`
client, never a local server), so this never came up before. The
receiving side's entire purpose is accepting SSH connections, so silently
doing nothing because an admin forgot a separate
`services.openssh.enable = true` elsewhere would defeat the point.
`mkDefault`, not an unconditional set: an admin who's configured
`services.openssh` explicitly (either value) still wins.

## Alternatives considered

**A sub-option instead of a second top-level service**, e.g.
`services.nixDynamicBuilders.acceptConnections.enable`. Rejected: this
still ties the receiving side's existence to the dispatching side's own
option tree (and its `enable` would most naturally still gate on the
parent's `enable` too, reintroducing the exact coupling this change
removes) rather than making it a true peer namespace a receive-only host
can use without touching `services.nixDynamicBuilders` at all.

## Consequence

A fully bidirectional peer relationship is configured in up to two
places per host instead of one: `services.nixDynamicBuilders.peers.bob`
on host A (to dispatch to bob) and
`services.nixDynamicBuilderUser.peers.bob` on host A (to accept from
bob), each independently optional. Nothing enforces that the same name
is used in both trees for what a human considers "the same peer" --
that's a documentation convention (see `userOptions.nix`'s own `peers`
description), not a structural guarantee.
