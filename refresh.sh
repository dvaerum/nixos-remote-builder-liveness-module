# Probe the peer's liveness and atomically rewrite this peer's own fragment
# of the dynamic nix builders file, then reassemble the full file from
# every peer's current fragment. Runs as a oneshot, triggered by this
# peer's own nix-dynamic-builders-refresh-<peer>.timer -- every tick is
# fully self-contained (no state persisted between runs): up to three
# quick SSH connect attempts decide THIS tick's answer, followed by a live
# supportedFeatures query over the same channel if reachable. Each peer
# only ever writes its OWN fragment file, never anyone else's -- so
# concurrent per-peer timers can't race each other -- and both the
# fragment write and the final reassembly go through write-temp-then-
# rename, so nix-daemon (which re-reads the assembled file fresh on every
# build dispatch, per src/libstore/machines.cc -- no caching) never
# observes a half-written file either way.
#
# Nix's `builders = @file` has no signature-verification step for build
# results (unlike a substituter path) -- the peer is trusted exactly as much
# as running sudo on it locally. See README.md's "Trust model" section.

set -euo pipefail

# Generate this peer's identity key on first use if nothing's there yet --
# shared-default keys can be raced by several peers' independent ticks, so
# the whole key_dir (never anything else) is the atomic commit unit, not
# the two files independently: committing them with two separate `mv`
# calls let one tick's private key land paired with a DIFFERENT tick's
# public key, a silently mismatched keypair that's never repaired (the
# outer guard below only checks the private key's existence). Generating
# into a scratch dir and renaming the whole dir into place is atomic --
# POSIX rename(2) onto an existing non-empty directory fails outright
# (ENOTEMPTY) rather than merging, so a losing tick gets an unambiguous
# "someone else already committed" signal instead of silently clobbering.
key_dir="$(dirname "$SSH_KEY_PATH")"
key_name="$(basename "$SSH_KEY_PATH")"
if [ ! -e "$SSH_KEY_PATH" ]; then
  keys_parent="$(dirname "$key_dir")"
  mkdir -p "$keys_parent"
  scratch="$(mktemp -d "${keys_parent}/.tmp.XXXXXX")"
  ssh-keygen -q -t ed25519 -N "" -f "$scratch/$key_name" < /dev/null
  chmod 0711 "$scratch"
  if mv -T "$scratch" "$key_dir" 2>/dev/null; then
    echo "nix-dynamic-builders: generated a new SSH identity at ${SSH_KEY_PATH}"
  else
    rm -rf "$scratch"
  fi
fi
# The private half is never touched beyond generation (root-only via
# ssh-keygen's own default; an admin-provided key is the admin's own
# responsibility to protect) -- but the public half's access policy is
# re-applied every tick, so toggling publicKeyWorldReadable later takes
# effect on the next tick rather than only at first generation.
if [ -e "${SSH_KEY_PATH}.pub" ]; then
  chmod "$PUBLIC_KEY_MODE" "${SSH_KEY_PATH}.pub"
fi

# Shared by both ssh calls below (liveness probe + features query) -- same
# connection policy either way, no reason to duplicate the flag list.
ssh_opts=(
  -F /dev/null
  -i "$SSH_KEY_PATH"
  -o ConnectTimeout="$CONNECT_TIMEOUT"
  -o BatchMode=yes
  -o UserKnownHostsFile="$KNOWN_HOSTS_FILE"
  -o StrictHostKeyChecking="$STRICT_HOST_KEY_CHECKING"
)

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
  ssh "${ssh_opts[@]}" "${PEER_USER}@${PEER_HOSTNAME}" true 2>/dev/null || rc=$?
  if [ "$rc" -ne 255 ]; then
    reachable=1
    break
  fi
  if [ "$attempt" -lt "$PROBE_RETRIES" ]; then
    sleep "$PROBE_RETRY_DELAY"
  fi
done

# Live supportedFeatures, fetched over the same restricted channel (the
# dispatcher on the peer answers this one sentinel command distinctly from
# the real nix-store --serve, see dispatch.sh) -- only worth asking once we
# already know the peer's reachable this tick, and falls back to the static
# config value if the query comes back empty for any reason (peer running
# an older/unpatched dispatcher, transient hiccup, etc.) rather than
# silently advertising zero features.
live_supported_features="$PEER_SUPPORTED_FEATURES"
if [ "$reachable" = "1" ]; then
  raw="$(ssh "${ssh_opts[@]}" "${PEER_USER}@${PEER_HOSTNAME}" nix-dynamic-builders-query-features 2>/dev/null || true)"
  if [ -n "$raw" ]; then
    # nix config show prints a space-separated list; the machines-file
    # format wants comma-separated.
    live_supported_features="$(echo "$raw" | tr ' ' ',')"
  fi
fi

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
    "$PEER_MAX_JOBS" "$PEER_SPEED_FACTOR" "$live_supported_features" "$PEER_MANDATORY_FEATURES" \
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
