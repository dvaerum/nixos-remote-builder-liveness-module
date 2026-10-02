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

This module is symmetric and mutual by design: the same keypair
authorizes builds in *both* directions between two machines. Generate
one keypair, use its public half on both hosts.

1. Generate a dedicated keypair (not an admin/login key):

   ```bash
   ssh-keygen -t ed25519 -N "" -f nix-dynamic-builders_ed25519 \
     -C "nix-dynamic-builders (mutual, <host-a> <-> <host-b>)"
   ```

2. Put the **private** key where your secrets manager can hand NixOS a
   decrypted path. This module expects
   `config.sops.secrets."nix-dynamic-builders/ssh-key".path` to exist
   -- i.e. you're expected to be using
   [sops-nix](https://github.com/Mic92/sops-nix) and to add an entry
   named exactly `nix-dynamic-builders/ssh-key` to each host's secrets
   file, owned by root, containing the private key content.

3. On **each** host, import this module and configure the other host
   as the peer, with the **public** key content:

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
       publicKey = builtins.readFile ./nix-dynamic-builders_ed25519.pub;
     };
   };
   ```

   ```nix
   # host B's configuration (mirror)
   services.nixDynamicBuilders = {
     enable = true;
     peers.host-a = {
       maxJobs = 8;
       publicKey = builtins.readFile ./nix-dynamic-builders_ed25519.pub;
     };
   };
   ```

   A host can list more than one peer under `peers`, each keyed by its own
   name (which also becomes its hostname by default -- set `hostname`
   explicitly only if the peer's reachable name differs from the name you
   give it here).

4. Deploy both. Each host starts probing the other every 60s; while
   either peer is offline, that direction just quietly builds locally.

## Options reference

| Option | Type | Default | Description |
|---|---|---|---|
| `services.nixDynamicBuilders.enable` | bool | `false` | Enable this host's probing timers + receiving-side user |
| `services.nixDynamicBuilders.peers.<name>.hostname` | str | *(attribute name)* | The peer's hostname, probed and dispatched to |
| `services.nixDynamicBuilders.peers.<name>.system` | str | `"x86_64-linux"` | The peer's Nix `system` string |
| `services.nixDynamicBuilders.peers.<name>.maxJobs` | int | *(required)* | The peer's own `maxJobs` for this builder entry |
| `services.nixDynamicBuilders.peers.<name>.speedFactor` | int | `1` | |
| `services.nixDynamicBuilders.peers.<name>.supportedFeatures` | list of str | `["kvm" "big-parallel"]` | |
| `services.nixDynamicBuilders.peers.<name>.mandatoryFeatures` | list of str | `[ ]` | |
| `services.nixDynamicBuilders.peers.<name>.publicKey` | str | *(required)* | The peer's public key, authorized to connect here as `nix-remote-builder` |

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
