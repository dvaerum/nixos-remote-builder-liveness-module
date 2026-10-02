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

  # peerHostnames: list of OTHER hosts this container should probe. Plain
  # builtins only (map/listToAttrs) -- this file is a bare attrset handed
  # straight to pkgs.testers.nixosTest, not a module function, so there's
  # no `lib` in scope here the way there is inside the module configs below.
  peerConfig = peerHostnames: {
    imports = [
      ../../nixosModule
      sopsStub
    ];
    services.openssh.enable = true;
    services.nixDynamicBuilders = {
      enable = true;
      peers = builtins.listToAttrs (
        map (hostname: {
          name = hostname;
          value = {
            maxJobs = 2;
            publicKey = testSshPublicKey;
          };
        }) peerHostnames
      );
    };
  };
in
{
  name = "nix-dynamic-builders-liveness";

  containers = {
    # alice has two peers -- the real proof that fragment-per-peer writes
    # don't clobber each other, not just that the single-peer path works.
    alice = peerConfig [
      "bob"
      "carol"
    ];
    bob = peerConfig [ "alice" ];
    carol = peerConfig [ "alice" ];
  };

  testScript = ''
    start_all()
    # sshd is socket-activated: sshd.socket listens at boot, sshd.service
    # only starts lazily on the first real connection -- assert on the unit
    # that's actually active at this point, not the one that isn't yet.
    alice.wait_for_unit("sshd.socket")
    bob.wait_for_unit("sshd.socket")
    carol.wait_for_unit("sshd.socket")

    # Force both of alice's peer ticks now instead of waiting out the real
    # 60s timer, and confirm BOTH fragments land in the assembled file --
    # not just that one peer's write doesn't crash, but that two peers'
    # independent fragment writes genuinely coexist.
    alice.succeed("systemctl start nix-dynamic-builders-refresh-bob.service")
    alice.succeed("systemctl start nix-dynamic-builders-refresh-carol.service")
    alice.wait_until_succeeds("grep -q bob /run/nix-dynamic-builders/machines")
    alice.wait_until_succeeds("grep -q carol /run/nix-dynamic-builders/machines")

    # bob goes down -> next tick drops ONLY bob's line (silent fall-back-to-
    # local for that one direction), carol's fragment is untouched. Stop
    # the socket, not sshd.service -- the latter is a transient per-
    # connection unit under socket activation and usually isn't even loaded.
    bob.succeed("systemctl stop sshd.socket")
    alice.succeed("systemctl start nix-dynamic-builders-refresh-bob.service")
    alice.wait_until_succeeds("! grep -q bob /run/nix-dynamic-builders/machines")
    alice.succeed("grep -q carol /run/nix-dynamic-builders/machines")
  '';
}
