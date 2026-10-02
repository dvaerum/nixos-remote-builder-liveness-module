{
  config,
  lib,
  options,
  ...
}:

let
  cfg = config.services.nixDynamicBuilders;

  # Several options below are declared twice -- once globally, once as a
  # per-peer override inheriting that global value -- with an identical
  # shape every time. One helper for the override half instead of
  # repeating it (the global half still varies enough in
  # description/default to stay written out separately). The type is
  # read back from the already-declared global option rather than
  # re-typed here: narrowing the global enum (say) then automatically
  # narrows every peer override too, instead of needing a second,
  # easy-to-forget manual edit. extraDescription covers the one override
  # (publicKeyWorldReadable) that needs a caveat sentence beyond the
  # generic one-liner, so it doesn't have to sit hand-rolled outside the
  # helper just for that.
  mkPeerOverride =
    globalName:
    {
      extraDescription ? "",
    }:
    lib.mkOption {
      type = options.services.nixDynamicBuilders.${globalName}.type;
      default = cfg.${globalName};
      defaultText = lib.literalExpression "config.services.nixDynamicBuilders.${globalName}";
      description = "Per-peer override of the global `${globalName}`." + extraDescription;
    };
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
        Global only -- see docs/decisions/0003 for why this isn't per-peer.
      '';
    };

    probeIntervalSec = lib.mkOption {
      type = lib.types.str;
      default = "60s";
      description = "How often each peer is re-probed after the first tick (systemd time span). Global only -- see docs/decisions/0003.";
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
                description = "The peer's Nix `system` string, as it appears in the machines-file line.";
              };
              maxJobs = lib.mkOption {
                type = lib.types.int;
                description = ''
                  The peer's own maxJobs. For a dual-use machine (a workstation
                  someone also works on interactively, not a dedicated build box),
                  size this below its real thread count to leave headroom.
                '';
              };
              speedFactor = lib.mkOption {
                type = lib.types.int;
                default = 1;
                description = "The peer's relative speed factor, as it appears in the machines-file line -- see `nix.buildMachines`'s `speedFactor`.";
              };
              supportedFeatures = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [
                  "kvm"
                  "big-parallel"
                ];
                description = ''
                  Fallback only -- each tick replaces this with the peer's
                  real, live `nix config show system-features`, queried over
                  the same restricted SSH channel (see
                  `docs/decisions/0003`); this value is only used if that
                  live query fails.
                '';
              };
              mandatoryFeatures = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = ''
                  Features a build must explicitly request before this peer
                  is even considered for it -- this host's own dispatching
                  policy toward the peer, not a fact about the peer, so
                  unlike `supportedFeatures` it's never fetched live. See
                  `docs/decisions/0003`.
                '';
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
              publicKeyWorldReadable = mkPeerOverride "publicKeyWorldReadable" {
                extraDescription = " Only meaningful when this peer has its own distinct key (`sshKey` isn't `false`) -- a peer reusing the shared default key can't have its own say over that one shared file's permissions.";
              };
              connectTimeout = mkPeerOverride "connectTimeout" { };
              strictHostKeyChecking = mkPeerOverride "strictHostKeyChecking" { };
              probeRetries = mkPeerOverride "probeRetries" { };
              probeRetryDelay = mkPeerOverride "probeRetryDelay" { };
              niceLevel = mkPeerOverride "niceLevel" { };
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
