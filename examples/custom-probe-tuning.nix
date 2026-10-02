# Tuning the probe itself -- a slower/flakier link to one specific peer
# gets a longer per-attempt timeout and more retries, without changing
# the fleet-wide defaults every other peer still uses, plus a slower
# fleet-wide probe cadence (the one knob that's global-only -- see
# docs/decisions/0003 for why per-peer cadence wasn't worth the extra
# option surface).
{ ... }:
{
  services.nixDynamicBuilders = {
    enable = true;
    sshKey = true;

    # Less aggressive than the 30s/60s default -- a fleet that doesn't
    # need sub-minute failover latency can trade it for less SSH noise.
    probeOnBootSec = "1m";
    probeIntervalSec = "5m";

    peers = {
      # Fleet-wide defaults are fine for this one.
      workstation = {
        maxJobs = 8;
        publicKey = "placeholder -- replaced via nix-dynamic-builders-show-key";
      };

      # A peer reached over a slower/less reliable link needs more
      # patience per attempt and more attempts before being declared
      # unreachable -- a fact about THIS peer's network, not a
      # fleet-wide policy change.
      remote-site = {
        maxJobs = 4;
        publicKey = "placeholder -- replaced via nix-dynamic-builders-show-key";
        connectTimeout = 10;
        probeRetries = 5;
        probeRetryDelay = "3";
        niceLevel = 15; # a shared, busier box -- be a little less polite
      };
    };
  };
}
