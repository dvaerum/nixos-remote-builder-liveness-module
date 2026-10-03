# 0007: Public keys are served from runtimeDir, never from baseDir

## Decision

`refresh.sh` serves each peer's current public key from a new location
under `runtimeDir` (`runtimeDir/publickeys/<name>.pub`), not from a
`.pub` file living next to the private key in `baseDir`. Every tick,
unconditionally and regardless of key source: if `SSH_KEY_PATH.pub`
exists as a natural sibling (always true for a self-generated key), its
content is copied there; otherwise the public half is derived directly
from the private key (`ssh-keygen -y -f "$SSH_KEY_PATH"`) and written
there instead.

`baseDir` and `baseDir/ssh-keys` drop from `0711` to `0700` -- nothing
under `baseDir` is public-facing anymore, so there's no reason for any
non-root traversal access to it at all.
`nix-dynamic-builders-show-key` is unchanged: it still only ever reads
one file per name from `KEY_MAP_FILE`, which now simply always points
into `runtimeDir`.

A peer inheriting the shared default key (`sshKey == false`) writes into
the SAME shared `runtimeDir/publickeys/_default.pub` every other
inheriting peer also writes into -- mirroring exactly how they already
all resolve to the same shared *private* key file -- rather than its own
peer-named file, which nothing would ever read via `show-key --default`.
Only a peer with its own distinct key (`true` or a path/string) gets its
own file. Written via write-temp-then-rename, not a plain overwrite:
this shared file can be written concurrently by several peers' ticks,
the same concurrency class the private key's own generation already
guards against.

## Why

**A real deployment hit this: an admin-supplied key via sops-nix has no
`.pub` sibling, and `show-key` reported it as "not generated yet" --
actively misleading.** sops-nix decrypts and manages the private half
alone; the public half isn't a secret worth deploying that way, so
nothing ever creates a matching `.pub` file next to it. The error
message was written for the self-generated case (where that assumption
holds) and gave the wrong explanation for this one.

**The fix belongs in `refresh.sh`, not in `show-key.sh`.** The first
draft of this fix had `show-key.sh` fall back to running `ssh-keygen -y`
itself when no `.pub` sibling existed -- which requires read access to
the private key. That's exactly backwards: `show-key.sh` is deliberately
invoked by arbitrary, possibly non-root callers (`publicKeyWorldReadable
= true` exists specifically so it doesn't need `sudo`), and it must
never be the thing touching private key material, regardless of
permissions. `refresh.sh` already legitimately reads `SSH_KEY_PATH`
every tick (it's used for the real `ssh` connection), so the derivation
belongs there -- a privileged operation done by the thing that's already
privileged, not plumbed out to a tool designed to need no privilege at
all.

**One unconditional runtime location, not two paths show-key has to
choose between.** An earlier version of this fix kept the natural
`.pub` sibling as a fast path and added a second, derived-cache path
under `baseDir` as a fallback -- which meant `baseDir` still needed a
`0711` traversal exception for `show-key` to reach the fallback file,
and `show-key.sh` needed new branching logic to try one path then the
other. Having `refresh.sh` unconditionally maintain exactly one
canonical copy under `runtimeDir` instead removes both: `show-key.sh`
goes back to its original, unmodified single-path check, and `baseDir`
can be `0700` with no exception carved out of it at all -- simpler and
more obviously correct than either of the two things it replaces.

## Alternatives considered

**`show-key.sh` derives the key itself via `ssh-keygen -y -f
<private-key-path>` when no `.pub` sibling exists.** Rejected outright --
see "Why" above. Flagged during review before landing, not shipped.

**A derived-cache path under `baseDir`, as a second fallback alongside
the natural sibling.** Considered and implemented, then reworked once
the single-runtime-location design above was worked out to be strictly
simpler for the same result. Rejected in favor of the one-location
design: two paths to maintain and check is pure accidental complexity
once a single always-fresh location works for every case.

## Consequence

A peer's public key is no longer visible by just reading `baseDir`
(because nothing public-facing lives there anymore) -- it only ever
exists under `runtimeDir`, which is ephemeral (tmpfs, wiped on reboot)
like everything else there. `nix-dynamic-builders-show-key` for a given
peer only returns the right answer after that peer's refresh tick has
run at least once since boot, same as it always has for self-generated
keys; this is now also true for the admin-supplied case, which
previously (incorrectly) looked like it should work immediately.
