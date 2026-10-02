# End-to-end proof, not just eval-level: real containers, a real SSH
# probe, a real atomic file rewrite, and nix-daemon's own live-reread
# behavior asserted from the outside (grep the machines file), not
# assumed.
#
# testSshKey/testSshPublicKey are a throwaway keypair generated solely
# for this test -- no real-world access, safe to commit (see
# tests/fixtures/test-ed25519's own header). Used directly as an explicit
# `sshKey` path below: a real two-way trust relationship needs both sides
# to know the SAME keypair at build time, which only a fixed, pre-known
# key can satisfy -- self-generated keys are exercised separately (the
# "selfgen" peer below), in isolation, since there's no way to predict a
# runtime-generated key's public half at eval time to put in a peer's
# authorized_keys.
let
  testSshKey = ../fixtures/test-ed25519;
  testSshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDj28OND0mtMrx61UE2LXJt4EnQ0kDg5N+ORYze91Esl nixos-remote-builder-liveness-module test fixture (not a real secret)";

  # peerHostnames: list of OTHER hosts this container should probe. Plain
  # builtins only (map/listToAttrs) -- this file is a bare attrset handed
  # straight to pkgs.testers.nixosTest, not a module function, so there's
  # no `lib` in scope here the way there is inside the module configs below.
  peerConfig = peerHostnames: {
    imports = [ ../../nixosModule ];
    services.openssh.enable = true;
    services.nixDynamicBuilders = {
      enable = true;
      sshKey = testSshKey;
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
    # alice has two real peers -- the proof that fragment-per-peer writes
    # don't clobber each other, not just that the single-peer path works --
    # plus a third, synthetic "selfgen" peer purely to exercise self-
    # generated keys and nix-dynamic-builders-show-key in isolation (it's
    # never expected to actually authenticate -- see the file header).
    alice = {
      # `imports`, not `//` -- a shallow merge of two already-built attrsets
      # would let this attrset's own `services` key silently clobber
      # peerConfig's `services.openssh.enable` and all of
      # `services.nixDynamicBuilders`, since both sides define `services`.
      # `imports` lets the module system merge them properly instead.
      imports = [
        (peerConfig [
          "bob"
          "carol"
        ])
      ];
      services.nixDynamicBuilders.peers.selfgen = {
        hostname = "localhost";
        maxJobs = 1;
        publicKey = testSshPublicKey;
        sshKey = true;
        publicKeyWorldReadable = false;
      };
    };
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

    # Force both of alice's real-peer ticks now instead of waiting out the
    # real 60s timer, and confirm BOTH fragments land in the assembled file
    # -- not just that one peer's write doesn't crash, but that two peers'
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

    # Self-generated key: the tick itself doesn't need to succeed (nothing
    # trusts this synthetic peer's key), just needs to run once so refresh.sh's
    # generate-if-missing step fires.
    alice.succeed("systemctl start nix-dynamic-builders-refresh-selfgen.service || true")
    alice.succeed("test -s /var/lib/nix-dynamic-builders/ssh-keys/selfgen/ssh_key")
    alice.succeed("test -s /var/lib/nix-dynamic-builders/ssh-keys/selfgen/ssh_key.pub")

    # show-key prints exactly what's on disk.
    alice.succeed(
        "diff <(nix-dynamic-builders-show-key selfgen) "
        "/var/lib/nix-dynamic-builders/ssh-keys/selfgen/ssh_key.pub"
    )

    # publicKeyWorldReadable = false on this peer -> a non-root user can't
    # read the pub key file directly...
    alice.fail(
        "su nobody -s /bin/sh -c "
        "'cat /var/lib/nix-dynamic-builders/ssh-keys/selfgen/ssh_key.pub'"
    )
    # ...and show-key, run as that same non-root user, fails the same way
    # (no privilege logic of its own -- it's just the file permission).
    alice.fail("su nobody -s /bin/sh -c 'nix-dynamic-builders-show-key selfgen'")
  '';
}
