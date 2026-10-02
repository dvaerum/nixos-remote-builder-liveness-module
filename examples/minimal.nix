# Minimal usage -- one peer, self-generated key. Mirrors README's Setup
# step 1 (the publicKey placeholder gets replaced by
# nix-dynamic-builders-show-key's real output after first deploy, see
# README); proven to still evaluate against the current option schema
# by tests/nixos/examples.nix.
{ ... }:
{
  services.nixDynamicBuilders = {
    enable = true;
    sshKey = true; # generate on first use, no ssh-keygen/secrets manager needed
    peers.host-b.maxJobs = 8;
  };

  # Accepting connections FROM host-b is a separate, independently-enableable
  # service -- see services.nixDynamicBuilderUser.enable's description.
  services.nixDynamicBuilderUser = {
    enable = true;
    peers.host-b.publicKey = "placeholder -- replaced via nix-dynamic-builders-show-key";
  };
}
