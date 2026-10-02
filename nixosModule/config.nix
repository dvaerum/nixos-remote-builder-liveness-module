{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nixDynamicBuilders;

  featureList = features: if features == [ ] then "-" else lib.concatStringsSep "," features;

  refreshScript = pkgs.writeShellApplication {
    name = "nix-dynamic-builders-refresh";
    runtimeInputs = [
      pkgs.openssh
      pkgs.coreutils
    ];
    text = builtins.readFile ../refresh.sh;
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
      # restrict,command= means this key can ONLY ever invoke nix-store
      # --serve -- never a shell, never arbitrary commands, even if the
      # private key half of this pair leaked. One line per configured
      # peer -- all mapping to this same shared account, since the forced
      # command already fully constrains each key regardless of which
      # account it lands on.
      openssh.authorizedKeys.keys = lib.mapAttrsToList (
        _: peerCfg: ''command="nice -19 nix-store --serve --write",restrict ${peerCfg.publicKey}''
      ) cfg.peers;
    };

    # nix-store --serve needs to import build-input paths without a
    # per-path signature check.
    nix.settings.trusted-users = [ "nix-remote-builder" ];

    # ── dispatching side: what THIS host uses to reach the peer ─────────
    sops.secrets."nix-dynamic-builders/ssh-key" = {
      owner = "root"; # nix-daemon dispatches builds as root
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/nix-dynamic-builders 0750 root root -"
    ];

    systemd.services = lib.mapAttrs' (
      peerName: peerCfg:
      lib.nameValuePair "nix-dynamic-builders-refresh-${peerName}" {
        description = "Probe ${peerCfg.hostname} liveness and rewrite the dynamic nix builders file";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe refreshScript;
          Environment = [
            "PEER_HOSTNAME=${peerCfg.hostname}"
            "PEER_USER=nix-remote-builder"
            "PEER_SYSTEM=${peerCfg.system}"
            "PEER_MAX_JOBS=${toString peerCfg.maxJobs}"
            "PEER_SPEED_FACTOR=${toString peerCfg.speedFactor}"
            "PEER_SUPPORTED_FEATURES=${featureList peerCfg.supportedFeatures}"
            "PEER_MANDATORY_FEATURES=${featureList peerCfg.mandatoryFeatures}"
            "SSH_KEY_PATH=${config.sops.secrets."nix-dynamic-builders/ssh-key".path}"
            "KNOWN_HOSTS_FILE=/var/lib/nix-dynamic-builders/known_hosts"
            "MACHINES_FILE=/var/lib/nix-dynamic-builders/machines"
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
          OnBootSec = "30s";
          OnUnitActiveSec = "60s";
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
    nix.settings.builders = "@/var/lib/nix-dynamic-builders/machines";
  };
}
