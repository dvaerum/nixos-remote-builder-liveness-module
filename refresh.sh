# Probe the peer's liveness and atomically rewrite this peer's own fragment
# of the dynamic nix builders file, then reassemble the full file from
# every peer's current fragment. Runs as a oneshot, triggered by this
# peer's own nix-dynamic-builders-refresh-<peer>.timer -- every tick is
# fully self-contained (no state persisted between runs): up to three
# quick SSH connect attempts decide THIS tick's answer, followed by a live
# system + supportedFeatures query over the same channel if reachable.
# Each peer only ever writes its OWN fragment file, never anyone else's -- so
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
  # 0700, not world-traversable: baseDir holds private key material only
  # now, readable by nothing but the dedicated nix-dynamic-builders user
  # (the public half is served from a separate, ephemeral location below
  # instead).
  chmod 0700 "$scratch"
  if mv -T "$scratch" "$key_dir" 2>/dev/null; then
    echo "nix-dynamic-builders: generated a new SSH identity at ${SSH_KEY_PATH}"
  else
    rm -rf "$scratch"
  fi
fi

# Serve the current public key from PUBLIC_KEY_PATH (under runtimeDir,
# ephemeral, non-secret) rather than directly out of baseDir -- baseDir
# stays private-key-only, readable by nothing but the dedicated
# nix-dynamic-builders user (0700), so nix-dynamic-builders-show-key
# never needs any access to it at all (see docs/decisions/0007).
# Re-derived every tick (cheap: a cat of an
# existing sibling, or one local ssh-keygen -y call) so toggling
# publicKeyWorldReadable, or a later-placed admin .pub sibling, takes
# effect on the next tick rather than only at first generation.
mkdir -p "$(dirname "$PUBLIC_KEY_PATH")"
chmod 0755 "$(dirname "$PUBLIC_KEY_PATH")"
if [ -e "${SSH_KEY_PATH}.pub" ] || [ -e "$SSH_KEY_PATH" ]; then
  pubkey_tmp="$(mktemp "${PUBLIC_KEY_PATH}.XXXXXX")"
  if [ -e "${SSH_KEY_PATH}.pub" ]; then
    cat "${SSH_KEY_PATH}.pub" > "$pubkey_tmp"
  else
    # No natural .pub sibling -- true for any admin-supplied key with
    # nothing placed next to it (a sops-nix-decrypted secret, say: sops
    # manages the private half alone, since the public half isn't a
    # secret worth deploying that way), not just a key that hasn't been
    # self-generated yet. Derive it directly -- this runs as the
    # dedicated nix-dynamic-builders user (not root), which already
    # needs real read access to SSH_KEY_PATH anyway (it's used for the
    # real ssh connection below regardless) -- for a self-generated key
    # that's automatic (this same user created it); for an admin-supplied
    # key, making it readable by this specific user is the admin's own
    # responsibility (e.g. a sops-nix secret's own `owner` setting), same
    # as protecting it at all already is.
    ssh-keygen -y -f "$SSH_KEY_PATH" > "$pubkey_tmp"
  fi
  chmod "$PUBLIC_KEY_MODE" "$pubkey_tmp"
  # Atomic rename, not a plain overwrite -- PUBLIC_KEY_PATH can be the
  # SAME shared "_default" file several peers' concurrent ticks all
  # write to (any peer inheriting the shared default key resolves to it,
  # see resolvePublicKeyPath in config.nix), the same concurrency class
  # the private key's own generation above already guards against; a
  # reader (show-key) must never see a half-written file either way.
  mv -f "$pubkey_tmp" "$PUBLIC_KEY_PATH"
fi
# else: SSH_KEY_PATH doesn't even exist yet (an admin key not yet
# provisioned, say) -- nothing to serve this tick. The probe loop below
# already handles that gracefully as "unreachable", no need to hard-fail
# here too; any previously-served key from an earlier tick is left in
# place rather than removed on a transient gap.

# Shared by both ssh calls below (liveness probe + features query) -- same
# connection policy either way, no reason to duplicate the flag list.
# SSH_CONFIG_FILE (not /dev/null) so a peer's extraSshConfig (a jump host,
# say) applies here too, not just to nix-daemon's own real dispatch -- see
# docs/decisions/0010. -i is kept alongside its matching IdentityFile line
# in that same file as a belt-and-suspenders default for the DIRECT
# connection; it's the file's own Host block, not this flag, that a
# ProxyJump's re-invoked sub-ssh process actually sees.
ssh_opts=(
  -F "$SSH_CONFIG_FILE"
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
  # actually executes, the real nix-daemon --stdio is, and IT exits non-zero
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

# Live system + supportedFeatures, fetched over the same restricted channel
# (the dispatcher on the peer answers this one sentinel command distinctly
# from the real nix-daemon --stdio, see dispatch.sh) -- only worth asking
# once we already know the peer's reachable this tick. supportedFeatures
# falls back to its static config value if the query comes back empty
# (safe either way: under- or over-advertising a feature just changes
# which builds nix-daemon considers this peer for). system has no such
# fallback -- see docs/decisions/0006 for why guessing an architecture is
# categorically riskier than guessing a feature list, so a peer this
# can't be determined for is treated the same as unreachable below. Two
# lines, system then supportedFeatures (see dispatch.sh) -- not two SSH
# round trips, one connection answering with both.
live_system=""
live_supported_features="$PEER_SUPPORTED_FEATURES"
if [ "$reachable" = "1" ]; then
  # shellcheck disable=SC2029 # intentional: resolve locally to the fixed
  # sentinel before it's sent, which dispatch.sh then matches against the
  # SEPARATE, remote-side $SSH_ORIGINAL_COMMAND -- not the thing this
  # check warns about (a variable meant to expand on the remote shell).
  raw="$(ssh "${ssh_opts[@]}" "${PEER_USER}@${PEER_HOSTNAME}" "$FEATURE_QUERY_COMMAND" 2>/dev/null || true)"
  live_system="$(printf '%s\n' "$raw" | sed -n '1p')"
  live_features_line="$(printf '%s\n' "$raw" | sed -n '2p')"
  if [ -n "$live_features_line" ]; then
    # nix config show prints a space-separated list; the machines-file
    # format wants comma-separated.
    live_supported_features="$(printf '%s' "$live_features_line" | tr ' ' ',')"
  fi
fi

fragments_dir="$(dirname "$FRAGMENT_FILE")"
mkdir -p "$fragments_dir"
tmp="$(mktemp "${FRAGMENT_FILE}.XXXXXX")"

if [ "$reachable" = "1" ] && [ -n "$live_system" ]; then
  # storeUri system sshKey maxJobs speedFactor supportedFeatures mandatoryFeatures publicHostKey
  # Host key field is "-": we rely on the pinned known_hosts file above
  # (TOFU via accept-new) rather than pre-pinning a key -- see
  # docs/decisions/0002-tofu-host-key-checking.md.
  printf 'ssh-ng://%s@%s %s %s %s %s %s %s -\n' \
    "$PEER_USER" "$PEER_HOSTNAME" "$live_system" "$SSH_KEY_PATH" \
    "$PEER_MAX_JOBS" "$PEER_SPEED_FACTOR" "$live_supported_features" "$PEER_MANDATORY_FEATURES" \
    > "$tmp"
  echo "nix-dynamic-builders: ${PEER_HOSTNAME} reachable -- added as a builder"
elif [ "$reachable" = "1" ]; then
  : > "$tmp"
  echo "nix-dynamic-builders: ${PEER_HOSTNAME} reachable but couldn't determine its system -- dropped"
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
