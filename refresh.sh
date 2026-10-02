# Probe the peer's liveness and atomically rewrite the dynamic nix builders
# file. Runs as a oneshot, triggered by nix-dynamic-builders-refresh.timer --
# every tick is fully self-contained (no state persisted between runs): up to
# three quick SSH connect attempts decide THIS tick's answer, then the file is
# replaced via write-temp-then-rename so nix-daemon (which re-reads it fresh
# on every build dispatch, per src/libstore/machines.cc -- no caching) never
# observes a half-written file.
#
# Nix's `builders = @file` has no signature-verification step for build
# results (unlike a substituter path) -- the peer is trusted exactly as much
# as running sudo on it locally. See README.md's "Trust model" section.

set -euo pipefail

reachable=0
for attempt in 1 2 3; do
  # The receiving side's authorized_keys forces its own command (restrict +
  # command=) regardless of what we ask to run here -- "true" is never what
  # actually executes, the real nix-store --serve is, and IT exits non-zero
  # against a probe that sends no real protocol data. So a plain "did ssh
  # exit 0" check can never see a reachable peer as reachable. ssh itself
  # reserves exit code 255 for a connection/auth-level failure and passes
  # the remote command's own exit status through otherwise (ssh(1)) -- so
  # reachability is "ssh didn't fail at the ssh level", not "the forced
  # remote command happened to succeed", which we don't control and isn't
  # the thing being tested.
  rc=0
  ssh \
    -F /dev/null \
    -i "$SSH_KEY_PATH" \
    -o ConnectTimeout=2 \
    -o BatchMode=yes \
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
    -o StrictHostKeyChecking=accept-new \
    "${PEER_USER}@${PEER_HOSTNAME}" true 2>/dev/null || rc=$?
  if [ "$rc" -ne 255 ]; then
    reachable=1
    break
  fi
  if [ "$attempt" -lt 3 ]; then
    sleep 1.5
  fi
done

mkdir -p "$(dirname "$MACHINES_FILE")"
tmp="$(mktemp "${MACHINES_FILE}.XXXXXX")"

if [ "$reachable" = "1" ]; then
  # storeUri system sshKey maxJobs speedFactor supportedFeatures mandatoryFeatures publicHostKey
  # Host key field is "-": we rely on the pinned known_hosts file above
  # (TOFU via accept-new) rather than pre-pinning a key -- see
  # docs/decisions/0002-tofu-host-key-checking.md.
  printf 'ssh-ng://%s@%s %s %s %s %s %s %s -\n' \
    "$PEER_USER" "$PEER_HOSTNAME" "$PEER_SYSTEM" "$SSH_KEY_PATH" \
    "$PEER_MAX_JOBS" "$PEER_SPEED_FACTOR" "$PEER_SUPPORTED_FEATURES" "$PEER_MANDATORY_FEATURES" \
    > "$tmp"
  echo "nix-dynamic-builders: ${PEER_HOSTNAME} reachable -- added as a builder"
else
  : > "$tmp"
  echo "nix-dynamic-builders: ${PEER_HOSTNAME} unreachable after 3 attempts -- dropped"
fi

mv -f "$tmp" "$MACHINES_FILE"
