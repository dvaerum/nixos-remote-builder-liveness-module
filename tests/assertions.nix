# Fast, pure-eval checks that this module's own `assertions` entries
# actually fire for the configs they're meant to catch -- nothing
# exercised this at all before (confirmed: grepping the whole repo for
# the pre-existing "no key available" assertion turned up only its own
# definition, no test). No VM/container boot needed: NixOS's own
# `config.assertions` is a plain list, safe to inspect directly without
# triggering their enforcement (that only happens if something later
# forces `config.system.build.toplevel`, which nothing here does).
{
  lib,
  nixosModule,
  pkgs,
}:
let
  # `message` is matched as a substring, not full equality -- these
  # assertions wrap their text at a fixed column, so pinning the exact
  # wording here would make this test as fragile as the prose itself.
  fails =
    extraConfig: expectedSubstring:
    let
      sys = pkgs.nixos {
        imports = [ nixosModule.nixosModules.default ];
        services.nixDynamicBuilders = {
          enable = true;
          sshKey = "/tmp/placeholder-key";
        }
        // extraConfig;
      };
      failing = builtins.filter (a: a.assertion == false) sys.config.assertions;
      # Messages wrap at a fixed column -- collapse newlines to spaces
      # before matching, or a substring that happens to straddle a wrap
      # point looks "missing" even though the real message says it.
      normalize = s: lib.concatStringsSep " " (lib.splitString "\n" s);
    in
    builtins.any (a: lib.hasInfix expectedSubstring (normalize a.message)) failing;

  scenarios = {
    globalSshKeyPathLiteral = fails { sshKey = ./assertions.nix; } "got a Nix path literal";

    peerSshKeyPathLiteral = fails {
      peers.bob = {
        maxJobs = 1;
        sshKey = ./assertions.nix;
      };
    } "got a Nix path literal";

    noKeyAvailable = fails {
      sshKey = false;
      peers.bob.maxJobs = 1;
    } "no key available";

    invalidHostnameChars = fails {
      peers.bob = {
        maxJobs = 1;
        hostname = "bob,*";
      };
    } "not a valid hostname/IP";

    invalidPeerName = fails {
      peers."bob/evil".maxJobs = 1;
    } "unsafe to use in a systemd unit name";

    extraSshConfigNewline = fails {
      peers.bob = {
        maxJobs = 1;
        extraSshConfig = [ "ProxyCommand x\nHost *\nProxyCommand evil" ];
      };
    } "embedded newline";
  };

  failed = lib.filterAttrs (_: ok: !ok) scenarios;
in
assert (
  failed == { }
  || throw "assertions.nix: these scenarios did NOT produce the expected failing assertion: ${toString (lib.attrNames failed)}"
);
pkgs.runCommand "nix-dynamic-builders-assertions-fire-correctly" { } "touch $out"
