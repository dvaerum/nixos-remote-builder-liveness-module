# Skipping the two-step bootstrap (see README Setup) by supplying a
# pre-existing keypair instead of self-generating -- both sides'
# publicKey are known upfront, so a single deploy is enough.
#
# sshKeyPath is a plain STRING, not a Nix path literal (`./...`) -- a
# path literal copies the private key into the world-readable Nix
# store (services.nixDynamicBuilders.sshKey has a hard assertion
# against this, see docs/decisions/0003's "known limitation"). The
# default below is illustrative only (a typical real on-disk location
# on whatever machine actually builds this config -- reading its own
# ".pub" sibling at eval time only works when that's a real, unmoved
# file, never actually exercised by this repo's own tests).
#
# publicKey defaults to deriving from sshKeyPath's own sibling, but
# tests/nixos/examples.nix passes it directly instead: its own
# sshKeyPath override points at a file already copied into the Nix
# store under its own content hash (needed so the runtime SSH_KEY_PATH
# env var resolves to a real, materialized file), which breaks the
# sibling-derivation trick (the ".pub" was never copied alongside it
# under that same hash) -- supplying publicKey directly sidesteps ever
# evaluating that broken derivation at all.
{
  sshKeyPath ? "/etc/nix-dynamic-builders/nix-dynamic-builders_ed25519",
  publicKey ? builtins.readFile "${sshKeyPath}.pub",
  ...
}:
{
  services.nixDynamicBuilders = {
    enable = true;
    sshKey = sshKeyPath;
    peers.host-b.maxJobs = 8;
  };

  # Accepting connections FROM host-b is a separate, independently-enableable
  # service -- see services.nixDynamicBuilderUser.enable's description.
  services.nixDynamicBuilderUser = {
    enable = true;
    peers.host-b.publicKey = publicKey;
  };
}
