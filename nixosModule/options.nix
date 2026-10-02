{ config, lib, ... }:

let
  cfg = config.services.nixDynamicBuilders;
in
{
  options.services.nixDynamicBuilders = {
    enable = lib.mkEnableOption "dynamic nix remote-builder liveness tracking";

    baseDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/nix-dynamic-builders";
      description = ''
        Persistent state directory (survives reboot): SSH keys
        (`ssh-keys/<peer-name>/`, `ssh-keys/_default/`) and `known_hosts`.
      '';
    };

    knownHostsFile = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.baseDir}/known_hosts";
      defaultText = lib.literalExpression ''"''${config.services.nixDynamicBuilders.baseDir}/known_hosts"'';
      description = "TOFU known_hosts file scoped to this mechanism alone -- see docs/decisions/0002.";
    };

    runtimeDir = lib.mkOption {
      type = lib.types.path;
      default = "/run/nix-dynamic-builders";
      description = ''
        Ephemeral runtime directory (tmpfs, recreated fresh every boot):
        the assembled `machines` file nix-daemon reads and each peer's own
        fragment. Liveness has no meaning across a reboot, so this lives
        outside `baseDir` on purpose.
      '';
    };

    sshKey = lib.mkOption {
      type = lib.types.either lib.types.bool (lib.types.either lib.types.path lib.types.str);
      # Deliberately no default -- every install must pick one of the three
      # meanings below, rather than silently inheriting "generate one".
      description = ''
        The shared default identity key used by any peer that doesn't set
        its own `peers.<name>.sshKey`:

        - `true`: generate one at `baseDir/ssh-keys/_default/ssh_key` the
          first time it's needed, if it doesn't already exist.
        - `false`: no shared default -- every peer must set its own key, or
          evaluation fails naming the peer that didn't.
        - a path or string: use this exact pre-existing key as the shared
          default.
      '';
    };

    publicKeyWorldReadable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this host's own generated/configured public keys are
        readable by any local user (so `nix-dynamic-builders-show-key` just
        works) or root-only (so the command needs sudo). Public keys aren't
        secret, so `true` is the default; `peers.<name>.publicKeyWorldReadable`
        inherits this unless a peer overrides it.
      '';
    };

    connectTimeout = lib.mkOption {
      type = lib.types.int;
      default = 2;
      description = "Seconds `ssh -o ConnectTimeout` waits per probe attempt.";
    };

    strictHostKeyChecking = lib.mkOption {
      type = lib.types.enum [
        "yes"
        "accept-new"
        "no"
      ];
      default = "accept-new";
      description = ''
        `ssh -o StrictHostKeyChecking` for the probe. "accept-new" is
        TOFU -- see docs/decisions/0002. `"ask"` is deliberately not an
        option here (excluded by explicit choice, not a technical
        requirement -- `BatchMode=yes`, which is always on, would make it
        fail rather than hang either way).
      '';
    };

    probeRetries = lib.mkOption {
      type = lib.types.int;
      default = 3;
      description = "SSH connect attempts per tick before declaring a peer unreachable.";
    };

    probeRetryDelay = lib.mkOption {
      type = lib.types.str;
      default = "1.5";
      description = "Seconds to sleep between failed attempts (passed straight to `sleep`, fractional values are fine).";
    };

    niceLevel = lib.mkOption {
      type = lib.types.int;
      default = 19;
      description = "`nice` priority for the receiving side's `nix-store --serve` -- a scheduling courtesy, not a security control.";
    };

    probeOnBootSec = lib.mkOption {
      type = lib.types.str;
      default = "30s";
      description = ''
        How soon after boot the first probe tick fires (systemd time span).
        Global only -- see docs/decisions for why this isn't per-peer.
      '';
    };

    probeIntervalSec = lib.mkOption {
      type = lib.types.str;
      default = "60s";
      description = "How often each peer is re-probed after the first tick (systemd time span). Global only.";
    };

    peers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              hostname = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = ''
                  The OTHER host's hostname -- the machine this host probes
                  and, if reachable, dispatches builds to. Defaults to the
                  attribute name (e.g. `peers.bob` probes "bob"); only set
                  this when the peer's reachable name differs from whatever
                  you choose to call it here.
                '';
              };
              system = lib.mkOption {
                type = lib.types.str;
                default = "x86_64-linux";
              };
              maxJobs = lib.mkOption {
                type = lib.types.int;
                description = ''
                  The peer's own maxJobs. For a dual-use machine (a workstation
                  someone also works on interactively, not a dedicated build box),
                  size this below its real thread count to leave headroom --
                  see docs/decisions/0001 for the reasoning.
                '';
              };
              speedFactor = lib.mkOption {
                type = lib.types.int;
                default = 1;
              };
              supportedFeatures = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [
                  "kvm"
                  "big-parallel"
                ];
              };
              mandatoryFeatures = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
              };
              publicKey = lib.mkOption {
                type = lib.types.str;
                description = ''
                  The peer's public key (ed25519, authorized_keys line format --
                  just the key material, no command= prefix), authorized to
                  connect to THIS host as the nix-remote-builder user and dispatch
                  builds here. Deliberately NOT shipped with this module: it's
                  fleet-specific identity, not mechanism -- generate your own
                  keypair and set this from your own host configuration. See
                  README.md's Setup section.
                '';
              };
              sshKey = lib.mkOption {
                type = lib.types.either lib.types.bool (lib.types.either lib.types.path lib.types.str);
                default = false;
                description = ''
                  This peer's own identity key, overriding the shared
                  default (`services.nixDynamicBuilders.sshKey`):

                  - `false` (default): no override -- use the shared
                    default, or fail evaluation if the shared default is
                    itself disabled (`false`).
                  - `true`: generate a key distinct to THIS peer at
                    `baseDir/ssh-keys/<name>/ssh_key`, ignoring the shared
                    default entirely.
                  - a path or string: use this exact pre-existing key for
                    this peer only.
                '';
              };
              publicKeyWorldReadable = lib.mkOption {
                type = lib.types.bool;
                default = cfg.publicKeyWorldReadable;
                defaultText = lib.literalExpression "config.services.nixDynamicBuilders.publicKeyWorldReadable";
              };
              connectTimeout = lib.mkOption {
                type = lib.types.int;
                default = cfg.connectTimeout;
                defaultText = lib.literalExpression "config.services.nixDynamicBuilders.connectTimeout";
              };
              strictHostKeyChecking = lib.mkOption {
                type = lib.types.enum [
                  "yes"
                  "accept-new"
                  "no"
                ];
                default = cfg.strictHostKeyChecking;
                defaultText = lib.literalExpression "config.services.nixDynamicBuilders.strictHostKeyChecking";
              };
              probeRetries = lib.mkOption {
                type = lib.types.int;
                default = cfg.probeRetries;
                defaultText = lib.literalExpression "config.services.nixDynamicBuilders.probeRetries";
              };
              probeRetryDelay = lib.mkOption {
                type = lib.types.str;
                default = cfg.probeRetryDelay;
                defaultText = lib.literalExpression "config.services.nixDynamicBuilders.probeRetryDelay";
              };
              niceLevel = lib.mkOption {
                type = lib.types.int;
                default = cfg.niceLevel;
                defaultText = lib.literalExpression "config.services.nixDynamicBuilders.niceLevel";
              };
            };
          }
        )
      );
      default = { };
      description = ''
        The set of peer machines this host probes and may dispatch builds
        to, keyed by an arbitrary name of your choosing (used in unit
        names, the show-key command, and the on-disk key/fragment layout).
      '';
    };
  };
}
