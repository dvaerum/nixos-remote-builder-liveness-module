# Skipping the two-step bootstrap (see README Setup) by supplying a
# pre-existing keypair instead of self-generating -- both sides'
# publicKey are known upfront, so a single deploy is enough.
#
# sshKeyPath defaults to the realistic path a real user would actually
# have (a keypair generated once with `ssh-keygen -t ed25519 -N "" -f
# nix-dynamic-builders_ed25519`, sitting next to their own config) --
# tests/nixos/examples.nix overrides it to point at the repo's own
# throwaway test fixture instead, so this example evaluates for real
# rather than against a file that doesn't exist in this repo.
#
# `toString sshKeyPath`, not `"${sshKeyPath}"`: interpolating a path value
# directly copies it into the store first, so appending `.pub` afterwards
# would point at a `.pub` sibling of that store copy -- which was never
# itself copied, so it doesn't exist. `toString` renders the original
# on-disk path as a plain string first, so `.pub` resolves against the
# real sibling file, same footgun `sshKey`'s own path-literal handling
# documents in docs/decisions/0003's "known limitation".
{
  sshKeyPath ? ./nix-dynamic-builders_ed25519,
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
    peers.host-b.publicKey = builtins.readFile "${toString sshKeyPath}.pub";
  };
}
