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
    refresh_bin = multiPeer.succeed(
        "systemctl cat nix-dynamic-builders-refresh-workstation.service | grep '^ExecStart='"
    ).strip().split("=", 1)[1]

    multiPeer.succeed(f"""
        set -e
        key_dir=/var/lib/nix-dynamic-builders/ssh-keys/_default
        for i in $(seq 1 20); do
          rm -rf "$key_dir"
          ( SSH_KEY_PATH="$key_dir/ssh_key" PUBLIC_KEY_MODE=0644 {refresh_bin} || true ) &
          ( SSH_KEY_PATH="$key_dir/ssh_key" PUBLIC_KEY_MODE=0644 {refresh_bin} || true ) &
          wait
          if ! diff <(ssh-keygen -y -f "$key_dir/ssh_key") "$key_dir/ssh_key.pub" > /dev/null; then
            echo "mismatched keypair committed on attempt $i" >&2
            exit 1
          fi
        done
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
  '';
}
