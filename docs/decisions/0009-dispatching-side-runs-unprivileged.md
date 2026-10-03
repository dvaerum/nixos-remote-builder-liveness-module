# 0009: the dispatching side runs as a dedicated, unprivileged user

## Decision

`nix-dynamic-builders-refresh-<peer>.service` runs as a new, dedicated
system user/group (`nix-dynamic-builders`), not root. `baseDir`
(`/var/lib/nix-dynamic-builders`, holding `ssh-keys/`) is owned by this
user, mode `0700`.

## Why

Every operation `refresh.sh` performs on the dispatching side --
`ssh-keygen` into `baseDir`, writing the fragment/machines files under
`runtimeDir` (already scoped by systemd's own `RuntimeDirectory=`),
running `ssh` as a client -- needs no root privilege. Running as root was
a plain oversight (no `User=` set on the unit, so systemd's own default
filled in root), not a real requirement, confirmed by checking what each
line of the script actually touches.

This is a different user from `nix-remote-builder`
(`nixosModule/userOptions.nix`), which is the *receiving* side's account
-- a peer connects in as that user. `nix-dynamic-builders` is the
*dispatching* side's account, running `refresh.sh` itself and probing
out to peers. The two are never the same host's account for the same
relationship, though a single machine acting as both a peer and a
dispatcher runs both daemons side by side.

By contrast, `nix-daemon` genuinely needs root: it manages the whole Nix
store and sets up build sandboxes (mount namespaces, chroot, cgroups),
switching between unprivileged `nixbld1..N` build users per build --
intrinsic to Nix's own architecture, outside this module's control.
Confirmed via a real evaluated `nixosSystem` config that neither
service's `serviceConfig` had a `User=` key before this change, meaning
both defaulted to root purely by systemd's own fallback, not by any
explicit choice either service's definition made.

## Consequence

An admin-supplied key (e.g. a sops-nix-decrypted secret, no `.pub`
sibling) must now be made readable by `nix-dynamic-builders` explicitly
-- previously this worked unconditionally because root can read any
file regardless of ownership. For sops-nix this means setting the
secret's own `owner`; see README's "skip the bootstrap step" section.

The existing test suite caught two places that had baked in the old
"everything here runs as root" assumption and needed updating, not the
new code: a race test (`tests/nixos/examples.nix`) that invoked
`refresh.sh` directly to provoke a concurrent-generation race, leaving
root-owned key files the real (now unprivileged) service could no
longer read; and a synthetic admin-key fixture
(`tests/nixos/liveness.nix`'s `nopub` peer) installed without an
explicit owner. Both were fixed to match what a correct real-world setup
now requires, surfacing this exact permission boundary as a real,
reproducible test failure rather than leaving it undiscovered until a
production deploy.
