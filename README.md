# nixos-remote-builder-liveness-module

A NixOS module that gives `nix.settings.builders` a live, self-updating
peer instead of a static one. A systemd timer probes a peer machine's
SSH reachability every 60 seconds and atomically rewrites a plain
runtime file that `nix-daemon` re-reads fresh on every single build
dispatch. The peer being up or down takes effect on the very next
build -- no `nixos-rebuild switch`, no daemon restart, on either side.

Built for a small personal fleet of two (or more) machines where the
"remote builder" isn't a dedicated, always-on build box but something
like a second laptop that's only sometimes switched on. A build
dispatched to a sleeping peer under a static `nix.buildMachines`
config just hangs or fails; this module falls back to building locally
instead, silently and automatically.

## How it works

```
                    nix-dynamic-builders-refresh.timer
                    (OnBootSec=30s, OnUnitActiveSec=60s)
                                  |
                                  v
                    nix-dynamic-builders-refresh.service
                       (oneshot -- stateless each tick)
                                  |
                                  v
            +---------------------------------------------+
            |  ssh -i ssh-key -o ConnectTimeout=2 ...       |
            |  nix-remote-builder@<peer> true                |
            |  (up to 3 attempts, 1.5s apart)                |
            +---------------------------------------------+
                      |                          |
              reachable                   unreachable (3/3 failed)
                      |                          |
                      v                          v
      write tmp file with ONE line:      write EMPTY tmp file
      "ssh-ng://user@host system          (no builders listed)
       sshKey maxJobs speedFactor
       features ... -"
                      |                          |
                      +------------+-------------+
                                   |
                                   v
                    mv -f tmp  ->  /var/lib/nix-dynamic-builders/machines
                    (atomic rename -- nix-daemon NEVER sees a half-written file)
                                   |
                                   v
   +-------------------------------------------------------------------+
   |                      nix-daemon, on EVERY build                   |
   |                                                                   |
   |   readFile("@/var/lib/nix-dynamic-builders/machines")             |
   |   -- fresh read, ZERO caching (confirmed: src/libstore/machines.cc)|
   |                                                                   |
   |        peer line present  --------->  dispatch build over SSH     |
   |                                       to peer's "nix-store --serve"|
   |                                                                   |
   |        file empty         --------->  build locally               |
   +-------------------------------------------------------------------+

   -------------------------- receiving side (on the PEER) --------------------------

   services.nixDynamicBuilders.peer.publicKey
   installed in nix-remote-builder's authorized_keys with a forced prefix:

       command="nice -19 nix-store --serve --write",restrict  <pubkey>

   -> this key can NEVER open a shell or run anything else,
      even if the private half leaks -- only nix-store --serve.

   nix.settings.trusted-users = [ "nix-remote-builder" ]
   -> lets --serve import build inputs without a per-path signature check
```

See [`docs/decisions/0001`](docs/decisions/0001-live-file-over-static-buildmachines.md)
for why a live `@file` was chosen over the built-in static
`nix.buildMachines`, and
[`docs/decisions/0002`](docs/decisions/0002-tofu-host-key-checking.md)
for the host-key-checking and trust-model rationale.

## Setup

Each host gets its own identity key -- never the same private key copied
onto two hosts. By default (`sshKey = true`) a key is generated for you
on the first probe tick, no `ssh-keygen` or secrets manager required; set
it to a path/string instead if you'd rather manage the key yourself, or
to `false` to require every peer to set its own key explicitly.

Since the key is generated at runtime, its public half isn't known at
eval time -- wiring up a peer relationship is a two-step bootstrap:

1. On **each** host, import this module and enable it with the peer's
   `publicKey` left as a placeholder for now (any string; it'll be
   replaced in step 3):

   ```nix
   {
     inputs.nix-dynamic-builders.url = "github:dvaerum/nixos-remote-builder-liveness-module";
     # ...
   }
   ```

   ```nix
   # host A's configuration
   services.nixDynamicBuilders = {
     enable = true;
     peers.host-b = {
       maxJobs = 8; # size below host B's real thread count if it's a
                    # dual-use machine someone also works on directly
       publicKey = "placeholder -- replaced in step 3";
     };
   };
   ```

