# 0001: A liveness-probed `@file`, not a static `nix.buildMachines`

## Decision

Drive `nix.settings.builders` from a plain runtime file
(`/var/lib/nix-dynamic-builders/machines`), rewritten every 60s by a
systemd timer that probes the peer's SSH reachability, rather than the
built-in `nix.buildMachines`/`nix.distributedBuilds` option (which
renders to a static machines list baked into the system closure at
build time).

## Why

This module exists for a two-machine *personal* fleet where the second
machine isn't always on -- a laptop someone actively uses, not a
dedicated always-on build box. With a static `nix.buildMachines`, every
build dispatched to that peer while it happens to be asleep or offline
just hangs (SSH connect timeout) or fails outright, with no fallback.
Re-running `nixos-rebuild switch` on the *other* host every time the
peer's availability changes isn't a realistic workflow.

`nix.settings.builders = "@<path>"` sidesteps this because of a
specific, verified fact about Nix's own implementation: per
`src/libstore/machines.cc`, that file is read fresh via a plain
`readFile` on **every build dispatch**, not loaded once and cached at
daemon startup. A systemd timer can therefore rewrite the file based on
live reachability, and the very next build after a tick picks up the
change -- no daemon restart, no rebuild, no rebuild-and-switch cycle on
either host.

## Alternatives considered

**A FIFO/pipe instead of a plain file**, so the probe could push
updates instead of the daemon re-reading on a schedule. Tested directly
against a real `nix-daemon`: `readFile` on a pipe either hangs forever
(if the writer keeps its file descriptor open, so EOF never arrives) or
hangs on the *next* `open()` call (if the writer closes to deliver EOF,
since a pipe blocks opening for read until a writer attaches). A plain
regular file is the only primitive with "always has a complete answer,
whenever asked" semantics -- which is exactly what a build dispatch
happening at an arbitrary moment needs.

**`ALTER DATABASE`-style in-place mutation via some long-lived
daemon/socket talking to nix-daemon directly.** Nix has no such API;
the `@file` mechanism is the documented, intended extension point for
exactly this kind of dynamic list, not a workaround bolted onto an
unrelated feature.

## Consequence

The `@file` contents are plain-text, non-store data living outside the
Nix store on purpose -- anything that needs to change between rebuilds
(not at rebuild time) belongs in a mutable runtime file like this one,
not baked into the system closure.
