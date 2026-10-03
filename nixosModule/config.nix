{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nixDynamicBuilders;

  featureList = features: if features == [ ] then "-" else lib.concatStringsSep "," features;

  featureQuerySentinel = import ./featureQuerySentinel.nix;

  # The shared default key's own path, independent of any specific peer --
  # used both by peers that inherit it (resolveSshKeyPath below) and by
  # show-key's own "_default" entry (keyMapFile below). Keeping this in one
  # place is deliberate: it was previously inlined separately in both
  # spots, and the keyMapFile copy had drifted to always assume
  # `cfg.sshKey == true` (the generated-key convention path), silently
  # wrong whenever `cfg.sshKey` was instead an explicit pre-existing path --
  # `nix-dynamic-builders-show-key --default` failed outright in exactly
  # that (commonly-used) configuration.
  resolveDefaultKeyPath =
    if cfg.sshKey == true then "${cfg.baseDir}/ssh-keys/_default/ssh_key" else cfg.sshKey;

  # peerKey is a peer's own `sshKey` value (false | true | path/string).
  # false means "no override -- use the shared default", which itself can
  # be disabled (cfg.sshKey == false); that combination is caught by the
  # assertions below, not here -- this still needs to return SOME string so
  # evaluating it doesn't throw and mask the nicer assertion message.
  resolveSshKeyPath =
    peerName: peerKey:
    if peerKey == false then
      (
        if cfg.sshKey == false then
          "/dev/null/no-ssh-key-configured-for-${peerName}"
        else
          resolveDefaultKeyPath
      )
    else if peerKey == true then
      "${cfg.baseDir}/ssh-keys/${peerName}/ssh_key"
    else
      peerKey;

  # A peer reusing the shared default key (sshKey == false) can't have its
  # OWN say over that file's world-readability -- it's one file potentially
  # shared by several peers, so the global toggle applies uniformly there.
  # Only a peer with its own distinct key (sshKey == true or a path/string)
  # can meaningfully override it for itself.
  effectivePublicKeyWorldReadable =
    peerCfg:
    if peerCfg.sshKey == false then cfg.publicKeyWorldReadable else peerCfg.publicKeyWorldReadable;

  # Where refresh.sh serves a public key from -- always runtimeDir
  # (ephemeral), never baseDir (persistent, private-key-only). Populated
  # fresh every tick regardless of key source: a cat of the natural .pub
  # sibling for a self-generated key, or a direct ssh-keygen -y
  # derivation for an admin-supplied key with no sibling (a
  # sops-nix-decrypted secret, say -- sops manages the private half
  # alone, since the public half isn't a secret worth deploying that
  # way). One unconditional location either way means show-key.sh never
  # needs to know or care which case it is, and never needs any access to
  # baseDir at all (see docs/decisions/0007).
  runtimePubKeyPath = name: "${cfg.runtimeDir}/publickeys/${name}.pub";

  # Mirrors resolveSshKeyPath's own false/true/string branching, but for
  # where the PUBLIC half is served from rather than the private half's
  # own path: a peer inheriting the shared default key (peerKey == false)
  # writes into the SAME shared "_default" runtime file every other
  # inheriting peer also writes into (exactly like they all resolve to
  # the SAME shared private key file) -- not its own peer-named file,
  # which nothing would ever read via `show-key --default`. Only a peer
  # with its own distinct key (true or a path/string) gets its own.
  resolvePublicKeyPath =
    peerName: peerKey:
    if peerKey == false then runtimePubKeyPath "_default" else runtimePubKeyPath peerName;

  # name -> runtime public-key path, consumed by nix-dynamic-builders-
  # show-key. "_default" is only listed when a shared default key
  # actually exists.
  keyMapFile = pkgs.writeText "nix-dynamic-builders-keymap" (
    lib.concatStringsSep "\n" (
      lib.optional (cfg.sshKey != false) "_default\t${runtimePubKeyPath "_default"}"
      ++ lib.mapAttrsToList (
        peerName: peerCfg: "${peerName}\t${resolvePublicKeyPath peerName peerCfg.sshKey}"
      ) cfg.peers
    )
  );

  refreshScript = pkgs.writeShellApplication {
    name = "nix-dynamic-builders-refresh";
    runtimeInputs = [
      pkgs.openssh
      pkgs.coreutils
    ];
    text = builtins.readFile ../refresh.sh;
  };

  showKeyScript = pkgs.writeShellApplication {
    name = "nix-dynamic-builders-show-key";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.fzf
    ];
    # KEY_MAP_FILE is the one piece of per-install data show-key.sh needs
    # that isn't a per-invocation flag -- injected as a single line ahead
    # of the otherwise-static script body, same pattern as refresh.sh's
    # env-var wiring, just without a systemd unit to set it through.
    text = "KEY_MAP_FILE=${keyMapFile}\n" + builtins.readFile ../show-key.sh;
  };