2. Deploy both hosts. Each starts generating its own key and probing the
   other (which will fail until step 3 -- that's expected).

3. On each host, run `nix-dynamic-builders-show-key host-b` (substituting
   whichever peer name you used) to print that key's public half, and
   paste it into the *other* host's `publicKey` -- i.e. host A's real
   key goes into host B's config, and vice versa. Redeploy both.

Once that's done, both hosts quietly probe each other every 60s and the
chicken-and-egg bootstrap step is never needed again, even if a key is
later regenerated -- just repeat step 3 for whichever side changed.

If you'd rather skip the bootstrap step, generate a keypair yourself
(`ssh-keygen -t ed25519 -N "" -f nix-dynamic-builders_ed25519`) and point
`sshKey` at the private half -- then both sides' `publicKey` are known
upfront and a single deploy is enough:

```nix
# host A's configuration
services.nixDynamicBuilders = {
  enable = true;
  sshKey = ./nix-dynamic-builders_ed25519;
  peers.host-b = {
    maxJobs = 8;
    publicKey = builtins.readFile ./nix-dynamic-builders_ed25519.pub;
  };
};
```

A host can list more than one peer under `peers`, each keyed by its own
name (which also becomes its hostname by default -- set `hostname`
explicitly only if the peer's reachable name differs from the name you
give it here).

## Options reference

| Option | Type | Default | Description |
|---|---|---|---|
| `services.nixDynamicBuilders.enable` | bool | `false` | Enable this host's probing timers + receiving-side user |
| `services.nixDynamicBuilders.baseDir` | path | `/var/lib/nix-dynamic-builders` | Persistent state: SSH keys, `known_hosts` |
| `services.nixDynamicBuilders.knownHostsFile` | path | `"${baseDir}/known_hosts"` | TOFU known_hosts file -- see docs/decisions/0002 |
| `services.nixDynamicBuilders.runtimeDir` | path | `/run/nix-dynamic-builders` | Ephemeral (tmpfs) runtime state: the machines file and per-peer fragments |
| `services.nixDynamicBuilders.sshKey` | `true`\|`false`\|path\|str | *(required)* | Shared default identity key: generate (`true`), disable (`false`), or use this exact pre-existing key |
| `services.nixDynamicBuilders.publicKeyWorldReadable` | bool | `true` | Whether generated/configured public keys are readable by any local user (so `show-key` just works) or root-only |
| `services.nixDynamicBuilders.connectTimeout` | int | `2` | Seconds `ssh -o ConnectTimeout` waits per probe attempt |
| `services.nixDynamicBuilders.strictHostKeyChecking` | `"yes"`\|`"accept-new"`\|`"no"` | `"accept-new"` | TOFU by default -- see docs/decisions/0002 |
| `services.nixDynamicBuilders.probeRetries` | int | `3` | SSH connect attempts per tick before declaring a peer unreachable |
| `services.nixDynamicBuilders.probeRetryDelay` | str | `"1.5"` | Seconds between failed attempts (passed straight to `sleep`) |
| `services.nixDynamicBuilders.niceLevel` | int | `19` | `nice` priority for the receiving side's `nix-store --serve` |
| `services.nixDynamicBuilders.probeOnBootSec` | str | `"30s"` | Delay before the first probe tick after boot. Global only |
| `services.nixDynamicBuilders.probeIntervalSec` | str | `"60s"` | How often each peer is re-probed thereafter. Global only |
| `services.nixDynamicBuilders.peers.<name>.hostname` | str | *(attribute name)* | The peer's hostname, probed and dispatched to |
| `services.nixDynamicBuilders.peers.<name>.system` | str | `"x86_64-linux"` | The peer's Nix `system` string |
| `services.nixDynamicBuilders.peers.<name>.maxJobs` | int | *(required)* | The peer's own `maxJobs` for this builder entry |
| `services.nixDynamicBuilders.peers.<name>.speedFactor` | int | `1` | |
| `services.nixDynamicBuilders.peers.<name>.supportedFeatures` | list of str | `["kvm" "big-parallel"]` | Fallback only -- each tick replaces this with the peer's real, live `nix config show system-features`, queried over the same restricted SSH channel; only used if that query fails |
| `services.nixDynamicBuilders.peers.<name>.mandatoryFeatures` | list of str | `[ ]` | |
| `services.nixDynamicBuilders.peers.<name>.publicKey` | str | *(required)* | The peer's public key, authorized to connect here as `nix-remote-builder` |
| `services.nixDynamicBuilders.peers.<name>.sshKey` | `false`\|`true`\|path\|str | `false` | Override the shared default: `false` inherits it (erroring if it's disabled), `true` generates a key distinct to this peer, a path/string uses that exact key |
| `services.nixDynamicBuilders.peers.<name>.publicKeyWorldReadable` | bool | *(inherits `publicKeyWorldReadable`)* | Only meaningful when this peer has its own distinct key (`sshKey` isn't `false`) |
| `services.nixDynamicBuilders.peers.<name>.{connectTimeout,strictHostKeyChecking,probeRetries,probeRetryDelay,niceLevel}` | *(same as above)* | *(inherits the global value)* | Per-peer override of the matching global option |

`nix-dynamic-builders-show-key <peer-name>|--default|--fzf` prints a
public key (not secret) for pasting into the other host's `publicKey` --
see Setup above. Run with no arguments for a list of known names.

## Trust model

Read [`docs/decisions/0002`](docs/decisions/0002-tofu-host-key-checking.md)'s
"Trust model, stated plainly" section before pointing this at anything
you wouldn't otherwise trust with `sudo`-equivalent access. This is
built for a small fleet under one administration, not for untrusted or
third-party peers.

## Testing

```bash
nix flake check
```

Runs a real two-VM test (`tests/nixos/liveness.nix`): both peers come
up, SSH to each other, the machines file picks up the live peer, and
-- the fallback path this module exists for -- going back to empty the
moment the peer drops.
