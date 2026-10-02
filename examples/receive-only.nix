# A build-serving-only machine -- accepts builds dispatched from peers but
# never dispatches anywhere itself. services.nixDynamicBuilders is never
# even mentioned: the two services are fully independent, so there's
# nothing to explicitly disable.
{ ... }:
{
  services.nixDynamicBuilderUser = {
    enable = true;
    # The dispatcher's public key -- printed by nix-dynamic-builders-show-key
    # run on the DISPATCHER side (it has no meaning to generate or print here:
    # this host never dispatches anywhere, so it has no outbound identity of
    # its own).
    peers.dispatcher.publicKey = "placeholder -- replaced with the dispatcher's own public key";
  };
}