in
{
  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (peerName: peerCfg: {
      assertion = !(peerCfg.sshKey == false && cfg.sshKey == false);
      message = ''
        services.nixDynamicBuilders.peers.${peerName}.sshKey: no key available --
        the shared default (services.nixDynamicBuilders.sshKey) is disabled
        (false) and this peer didn't set its own.
      '';
    }) cfg.peers;

    environment.systemPackages = [ showKeyScript ];

    # ── dispatching side: what THIS host uses to reach the peer ─────────
    # 0700: private key material only lives under baseDir, never a public
    # key (those are served from runtimeDir instead, see runtimePubKeyPath
    # above) -- nothing here needs any non-root access at all, so there's
    # no traversal exception to carve out.
    systemd.tmpfiles.rules = [
      "d ${cfg.baseDir} 0700 root root -"
      "d ${cfg.baseDir}/ssh-keys 0700 root root -"
    ];

    systemd.services =
      (lib.mapAttrs' (
        peerName: peerCfg:
        lib.nameValuePair "nix-dynamic-builders-refresh-${peerName}" {
          description = "Probe ${peerCfg.hostname} liveness and rewrite the dynamic nix builders file";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe refreshScript;
            # Shared by every peer's refresh service (same name): systemd
            # refcounts a RuntimeDirectory used by multiple units, tearing it
            # down only once none of them reference it. Preserve=yes on top
            # of that stops it being wiped between THIS unit's own oneshot
            # ticks too -- without it the machines file (and sibling peers'
            # fragments) would vanish every time any single peer's tick
            # completes, not just at reboot.
            RuntimeDirectory = "nix-dynamic-builders";
            RuntimeDirectoryPreserve = "yes";
            # Grouped by the phases refresh.sh itself reads these in (key
            # gen -> ssh_opts -> probe loop -> feature query -> fragment
            # write -> reassembly), not alphabetically or by category --
            # so "which concern owns this var" is visible without cross-
            # referencing refresh.sh's own comments. Order WITHIN a group
            # isn't significant (refresh.sh doesn't read every var in a
            # group in this exact sequence).
            Environment = [
              # Key generation
              "SSH_KEY_PATH=${resolveSshKeyPath peerName peerCfg.sshKey}"
              "PUBLIC_KEY_MODE=${if effectivePublicKeyWorldReadable peerCfg then "0644" else "0600"}"
              "PUBLIC_KEY_PATH=${resolvePublicKeyPath peerName peerCfg.sshKey}"
              # Connection options (ssh_opts)
              "CONNECT_TIMEOUT=${toString peerCfg.connectTimeout}"
              "KNOWN_HOSTS_FILE=${cfg.knownHostsFile}"
              "STRICT_HOST_KEY_CHECKING=${peerCfg.strictHostKeyChecking}"
              # Probe loop
              "PEER_USER=nix-remote-builder"
              "PEER_HOSTNAME=${peerCfg.hostname}"
              "PROBE_RETRIES=${toString peerCfg.probeRetries}"
              "PROBE_RETRY_DELAY=${peerCfg.probeRetryDelay}"
              # Feature query
              "PEER_SUPPORTED_FEATURES=${featureList peerCfg.supportedFeatures}"
              "FEATURE_QUERY_COMMAND=${featureQuerySentinel}"
              # Fragment write
              "PEER_MAX_JOBS=${toString peerCfg.maxJobs}"
              "PEER_SPEED_FACTOR=${toString peerCfg.speedFactor}"
              "PEER_MANDATORY_FEATURES=${featureList peerCfg.mandatoryFeatures}"
              "FRAGMENT_FILE=${cfg.runtimeDir}/machines.d/${peerName}"
              # Reassembly
              "MACHINES_FILE=${cfg.runtimeDir}/machines"
            ];
          };
        }
      ) cfg.peers)
      // {
        # Liveness detection alone does NOT guarantee a real build
        # dispatch will actually reach a peer -- confirmed via a real
        # deployment and Nix's own source (src/libstore/ssh.cc,
        # src/libstore/machines.cc, Nix 2.34.8): the probe's SSH
        # connection and nix-daemon's REAL ssh-ng:// build-dispatch
        # connection are two entirely separate trust paths. The probe
        # explicitly uses its own private knownHostsFile (refresh.sh's
        # `-F /dev/null -o UserKnownHostsFile=...`); the machines-file
        # line's host-key field is deliberately left as "-" (TOFU, not
        # pre-pinned -- see docs/decisions/0002), so nix-daemon's own
        # connection never gets a matching UserKnownHostsFile override
        # and falls back entirely to ambient system SSH config, which
        # this module never touches. On a host with no other SSH trust
        # already established for the peer, the daemon's connection
        # fails outright (non-interactive, can't prompt) -- confirmed
        # reproducible, see docs/decisions/0008.
        #
        # NIX_SSHOPTS is read first, before anything else, for every
        # ssh-ng:// connection nix-daemon makes (ssh.cc's
        # addCommonSSHOpts) -- pointing it at the SAME file the probe
        # already TOFU-populates closes the gap with one shared trust
        # source, not a second one. Daemon-wide, not per-peer, and so
        # lives alongside the per-peer refresh units here rather than
        # inside the mapAttrs' above: Nix has no per-machine ssh-options
        # field at all, so this is the only lever available regardless.
        nix-daemon.environment.NIX_SSHOPTS = "-o UserKnownHostsFile=${cfg.knownHostsFile} -o StrictHostKeyChecking=accept-new";
      };

    systemd.timers = lib.mapAttrs' (
      peerName: peerCfg:
      lib.nameValuePair "nix-dynamic-builders-refresh-${peerName}" {
        description = "Periodic ${peerCfg.hostname} liveness probe for dynamic nix builders";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.probeOnBootSec;
          OnUnitActiveSec = cfg.probeIntervalSec;
        };
      }
    ) cfg.peers;

    # nixpkgs' own nix-remote-build.nix forces `nix.settings.builders =
    # null` whenever distributedBuilds is false (its default) -- a real
    # conflicting definition against ours, not just an inert default
    # (caught by this module's own nixosTest, not assumed). Enabling
    # this module inherently means "use distributed builds", so this
    # isn't a side effect the consumer needs to separately remember.
    nix.distributedBuilds = true;
    nix.settings.builders = "@${cfg.runtimeDir}/machines";
  };
}
