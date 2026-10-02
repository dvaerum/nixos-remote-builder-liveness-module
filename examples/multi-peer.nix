# A host with two independent peers -- the actual point of peers being
# an attrsOf rather than one fixed slot (see docs/decisions/0003): each
# gets its own probing timer and its own fragment of the machines file,
# so one peer being asleep never affects the other.
{ ... }:
{
  services.nixDynamicBuilders = {
    enable = true;
    sshKey = true; # shared default identity, reused by both peers below

    peers = {
      workstation = {
        maxJobs = 8;
        publicKey = "placeholder -- replaced via nix-dynamic-builders-show-key";
      };
      laptop = {
        maxJobs = 4;
        # a smaller, often-offline machine -- liveness gating
        # is exactly why this one doesn't need its own
        # static nix.buildMachines entry
        publicKey = "placeholder -- replaced via nix-dynamic-builders-show-key";
      };
    };
  };
}
