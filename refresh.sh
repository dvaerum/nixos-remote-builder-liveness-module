# Probe the peer's liveness and atomically rewrite this peer's own fragment
# of the dynamic nix builders file, then reassemble the full file from
# every peer's current fragment. Runs as a oneshot, triggered by this
# peer's own nix-dynamic-builders-refresh-<peer>.timer -- every tick is
# fully self-contained (no state persisted between runs): up to three
# quick SSH connect attempts decide THIS tick's answer. Each peer only
# ever writes its OWN fragment file, never anyone else's -- so concurrent
# per-peer timers can't race each other -- and both the fragment write and
# the final reassembly go through write-temp-then-rename, so nix-daemon
# (which re-reads the assembled file fresh on every build dispatch, per
# src/libstore/machines.cc -- no caching) never observes a half-written
# file either way.
#
# Nix's `builders = @file` has no signature-verification step for build
# results (unlike a substituter path) -- the peer is trusted exactly as much
# as running sudo on it locally. See README.md's "Trust model" section.

set -euo pipefail

# Generate this peer's identity key on first use if nothing's there yet --
# shared-default keys can be raced by several peers' independent ticks, so
# generate into a scratch dir and lose gracefully (-n/no-clobber) if another
# tick already won.
key_dir="$(dirname "$SSH_KEY_PATH")"
if [ ! -e "$SSH_KEY_PATH" ]; then
  mkdir -p "$key_dir"
  chmod 0711 "$key_dir"
  tmpdir="$(mktemp -d)"
  ssh-keygen -q -t ed25519 -N "" -f "$tmpdir/key" < /dev/null
  mv -n "$tmpdir/key" "$SSH_KEY_PATH" || true
  mv -n "$tmpdir/key.pub" "${SSH_KEY_PATH}.pub" || true
  rm -rf "$tmpdir"
  echo "nix-dynamic-builders: generated a new SSH identity at ${SSH_KEY_PATH}"
fi
# The private half is never touched beyond generation (root-only via
# ssh-keygen's own default; an admin-provided key is the admin's own
# responsibility to protect) -- but the public half's access policy is
# re-applied every tick, so toggling publicKeyWorldReadable later takes
# effect on the next tick rather than only at first generation.
if [ -e "${SSH_KEY_PATH}.pub" ]; then
  chmod "$PUBLIC_KEY_MODE" "${SSH_KEY_PATH}.pub"
fi

reachable=0
for attempt in $(seq 1 "$PROBE_RETRIES"); do
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
    -o ConnectTimeout="$CONNECT_TIMEOUT" \
    -o BatchMode=yes \
    -o UserKnownHostsFile="$KNOWN_HOSTS_FILE" \
    -o StrictHostKeyChecking="$STRICT_HOST_KEY_CHECKING" \
    "${PEER_USER}@${PEER_HOSTNAME}" true 2>/dev/null || rc=$?
  if [ "$rc" -ne 255 ]; then
    reachable=1
    break
  fi
  if [ "$attempt" -lt "$PROBE_RETRIES" ]; then
    sleep "$PROBE_RETRY_DELAY"
  fi
done

fragments_dir="$(dirname "$FRAGMENT_FILE")"
mkdir -p "$fragments_dir"
tmp="$(mktemp "${FRAGMENT_FILE}.XXXXXX")"

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
  echo "nix-dynamic-builders: ${PEER_HOSTNAME} unreachable after ${PROBE_RETRIES} attempts -- dropped"
fi

mv -f "$tmp" "$FRAGMENT_FILE"

# Reassemble the single file nix-daemon reads from every peer's current
# fragment -- an empty fragment (peer unreachable) contributes nothing when
# catted, so no separate "skip empty files" filtering is needed. `find`
# (not a `fragments_dir/*` glob) so a tick where this is the only peer
# configured so far -- nothing else in the directory yet -- doesn't fail
# on an unmatched glob under `set -u`.
mkdir -p "$(dirname "$MACHINES_FILE")"
assembled="$(mktemp "${MACHINES_FILE}.XXXXXX")"
find "$fragments_dir" -mindepth 1 -maxdepth 1 -type f -exec cat {} + > "$assembled"
mv -f "$assembled" "$MACHINES_FILE"
