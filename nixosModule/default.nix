# Dynamic nix remote-builder liveness tracking -- gives `nix.settings.builders`
# a live, self-updating machine list instead of a static one: a systemd timer
# probes the peer's SSH reachability every 60s and atomically rewrites a plain
# runtime file; nix-daemon re-reads that file fresh on every single build
# dispatch (confirmed against src/libstore/machines.cc -- zero caching), so a
# peer going up or down takes effect on the very next build, no daemon
# restart needed. See README.md for the full mechanism and setup, and
# docs/decisions/ for the design rationale (why a live `@file` over a
# static `nix.buildMachines`, per-host identity keys and why
# `supportedFeatures` is live-fetched, why TOFU host-key checking for
# now, why the receiving-side account is its own independently-enableable
# service).
{
  imports = [
    ./options.nix
    ./config.nix
    ./userOptions.nix
    ./userConfig.nix
  ];
}
