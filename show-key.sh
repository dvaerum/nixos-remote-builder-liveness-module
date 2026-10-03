# Print a public key (not secret -- safe to paste into the OTHER host's
# config) so an admin can wire two peers together without ever touching
# ssh-keygen by hand. KEY_MAP_FILE (name<TAB>pub-path per line, "_default"
# plus one row per configured peer) is injected by config.nix ahead of
# this script's own body -- see showKeyScript there. The path always
# points into runtimeDir, never baseDir -- refresh.sh maintains it there
# every tick regardless of key source (self-generated or admin-supplied),
# so this script only ever reads a dedicated, non-secret location and
# never needs any access to baseDir at all (see docs/decisions/0007).
#
# Whether a given key is actually readable by a non-root caller is pure
# file permissions (see refresh.sh's PUBLIC_KEY_MODE handling), not
# anything this script decides -- it just cats the file and lets the OS
# enforce it.

set -euo pipefail

usage() {
  cat <<EOF
Usage: nix-dynamic-builders-show-key <peer-name>
       nix-dynamic-builders-show-key --default
       nix-dynamic-builders-show-key --fzf

Prints one public key. Known names:
EOF
  cut -f1 "$KEY_MAP_FILE"
}

print_pubkey() {
  name="$1"
  path="$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$KEY_MAP_FILE")"
  if [ -z "$path" ]; then
    echo "nix-dynamic-builders-show-key: no key named '$name' -- run with no arguments to list known names" >&2
    exit 1
  fi
  if [ ! -e "$path" ]; then
    echo "nix-dynamic-builders-show-key: '$name' has no key yet -- it's generated on its first probe tick, not at boot" >&2
    exit 1
  fi
  cat "$path"
}

case "${1:-}" in
  "" | -h | --help)
    usage
    ;;
  --default)
    print_pubkey "_default"
    ;;
  --fzf)
    chosen="$(cut -f1 "$KEY_MAP_FILE" | fzf --prompt="key> ")"
    print_pubkey "$chosen"
    ;;
  *)
    print_pubkey "$1"
    ;;
esac
