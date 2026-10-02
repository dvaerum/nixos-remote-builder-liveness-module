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
  # Read from the real .pub fixture file, not a second hand-typed copy of
  # the same value -- an admin-provided sshKey is expected to have a real
  # .pub sibling on disk (same as any ssh-keygen output), which is exactly
  # what nix-dynamic-builders-show-key --default reads. No `lib` in scope
  # in this file (see below) to trim the trailing newline the usual way,
  # so it's done with plain builtins instead.
  testSshPublicKeyFile = builtins.readFile ../fixtures/test-ed25519.pub;
  testSshPublicKey = builtins.substring 0 (
    builtins.stringLength testSshPublicKeyFile - 1
  ) testSshPublicKeyFile;

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
          };
        }) peerHostnames
      );
    };
    # Accepting connections from these same peers is a separate,
    # independently-enableable service -- see the "dan" container below for
    # the opposite combination (accepting without ever dispatching).
    services.nixDynamicBuilderUser = {
      enable = true;
      peers = builtins.listToAttrs (
        map (hostname: {
          name = hostname;
          value = {
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
        sshKey = true;
        publicKeyWorldReadable = false;
      };
      services.nixDynamicBuilderUser.peers.selfgen.publicKey = testSshPublicKey;
      # Non-default SSH tunables on just one peer, to prove per-peer
      # override actually reaches the rendered unit -- carol (unchanged)
      # is the control case showing the global default still applies.
      services.nixDynamicBuilders.peers.bob = {
        connectTimeout = 7;
        probeRetries = 5;
      };
      # A fourth peer, dan, who never dispatches anywhere -- only accepts.
      # Proves services.nixDynamicBuilders and services.nixDynamicBuilderUser
      # are genuinely independent: alice dispatches TO dan even though dan
      # itself never enables services.nixDynamicBuilders at all.
      services.nixDynamicBuilders.peers.dan.maxJobs = 1;
    };
    bob = {
      imports = [ (peerConfig [ "alice" ]) ];
      # A distinctive, real feature -- not present in alice's static
      # peers.bob.supportedFeatures default (["kvm" "big-parallel"]) --
      # to prove alice's assembled machines file picks this up live,
      # without alice's own config ever mentioning it.
      nix.settings.system-features = [
        "kvm"
        "big-parallel"
        "nix-dynamic-builders-test-marker"
      ];
    };
    carol = peerConfig [ "alice" ];

    # Receive-only: services.nixDynamicBuilderUser WITHOUT importing
    # peerConfig at all, so services.nixDynamicBuilders.enable stays at its
    # default (false) -- no refresh timers, no show-key command, no
    # /run/nix-dynamic-builders. Proves a host can accept builds from a peer
    # without ever dispatching to any peer of its own.
    dan = {
      imports = [ ../../nixosModule ];
      services.openssh.enable = true;
      services.nixDynamicBuilderUser = {
        enable = true;
        peers.alice.publicKey = testSshPublicKey;
      };
    };
  };

  testScript = ''
    start_all()
    # sshd is socket-activated: sshd.socket listens at boot, sshd.service
    # only starts lazily on the first real connection -- assert on the unit
    # that's actually active at this point, not the one that isn't yet.
    alice.wait_for_unit("sshd.socket")
    bob.wait_for_unit("sshd.socket")
    carol.wait_for_unit("sshd.socket")
    dan.wait_for_unit("sshd.socket")

    # dan: services.nixDynamicBuilderUser.enable alone, with
    # services.nixDynamicBuilders left at its default (false) -- the
    # receiving-side account exists, but none of the dispatching side does.
    dan.succeed("id nix-remote-builder")
    dan.fail("command -v nix-dynamic-builders-show-key")
    dan.fail("test -d /run/nix-dynamic-builders")

    # Force both of alice's real-peer ticks now instead of waiting out the
    # real 60s timer, and confirm BOTH fragments land in the assembled file
    # -- not just that one peer's write doesn't crash, but that two peers'
    # independent fragment writes genuinely coexist.
    alice.succeed("systemctl start nix-dynamic-builders-refresh-bob.service")
    alice.succeed("systemctl start nix-dynamic-builders-refresh-carol.service")
    alice.wait_until_succeeds("grep -q bob /run/nix-dynamic-builders/machines")
    alice.wait_until_succeeds("grep -q carol /run/nix-dynamic-builders/machines")

    # alice dispatches TO dan even though dan never enabled
    # services.nixDynamicBuilders itself -- the real end-to-end proof that
    # the two services are independent, not just that they evaluate
    # independently.
    alice.succeed("systemctl start nix-dynamic-builders-refresh-dan.service")
    alice.wait_until_succeeds("grep -q dan /run/nix-dynamic-builders/machines")

    # supportedFeatures is live-fetched from the peer, not echoed from
    # alice's own static config -- bob's real system-features includes a
    # marker alice's peers.bob.supportedFeatures never mentions, and it
    # shows up in the assembled file anyway.
    alice.succeed("grep -q nix-dynamic-builders-test-marker /run/nix-dynamic-builders/machines")

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

    # --default against a *path-literal* admin-provided sshKey (alice's
    # global sshKey = testSshKey) is NOT exercised here -- Nix copies a
    # referenced path into the store as its own independent, content-
    # hashed object, so "the resolved store path + .pub" does not find a
    # real sibling file the way it would on a real filesystem. That's a
    # genuine, currently-unsolved design gap for that one specific shape
    # of config, out of scope for this fix -- see
    # tests/nixos/examples.nix's multiPeer scenario for --default tested
    # against the *self-generated* case, where it works correctly (both
    # halves are created together on disk by refresh.sh itself, no Nix
    # store path arithmetic involved).

    # Bare invocation lists every known name.
    usage = alice.succeed("nix-dynamic-builders-show-key")
    for name in ["_default", "bob", "carol", "dan", "selfgen"]:
        assert name in usage, f"{name!r} missing from show-key's bare usage listing: {usage!r}"

    # Per-peer SSH tunable overrides actually reach the rendered unit...
    alice.succeed(
        "systemctl cat nix-dynamic-builders-refresh-bob.service | grep -q CONNECT_TIMEOUT=7"
    )
    alice.succeed(
        "systemctl cat nix-dynamic-builders-refresh-bob.service | grep -q PROBE_RETRIES=5"
    )
    # ...while a peer that didn't override still gets the global default.
    alice.succeed(
        "systemctl cat nix-dynamic-builders-refresh-carol.service | grep -q CONNECT_TIMEOUT=2"
    )
    alice.succeed(
        "systemctl cat nix-dynamic-builders-refresh-carol.service | grep -q PROBE_RETRIES=3"
    )
  '';
}
