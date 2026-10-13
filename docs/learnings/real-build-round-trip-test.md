# Why there's no "a real build actually completes" test (yet)

`tests/nixos/liveness.nix` and `docs/decisions/0011` prove the `ssh-ng://`
wire protocol is correct -- real SSH auth, real forced-command dispatch,
a confirmed RED/GREEN regression test. What they don't prove is a real
build *completing*: `nix-daemon`'s own store-write path fails inside
these `systemd-nspawn` containers, independent of anything this module
does. This is what was tried, and where it stopped.

## The blocker

Any real connection that reaches `nix-daemon`'s `LocalStore` (not just
build dispatch -- even the simplest `nix store ping`) triggers
`LocalStore::makeStoreWritable()`, which tries to remount `/nix/store`
writable. In these nspawn containers that fails:

```
nix-daemon: unexpected Nix daemon error: error: changing ownership of
path "/nix/store": Operation not permitted
```

Confirmed this is **not specific to this module or this test** -- it's
a known, already-fixed upstream Nix bug:
[NixOS/nix#9705](https://github.com/NixOS/nix/issues/9705), fixed by
[PR #15324](https://github.com/NixOS/nix/pull/15324) (merged
2026-03-09, commit `e73d0e3f`): the old `makeStoreWritable()` passed
only `MS_REMOUNT | MS_BIND` to `mount()`, dropping every other flag;
flags locked in a user namespace (`nodev`, `nosuid` -- exactly what
nspawn sets) can't be dropped, so the kernel silently leaves the store
read-only and the later `chown()` throws `EPERM`.

## Why it's not just a version bump

Confirmed directly against this project's pinned `nixpkgs`
(2026-10-01 snapshot): `pkgs.nix` resolves to `nixVersions.nix_2_34`
(2.34.8), which still has the pre-fix code -- nixpkgs hasn't bumped
that specific alias past the March fix yet. `pkgs.nixVersions.git`
(`2.36pre20260912_203f85b2`) **does** already contain the fix
(confirmed by reading its actual source), but overriding `pkgs.nix` to
use the merged patch directly on 2.34.8 hit a different wall: nixpkgs
is mid-transition to a "per-component" build for `nix`
(`pkgs/tools/package-management/nix/common-meson.nix`'s own comment:
*"Called for Nix == 2.28. Transitional until we always use
per-component packages"*) -- the top-level `pkgs.nix` attribute is a
thin wrapper with no real unpacked source of its own to patch against
(`prePatch` diagnostics showed `patchPhase` running in a directory
containing only `.` and `./env-vars`). The real C++ source lives in a
separate component derivation not yet identified.

## Where this was left

Reverted all of it -- no patch file, no new check, nothing half-working
committed. `docs/decisions/0011`'s protocol-level test remains the
ceiling for this test suite.

**Revisit when:** a routine `nix flake update` bumps this project's
`nixpkgs` pin past whatever commit nixpkgs eventually bumps
`nixVersions.nix_2_34` (or `pkgs.nix`'s default alias) past the #9705
fix -- at that point a plain `nix-build --max-jobs 0` round-trip
assertion can likely be added to the existing nspawn suite directly,
no patching or package overrides needed at all. Check `pkgs.nix.version`
against the fix's merge date (2026-03-09) first, since that's a one-line
confirmation of whether this is still blocked.

**Update: path (b) was tried end to end (wiring `nix.package =
pkgs.nixVersions.git` directly, no patching) -- still fails, with a
different, more precise finding.** `nixVersions.git` (confirmed present
at `2.36pre20261010_979a87c9`, source re-checked, fix still there) gets
past whatever `makeStoreWritable`'s own remount logic does without
throwing -- but a *separate*, later `chown()` in `LocalStore`'s own
constructor (`src/libstore/local-store.cc`, the step that normalizes
`/nix/store`'s ownership to the configured `build-users-group`,
unrelated to the remount-to-writable step `#9705` fixes) still throws
`EPERM` with the exact same message. This means nspawn's specific
presentation of the read-only bind-mount doesn't make Nix's own
`statvfs`-based "is this actually read-only" check agree with what the
kernel actually enforces the way the original bug report's scenario
did -- a narrower, different mismatch between this test backend and
the fix's own assumptions, not something `nixVersions.git` alone
resolves. Reverted again (same discipline as before: nothing
half-working committed).

The one remaining un-tried path: (a) find and patch the actual
per-component source derivation `pkgs.nix` wraps (nixpkgs' own
mid-transition to "per-component" packaging for `nix`, not yet
identified which derivation actually holds the real source tree).
Given two separate attempts have now hit two separate, non-overlapping
walls, the next session attempting this should budget real
investigation time for nixpkgs' own packaging structure specifically,
not just another Nix-version swap.
