# A fleet where a peer genuinely differs from this module's defaults and
# from other peers -- not just two identical entries with different names
# (see multi-peer.nix for that simpler case).
{ ... }:
{
  services.nixDynamicBuilders = {
    enable = true;
    sshKey = true;

    # A security-conscious fleet: nix-dynamic-builders-show-key needs sudo
    # on this host. Overridable per-peer (peers.<name>.publicKeyWorldReadable)
    # for a peer with its own distinct key -- not useful here, since
    # arm-builder reuses the shared default key below.
    publicKeyWorldReadable = false;

    peers.arm-builder = {
      # Reached by IP, not DNS -- the attribute name above is just this
      # host's own label for it, unrelated to how it's actually reached.
      hostname = "10.0.0.50";
      system = "aarch64-linux";
      maxJobs = 4;
      speedFactor = 2; # genuinely faster than this fleet's other peers
      # Fallback only (live-fetched normally, see services.nixDynamicBuilders.peers's
      # own supportedFeatures description) -- stated here just because this
      # peer's real feature set differs from the module's ["kvm" "big-parallel"]
      # default (no KVM on this particular board).
      supportedFeatures = [ "big-parallel" ];
      # This host only ever dispatches a build here if the build itself
      # explicitly asks for "aarch64-only-build" -- gating by policy, not by
      # a fact about the peer (see docs/decisions/0003).
      mandatoryFeatures = [ "aarch64-only-build" ];
    };
  };

  # Accepting connections FROM arm-builder is a separate, independently-enableable
  # service -- see services.nixDynamicBuilderUser.enable's description.
  services.nixDynamicBuilderUser = {
    enable = true;
    peers.arm-builder.publicKey = "placeholder -- replaced via nix-dynamic-builders-show-key";
  };
}
