# 0006: `system` goes live too, with no static option at all

## Decision

`peers.<name>.system` is removed entirely -- there is no static,
admin-configured value for a peer's architecture anymore. The real value
is fetched every tick from the peer itself, over the same restricted SSH
channel already used for `supportedFeatures` (`docs/decisions/0003`), by
extending the existing feature-query sentinel in `dispatch.sh` to answer
with two lines -- `nix config show system` first, then `nix config show
system-features` -- instead of adding a second sentinel and a second SSH
round trip.

If a peer is reachable but the live `system` can't be determined (an
empty first line), that tick is treated exactly like an unreachable
peer: an empty fragment, no builder line written. There's no fallback to
fall back to.

## Why

**`docs/decisions/0003`'s own stated rule already covers this, and
originally should have.** *"A value that's a fact about a real external
system should track that system, not a value typed once and left to
drift."* `system` is exactly such a fact -- it just wasn't live-fetched
when 0003 was written, because the reasoning at the time focused on
drift *after* deployment (a feature flag toggled, a kernel module
loaded), and a peer's CPU architecture doesn't drift that way: changing
it means different hardware, which already means touching that peer's
Nix config for a dozen other reasons.

**That framing missed the more common failure mode: getting it wrong at
entry time, not later.** An admin can simply mistype `system =
"x86_64-linux"` on an aarch64 box, or copy-paste one peer's block as a
template for another and forget to change it. Nothing catches that --
it isn't "drift" in the sense of a value that was once correct silently
going stale, but it's the identical outcome (a static config value that
doesn't match reality) via the identical mechanism 0003 already solves
for `supportedFeatures`. Treating entry-time error and post-deployment
drift as different problems needing different solutions was the actual
mistake in 0003's original scope.

**No static fallback, unlike `supportedFeatures`.** The two fields don't
share a risk profile. Getting `supportedFeatures` wrong just changes
which builds nix-daemon considers this peer for -- safe on both sides of
wrong (under-advertising loses capacity; over-advertising fails one
job). Getting `system` wrong is structurally worse: it's the field
`src/libstore/machines.cc` uses to decide whether this peer is even a
candidate for a given derivation's platform at all, so a wrong static
guess can actively mis-route a build to an architecture-incompatible
machine, not just fail to use a peer that could've helped. A fallback
value is only useful if there's a real scenario where the live query
fails but a stale-but-still-correct guess is better than no builder line
at all -- and there isn't one here, so the extra option and the
nullable-type handling it would need have no real failure mode to earn
their keep.

**One SSH round trip, not two.** `exec` replaces the running process, so
it can only be the last command in `dispatch.sh`'s feature-query branch.
The `system` line is printed by an ordinary (non-`exec`'d) `nix config
show system` ahead of the final `exec nix ... config show
system-features` -- both lines land in the one SSH call `refresh.sh`
already makes once per tick, at no extra connection cost.

## Alternatives considered

**A second sentinel command, queried separately.** Rejected: doubles the
number of SSH connections per tick for no benefit -- both values are
cheap, static-until-queried facts about the same peer, answerable in one
round trip.

**A nullable `system` option, defaulting to `null`, used as an optional
fallback only when explicitly set.** Considered as a middle ground
before settling on removing the option entirely. Rejected: the only
real-world case where the live query could fail while the peer stays
reachable is a dispatch.sh version mismatch across the fleet -- and this
project explicitly doesn't support that (`AGENTS.md`'s "Versioning:
None" -- consumers pin by git revision, a breaking change just needs a
clear commit message, there's no cross-version compatibility story
anywhere else in this module either). Without that scenario, the option
would add a nullable type and extra branching in `refresh.sh` with
nothing it actually protects against.

## Consequence

A peer's architecture can no longer be verified or pre-declared purely
by reading that peer's own Nix config on the dispatching side --
confirming it requires either a live tick's result or running `nix
config show system` on the peer directly, exactly the same caveat 0003
already introduced for `supportedFeatures`. A peer that's reachable but
whose live `system` can't be determined for any reason is silently
dropped from this tick's machines file, with only the refresh service's
own log line ("reachable but couldn't determine its system -- dropped")
distinguishing that case from genuine unreachability.
