{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.nixDynamicBuilderUser;

  featureQuerySentinel = import ./featureQuerySentinel.nix;

  dispatchScript = pkgs.writeShellApplication {
    name = "nix-dynamic-builders-dispatch";
    runtimeInputs = [
      pkgs.nix
      pkgs.coreutils
    ];
    text = builtins.readFile ../dispatch.sh;
  };
in
{
  config = lib.mkIf cfg.enable {
    # This service's entire purpose is accepting SSH connections -- unlike
    # the dispatching side (which only ever needs the `ssh` client, never a
    # locally-running server), a host enabling this one has no other reason
    # not to also run sshd. mkDefault, not an unconditional override: an
    # admin who's explicitly configured services.openssh themselves (any
    # value) still wins.
    services.openssh.enable = lib.mkDefault true;

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
      # dispatchScript's positional contract: $1 = niceLevel, $2 =
      # featureQuerySentinel -- order matters (see dispatch.sh's own
      # `nice_level="$1"; feature_query_command="$2"`); a reorder here
      # without a matching reorder there wouldn't fail loudly, it would
      # just make the feature-query branch permanently unreachable.
      openssh.authorizedKeys.keys = lib.mapAttrsToList (
        _: peerCfg:
        ''command="${lib.getExe dispatchScript} ${toString peerCfg.niceLevel} ${featureQuerySentinel}",restrict ${peerCfg.publicKey}''
      ) cfg.peers;
    };

    # nix-store --serve needs to import build-input paths without a
    # per-path signature check.
    nix.settings.trusted-users = [ "nix-remote-builder" ];
  };
}
