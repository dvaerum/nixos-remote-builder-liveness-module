{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nixDynamicBuilders;

  featureList = features: if features == [ ] then "-" else lib.concatStringsSep "," features;

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

  # name -> resolved .pub path, consumed by nix-dynamic-builders-show-key.
  # "_default" is only listed when a shared default key actually exists.
  keyMapFile = pkgs.writeText "nix-dynamic-builders-keymap" (
    lib.concatStringsSep "\n" (
      lib.optional (cfg.sshKey != false) "_default\t${resolveDefaultKeyPath}.pub"
      ++ lib.mapAttrsToList (
        peerName: peerCfg: "${peerName}\t${resolveSshKeyPath peerName peerCfg.sshKey}.pub"
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

  dispatchScript = pkgs.writeShellApplication {
    name = "nix-dynamic-builders-dispatch";
    runtimeInputs = [
      pkgs.nix
      pkgs.coreutils
    ];
    text = builtins.readFile ../dispatch.sh;
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
    # ── receiving side: what the PEER connects to on THIS host ─────────
    users.groups.nix-remote-builder = { };
    users.users.nix-remote-builder = {
      isSystemUser = true;
      group = "nix-remote-builder";
      home = "/var/lib/nix-remote-builder";
      createHome = true;
      # sshd execs the authorized_keys command= forced command THROUGH
      # the account's shell (shell -c '<command>') -- NixOS's own
      # default shell for a plain isSystemUser is nologin, which would
      # refuse to run anything and print "This account is currently
      # not available." regardless of how the SSH auth itself goes.
      # Confirmed the hard way: this exact failure mode showed up in
      # this module's own nixosTest the first time anything actually
      # exercised a live peer end-to-end. A real shell here is safe:
      # restrict,command= below is what actually confines this key,
      # not the shell.
      shell = pkgs.bashInteractive;
      # A NixOS system user with no password option set gets "!" in
      # /etc/shadow -- shadow(5)'s administratively-LOCKED sentinel, not
      # just "no valid password". Recent OpenSSH (confirmed: 10.5p1) refuses
      # any login, pubkey included, once it sees that lock -- this isn't a
      # PAM check (UsePAM is irrelevant here), so restrict/command= alone
      # don't save you from it. "*" means the same "can never match" as
      # "!" for auth purposes but isn't the locked sentinel, so SSH-key
      # login is allowed again.
      hashedPassword = "*";
      # restrict,command= means this key can ONLY ever invoke dispatchScript
      # (which itself only ever runs nix-store --serve or a features query,
      # see dispatch.sh) -- never a shell, never arbitrary commands, even if
      # the private key half of this pair leaked. One line per configured
      # peer -- all mapping to this same shared account, since the forced
      # command already fully constrains each key regardless of which
      # account it lands on.
      openssh.authorizedKeys.keys = lib.mapAttrsToList (
        _: peerCfg:
        ''command="${lib.getExe dispatchScript} ${toString peerCfg.niceLevel}",restrict ${peerCfg.publicKey}''
      ) cfg.peers;
    };

    # nix-store --serve needs to import build-input paths without a
    # per-path signature check.
    nix.settings.trusted-users = [ "nix-remote-builder" ];

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
    # 0711: world can traverse by exact (documented, fixed) filename --
    # ssh_key.pub -- but can't list the directory. Actual read access to
    # any given file is gated by that file's own mode, set below per key.
    systemd.tmpfiles.rules = [
      "d ${cfg.baseDir} 0711 root root -"
      "d ${cfg.baseDir}/ssh-keys 0711 root root -"
    ];

    systemd.services = lib.mapAttrs' (
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
          Environment = [
            "PEER_HOSTNAME=${peerCfg.hostname}"
            "PEER_USER=nix-remote-builder"
            "PEER_SYSTEM=${peerCfg.system}"
            "PEER_MAX_JOBS=${toString peerCfg.maxJobs}"
            "PEER_SPEED_FACTOR=${toString peerCfg.speedFactor}"
            "PEER_SUPPORTED_FEATURES=${featureList peerCfg.supportedFeatures}"
            "PEER_MANDATORY_FEATURES=${featureList peerCfg.mandatoryFeatures}"
            "SSH_KEY_PATH=${resolveSshKeyPath peerName peerCfg.sshKey}"
            "PUBLIC_KEY_MODE=${if effectivePublicKeyWorldReadable peerCfg then "0644" else "0600"}"
            "KNOWN_HOSTS_FILE=${cfg.knownHostsFile}"
            "CONNECT_TIMEOUT=${toString peerCfg.connectTimeout}"
            "STRICT_HOST_KEY_CHECKING=${peerCfg.strictHostKeyChecking}"
            "PROBE_RETRIES=${toString peerCfg.probeRetries}"
            "PROBE_RETRY_DELAY=${peerCfg.probeRetryDelay}"
            "FRAGMENT_FILE=${cfg.runtimeDir}/machines.d/${peerName}"
            "MACHINES_FILE=${cfg.runtimeDir}/machines"
          ];
        };
      }
    ) cfg.peers;

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
