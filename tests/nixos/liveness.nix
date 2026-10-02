# End-to-end proof, not just eval-level: two real VMs, a real SSH probe,
# a real atomic file rewrite, and nix-daemon's own live-reread behavior
# asserted from the outside (grep the machines file), not assumed.
#
# testSshKey/testSshPublicKey are a throwaway keypair generated solely
# for this test -- no real-world access, safe to commit (see
# tests/fixtures/test-ed25519's own header).
#
# sopsStub below exists only because this module expects a real
# sops-nix installation to provide `config.sops.secrets.*.path` --
# pulling in real sops-nix + an age identity just to satisfy that one
# option in a test would be substantially more machinery than the thing
# being tested. The stub defines the identical option shape
# (`path`/`owner`/`mode`) so the module's own code is exercised exactly
# as written, just backed by a plain activation-script-dropped file
# instead of a real encrypted secret.
let
  testSshKey = ../fixtures/test-ed25519;
  testSshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDj28OND0mtMrx61UE2LXJt4EnQ0kDg5N+ORYze91Esl nixos-remote-builder-liveness-module test fixture (not a real secret)";

  sopsStub =
    { lib, ... }:
    {
      options.sops.secrets = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              path = lib.mkOption { type = lib.types.str; };
              owner = lib.mkOption {
                type = lib.types.str;
                default = "root";
              };
              mode = lib.mkOption {
                type = lib.types.str;
                default = "0400";
              };
            };
          }
        );
        default = { };
      };
      config.sops.secrets."nix-dynamic-builders/ssh-key".path = "/root/test-nix-dynamic-builders-ssh-key";
      config.system.activationScripts.testSshKeyFixture = ''
        install -m 0400 -o root -g root ${testSshKey} /root/test-nix-dynamic-builders-ssh-key
      '';
    };

  peerConfig = hostname: {
    imports = [
      ../../nixosModule
      sopsStub
    ];
    services.openssh.enable = true;
    services.nixDynamicBuilders = {
      enable = true;
      peers.${hostname} = {
        maxJobs = 2;
        publicKey = testSshPublicKey;
      };
    };
  };
in
{
  name = "nix-dynamic-builders-liveness";

  containers = {
    alice = peerConfig "bob";
    bob = peerConfig "alice";
  };

  testScript = ''
    start_all()
    # sshd is socket-activated: sshd.socket listens at boot, sshd.service
    # only starts lazily on the first real connection -- assert on the unit
    # that's actually active at this point, not the one that isn't yet.
    alice.wait_for_unit("sshd.socket")
    bob.wait_for_unit("sshd.socket")

    # Force a tick now instead of waiting out the real 60s timer.
    alice.succeed("systemctl start nix-dynamic-builders-refresh-bob.service")
    alice.wait_until_succeeds("grep -q bob /var/lib/nix-dynamic-builders/machines")

    # Peer goes down -> next tick drops it back to an empty file
    # (silent fall-back-to-local), not a stale stuck entry. Stop the
    # socket, not sshd.service -- the latter is a transient per-connection
    # unit under socket activation and usually isn't even loaded.
    bob.succeed("systemctl stop sshd.socket")
    alice.succeed("systemctl start nix-dynamic-builders-refresh-bob.service")
    alice.wait_until_succeeds("test ! -s /var/lib/nix-dynamic-builders/machines")
  '';
}
