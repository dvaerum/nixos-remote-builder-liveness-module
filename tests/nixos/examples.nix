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

    # custom-probe-tuning.nix: the global cadence override AND the
    # per-peer SSH-tunable overrides both actually reach their rendered
    # units, not just the peer that stayed on fleet-wide defaults.
    customProbeTuning.succeed(
        "systemctl cat nix-dynamic-builders-refresh-workstation.timer | "
        "grep -q OnUnitActiveSec=5m"
    )
    customProbeTuning.succeed(
        "systemctl cat nix-dynamic-builders-refresh-remote-site.service | "
        "grep -q CONNECT_TIMEOUT=10"
    )
    customProbeTuning.succeed(
        "systemctl cat nix-dynamic-builders-refresh-remote-site.service | "
        "grep -q PROBE_RETRIES=5"
    )
    customProbeTuning.succeed(
        "systemctl cat nix-dynamic-builders-refresh-workstation.service | "
        "grep -q CONNECT_TIMEOUT=2"
    )
  '';
}
