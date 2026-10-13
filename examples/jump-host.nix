# A peer only reachable through a bastion -- NIX_SSHOPTS has no per-peer
# field (it's daemon-wide), so this is the only lever for "a jump host for
# one peer but not another"; see docs/decisions/0010.
{ ... }:
{
  services.nixDynamicBuilders = {
    enable = true;
    sshKey = true;

    # The bastion's OWN Host block and identity -- needed because
    # ProxyJump re-invokes ssh as a separate process that reads this
    # same shared file for the bastion's own connection, not secure-site's.
    # Global, not per-peer: the bastion isn't itself a configured peer.
    extraSshConfig = [
      "Host bastion.example.com"
      "  IdentityFile /etc/nix-dynamic-builders/bastion_ed25519"
    ];

    peers.secure-site = {
      hostname = "10.0.1.50";
      maxJobs = 4;
      # Rendered into this peer's own `Host` block in the shared ssh_config
      # file both the probe and nix-daemon's real build dispatch read --
      # applies ONLY to connections to secure-site, never to any other
      # configured peer.
      extraSshConfig = [ "ProxyJump bastion.example.com" ];
    };
  };

  services.nixDynamicBuilderUser = {
    enable = true;
    peers.secure-site.publicKey = "placeholder -- replaced via nix-dynamic-builders-show-key";
  };
}
