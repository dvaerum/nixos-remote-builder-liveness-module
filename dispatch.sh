# Forced authorized_keys command (restrict + command=) for every configured
# peer's key -- sshd always runs exactly this, ignoring whatever the client
# actually asked for, and passes the client's real request through
# $SSH_ORIGINAL_COMMAND. Branches on that to also answer a live
# supportedFeatures query over the same restricted channel, instead of
# host A's config carrying a static guess at host B's features that can
# silently drift from reality.
#
# $1 is this peer's nice level, $2 is the feature-query sentinel -- both
# baked into the authorized_keys line itself (one line per peer, each
# able to set its own nice level; the sentinel is the same Nix-level
# value refresh.sh is also given, not a separately hand-typed copy of
# it) since sshd's forced command doesn't get refresh.sh's environment.
#
# The default branch matters: nix-daemon constructs its OWN ssh-ng://
# dispatch call independently of this module, so anything that ISN'T the
# exact feature-query sentinel below must still fall through to the real
# serve command, or live builds break.

set -euo pipefail

nice_level="$1"
feature_query_command="$2"

case "${SSH_ORIGINAL_COMMAND:-}" in
  "$feature_query_command")
    # --extra-experimental-features: don't depend on the receiving host's
    # own nix.conf happening to have nix-command enabled -- this dispatcher
    # picks its own invocation, not the peer's ambient config.
    exec nix --extra-experimental-features nix-command config show system-features
    ;;
  *)
    exec nice -"$nice_level" nix-store --serve --write
    ;;
esac
