# Proves the examples/ directory is more than prose: every example
# module is imported into its own real container here (one container
# per example, not merged into a single one -- several examples set
# the SAME global options like sshKey to different values, which would
# conflict if combined), so a rename/removal of an option any of them
# uses fails `nix flake check` immediately, not just the docs. Checks
# the rendered systemd units, not actual SSH connectivity -- that's
# already exhaustively covered by tests/nixos/liveness.nix; this is
# the lighter-weight floor keeping the example files themselves honest.
{ nixosModule }:
let
  examples = import ../../examples;
in
{
  name = "nix-dynamic-builders-examples";

  containers = {
    minimal = {
      imports = [
        nixosModule.nixosModules.default
        examples.minimal
      ];
    };
    multiPeer = {
      imports = [
        nixosModule.nixosModules.default
        examples.multiPeer
      ];
    };
    explicitKey = {
      imports = [
        nixosModule.nixosModules.default
        (import examples.explicitKey { sshKeyPath = ../fixtures/test-ed25519; })
      ];
    };
    customProbeTuning = {
      imports = [
        nixosModule.nixosModules.default
        examples.customProbeTuning
      ];
    };
    receiveOnly = {
      imports = [
        nixosModule.nixosModules.default
        examples.receiveOnly
      ];
    };
    heterogeneousFleet = {
      imports = [
        nixosModule.nixosModules.default
        examples.heterogeneousFleet
      ];
    };
  };

  testScript = ''
    start_all()

    # minimal.nix: the single peer's refresh timer is wired up.
    minimal.wait_for_unit("nix-dynamic-builders-refresh-host-b.timer")

    # multi-peer.nix: BOTH peers get their own independent timer -- the
    # actual point of peers being an attrsOf.
    multiPeer.wait_for_unit("nix-dynamic-builders-refresh-workstation.timer")
    multiPeer.wait_for_unit("nix-dynamic-builders-refresh-laptop.timer")

    # Both peers share the global default key (sshKey = true, neither
    # overrides it) and have no ordering dependency on each other -- a
    # real first-generation race is possible. Rather than rely on
    # systemd's own scheduling of the two real timers (unreliable to
    # provoke on demand), invoke the exact same installed script twice
    # directly as real concurrent background processes, racing for the
    # one shared key file, repeated several times (wiping the key
    # between attempts) to make a one-shot timing fluke unlikely to
    # hide a real bug. Only the two env vars the key-generation step
    # itself reads are set -- the rest of refresh.sh fails harmlessly
    # right after (missing env vars under `set -u`), which is fine
    # since only the key-generation side effect is under test here.
    # This IS coupled to key generation staying the first thing
    # refresh.sh does -- if a future change adds logic before it, this
    # test's "fails harmlessly after" assumption needs re-checking, not
    # just its own pass/fail.
    #
    # Nothing here confirms the two backgrounded processes actually
    # overlapped -- without that, a serialized scheduler could pass all
    # 20 attempts without ever exercising concurrent commit at all, a
    # false sense of coverage for exactly the bug this test exists to
    # catch. Start/end nanosecond markers bracket each invocation so the
    # test can assert genuine overlap was observed at least once across
    # the 20 attempts, not just "no mismatch happened to occur".
    refresh_bin = multiPeer.succeed(
        "systemctl cat nix-dynamic-builders-refresh-workstation.service | grep '^ExecStart='"
    ).strip().split("=", 1)[1]

    multiPeer.succeed(f"""
        set -e
        key_dir=/var/lib/nix-dynamic-builders/ssh-keys/_default
        overlap_seen=0
        for i in $(seq 1 20); do
          rm -rf "$key_dir"
          rm -f /tmp/race_start_a /tmp/race_end_a /tmp/race_start_b /tmp/race_end_b
          ( date +%s%N > /tmp/race_start_a
            SSH_KEY_PATH="$key_dir/ssh_key" PUBLIC_KEY_MODE=0644 {refresh_bin} || true
            date +%s%N > /tmp/race_end_a ) &
          ( date +%s%N > /tmp/race_start_b
            SSH_KEY_PATH="$key_dir/ssh_key" PUBLIC_KEY_MODE=0644 {refresh_bin} || true
            date +%s%N > /tmp/race_end_b ) &
          wait
          sa=$(cat /tmp/race_start_a); ea=$(cat /tmp/race_end_a)
          sb=$(cat /tmp/race_start_b); eb=$(cat /tmp/race_end_b)
          if [ "$sa" -le "$eb" ] && [ "$sb" -le "$ea" ]; then
            overlap_seen=1
          fi
          if ! diff <(ssh-keygen -y -f "$key_dir/ssh_key") "$key_dir/ssh_key.pub" > /dev/null; then
            echo "mismatched keypair committed on attempt $i" >&2
            exit 1
          fi
        done
        if [ "$overlap_seen" -ne 1 ]; then
          echo "race test never observed genuine process overlap across 20 attempts -- not a meaningful regression test" >&2
          exit 1
        fi
    """)

    # --default against a self-generated shared key: both halves exist
    # together on disk (refresh.sh created them), so unlike the
    # path-literal admin-provided case (not tested, see liveness.nix),
    # the .pub-sibling convention genuinely applies here.
    multiPeer.succeed(
        "diff <(nix-dynamic-builders-show-key --default) "
        "/var/lib/nix-dynamic-builders/ssh-keys/_default/ssh_key.pub"
    )

    # explicit-key.nix: the pre-existing fixture key is used as-is, not
    # self-generated -- proven by checking the rendered unit's own
    # SSH_KEY_PATH, not just that it evaluates.
    explicitKey.wait_for_unit("nix-dynamic-builders-refresh-host-b.timer")
    # Checking for the fixture's basename, not a predicted full store path --
    # Nix doesn't guarantee the same relative path literal resolves to the
    # identical store copy across every evaluation context, and the actual
    # thing this proves (the pre-existing fixture key was used, not a
    # generated one) doesn't depend on which store copy it is.
    explicitKey.succeed(
        "systemctl cat nix-dynamic-builders-refresh-host-b.service | "
        "grep -qE 'SSH_KEY_PATH=.*test-ed25519$'"
    )

    # custom-probe-tuning.nix: the global cadence override reaches the
    # rendered unit -- the one thing unique to this scenario. Per-peer
    # SSH-tunable overrides (connectTimeout/probeRetries reaching one
    # peer, the global default applying to another) are NOT re-asserted
    # here: liveness.nix's bob/carol pair already proves that exact fact,
    # and re-asserting it here would just duplicate it, undercutting this
    # file's own stated scope (checking rendered units, not re-proving
    # behavior liveness.nix already owns).
    customProbeTuning.succeed(
        "systemctl cat nix-dynamic-builders-refresh-workstation.timer | "
        "grep -q OnUnitActiveSec=5m"
    )

    # receive-only.nix: the nix-remote-builder account and its authorized_keys
    # line exist even though services.nixDynamicBuilders is never mentioned --
    # the whole point of the two services being independent. Real end-to-end
    # connectivity for this exact combination is already covered by
    # liveness.nix's "dan" container; this just keeps the example itself
    # honest against the current option schema.
    receiveOnly.succeed("id nix-remote-builder")
    receiveOnly.succeed("grep -q restrict /etc/ssh/authorized_keys.d/nix-remote-builder")
    receiveOnly.fail("command -v nix-dynamic-builders-show-key")

    # heterogeneous-fleet.nix: every option that differs from this module's
    # own defaults actually reaches the rendered unit -- hostname (by IP,
    # not the attribute name), speedFactor, maxJobs, supportedFeatures, and
    # mandatoryFeatures (system is entirely live-fetched, no static option
    # exists for it -- see docs/decisions/0006). None of these were
    # previously exercised by any example (only by liveness.nix's
    # hostname="localhost" and publicKeyWorldReadable=false per-peer
    # cases), so a rename/removal of any of them would otherwise only
    # fail through that one deep test, not here too.
    heterogeneousFleet.succeed(
        "systemctl cat nix-dynamic-builders-refresh-arm-builder.service | "
        "grep -q PEER_HOSTNAME=10.0.0.50"
    )
    heterogeneousFleet.succeed(
        "systemctl cat nix-dynamic-builders-refresh-arm-builder.service | "
        "grep -q PEER_SPEED_FACTOR=2"
    )
    heterogeneousFleet.succeed(
        "systemctl cat nix-dynamic-builders-refresh-arm-builder.service | "
        "grep -q PEER_MAX_JOBS=4"
    )
    heterogeneousFleet.succeed(
        "systemctl cat nix-dynamic-builders-refresh-arm-builder.service | "
        "grep -q PEER_SUPPORTED_FEATURES=big-parallel"
    )
    heterogeneousFleet.succeed(
        "systemctl cat nix-dynamic-builders-refresh-arm-builder.service | "
        "grep -q PEER_MANDATORY_FEATURES=aarch64-only-build"
    )
    # publicKeyWorldReadable = false set GLOBALLY (not per-peer, which
    # liveness.nix's selfgen peer already covers) still reaches a peer
    # that doesn't override it.
    heterogeneousFleet.succeed(
        "systemctl cat nix-dynamic-builders-refresh-arm-builder.service | "
        "grep -q PUBLIC_KEY_MODE=0600"
    )
  '';
}
