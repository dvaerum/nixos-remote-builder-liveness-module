## _module\.args

Additional arguments passed to each module in addition to ones
like ` lib `, ` config `,
and ` pkgs `, ` modulesPath `\.

This option is also available to all submodules\. Submodules do not
inherit args from their parent module, nor do they provide args to
their parent module or sibling submodules\. The sole exception to
this is the argument ` name ` which is provided by
parent modules to a submodule and contains the attribute name
the submodule is bound to, or a unique generated name if it is
not bound to an attribute\.

Some arguments are already passed by default, of which the
following *cannot* be changed with this option:

 - ` lib `: The nixpkgs library\.

 - ` config `: The results of all options after merging the values from all modules together\.

 - ` options `: The options declared in all modules\.

 - ` specialArgs `: The ` specialArgs ` argument passed to ` evalModules `\.

 - All attributes of ` specialArgs `
   
   Whereas option values can generally depend on other option values
   thanks to laziness, this does not apply to ` imports `, which
   must be computed statically before anything else\.
   
   For this reason, callers of the module system can provide ` specialArgs `
   which are available during import resolution\.
   
   For NixOS, ` specialArgs ` includes
   ` modulesPath `, which allows you to import
   extra modules from the nixpkgs package tree without having to
   somehow make the module aware of the location of the
   ` nixpkgs ` or NixOS directories\.
   
   ```
   { modulesPath, ... }: {
     imports = [
       (modulesPath + "/profiles/minimal.nix")
     ];
   }
   ```

For NixOS, the default value for this option includes at least this argument:

 - ` pkgs `: The nixpkgs package set according to
   the ` nixpkgs.pkgs ` option\.



*Type:*
lazy attribute set of raw value



*Default:*

```nix
{ }
```

*Declared by:*
 - [\<nixpkgs/lib/modules\.nix>](https://github.com/NixOS/nixpkgs/blob//lib/modules.nix)



## services\.nixDynamicBuilderUser\.enable



Whether to enable the nix-remote-builder account peers SSH into to dispatch builds here\.
Independent of services\.nixDynamicBuilders\.enable – a host can accept
builds from peers without ever dispatching to any peer of its own, or
vice versa
\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/userOptions\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/userOptions.nix)



## services\.nixDynamicBuilderUser\.niceLevel



` nice ` priority for ` nix-store --serve ` – a scheduling courtesy, not a security control\.



*Type:*
signed integer



*Default:*

```nix
19
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/userOptions\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/userOptions.nix)



## services\.nixDynamicBuilderUser\.peers



Peers authorized to connect to THIS host and dispatch builds here,
keyed by an arbitrary name of your choosing\. Convention is to use the
same name this same peer has under ` services.nixDynamicBuilders.peers `
on the other host, but nothing enforces that link – the two option
trees are independent, which is the whole point: a peer relationship
can be one-directional (one side dispatches, the other only
accepts), and a receive-only host only ever appears under this
option, never under ` services.nixDynamicBuilders.peers `\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/userOptions\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/userOptions.nix)



## services\.nixDynamicBuilderUser\.peers\.\<name>\.niceLevel



Per-peer override of the global ` niceLevel `\.



*Type:*
signed integer



*Default:*

```nix
config.services.nixDynamicBuilderUser.niceLevel
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/userOptions\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/userOptions.nix)



## services\.nixDynamicBuilderUser\.peers\.\<name>\.publicKey



The peer’s public key (ed25519, authorized_keys line format –
just the key material, no command= prefix), authorized to
connect to THIS host as the nix-remote-builder user and dispatch
builds here\. Deliberately NOT shipped with this module: it’s
fleet-specific identity, not mechanism – generate your own
keypair and set this from your own host configuration\. See
README\.md’s Setup section\.



*Type:*
string

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/userOptions\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/userOptions.nix)



## services\.nixDynamicBuilders\.enable



Whether to enable dynamic nix remote-builder liveness tracking\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.baseDir



Persistent state directory (survives reboot): SSH keys
(` ssh-keys/<peer-name>/ `, ` ssh-keys/_default/ `) and ` known_hosts `\.



*Type:*
absolute path



*Default:*

```nix
"/var/lib/nix-dynamic-builders"
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.connectTimeout



Seconds ` ssh -o ConnectTimeout ` waits per probe attempt\.



*Type:*
signed integer



*Default:*

```nix
2
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.knownHostsFile



TOFU known_hosts file scoped to this mechanism alone – see docs/decisions/0002\.



*Type:*
absolute path



*Default:*

```nix
"${config.services.nixDynamicBuilders.baseDir}/known_hosts"
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers



The set of peer machines this host probes and may dispatch builds
to, keyed by an arbitrary name of your choosing (used in unit
names, the show-key command, and the on-disk key/fragment layout)\.



*Type:*
attribute set of (submodule)



*Default:*

```nix
{ }
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.connectTimeout



Per-peer override of the global ` connectTimeout `\.



*Type:*
signed integer



*Default:*

```nix
config.services.nixDynamicBuilders.connectTimeout
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.hostname



The OTHER host’s hostname – the machine this host probes
and, if reachable, dispatches builds to\. Defaults to the
attribute name (e\.g\. ` peers.bob ` probes “bob”); only set
this when the peer’s reachable name differs from whatever
you choose to call it here\.



*Type:*
string



*Default:*

```nix
"‹name›"
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.mandatoryFeatures



Features a build must explicitly request before this peer
is even considered for it – this host’s own dispatching
policy toward the peer, not a fact about the peer, so
unlike ` supportedFeatures ` it’s never fetched live\. See
` docs/decisions/0003 `\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.maxJobs



The peer’s own maxJobs\. For a dual-use machine (a workstation
someone also works on interactively, not a dedicated build box),
size this below its real thread count to leave headroom\.



*Type:*
signed integer

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.probeRetries



Per-peer override of the global ` probeRetries `\.



*Type:*
signed integer



*Default:*

```nix
config.services.nixDynamicBuilders.probeRetries
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.probeRetryDelay



Per-peer override of the global ` probeRetryDelay `\.



*Type:*
string



*Default:*

```nix
config.services.nixDynamicBuilders.probeRetryDelay
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.publicKeyWorldReadable



Per-peer override of the global ` publicKeyWorldReadable `\. Only meaningful when this peer has its own distinct key (` sshKey ` isn’t ` false `) – a peer reusing the shared default key can’t have its own say over that one shared file’s permissions\.



*Type:*
boolean



*Default:*

```nix
config.services.nixDynamicBuilders.publicKeyWorldReadable
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.speedFactor



The peer’s relative speed factor, as it appears in the machines-file line – see ` nix.buildMachines `’s ` speedFactor `\.



*Type:*
signed integer



*Default:*

```nix
1
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.sshKey



This peer’s own identity key, overriding the shared
default (` services.nixDynamicBuilders.sshKey `):

 - ` false ` (default): no override – use the shared
   default, or fail evaluation if the shared default is
   itself disabled (` false `)\.
 - ` true `: generate a key distinct to THIS peer at
   ` baseDir/ssh-keys/<name>/ssh_key `, ignoring the shared
   default entirely\.
 - a path or string: use this exact pre-existing key for
   this peer only\.



*Type:*
boolean or absolute path or string



*Default:*

```nix
false
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.strictHostKeyChecking



Per-peer override of the global ` strictHostKeyChecking `\.



*Type:*
one of “yes”, “accept-new”, “no”



*Default:*

```nix
config.services.nixDynamicBuilders.strictHostKeyChecking
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.supportedFeatures



Fallback only – each tick replaces this with the peer’s
real, live ` nix config show system-features `, queried over
the same restricted SSH channel (see
` docs/decisions/0003 `); this value is only used if that
live query fails\.



*Type:*
list of string



*Default:*

```nix
[
  "kvm"
  "big-parallel"
]
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.peers\.\<name>\.system



The peer’s Nix ` system ` string, as it appears in the machines-file line\.



*Type:*
string



*Default:*

```nix
"x86_64-linux"
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.probeIntervalSec



How often each peer is re-probed after the first tick (systemd time span)\. Global only – see docs/decisions/0003\.



*Type:*
string



*Default:*

```nix
"60s"
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.probeOnBootSec



How soon after boot the first probe tick fires (systemd time span)\.
Global only – see docs/decisions/0003 for why this isn’t per-peer\.



*Type:*
string



*Default:*

```nix
"30s"
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.probeRetries



SSH connect attempts per tick before declaring a peer unreachable\.



*Type:*
signed integer



*Default:*

```nix
3
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.probeRetryDelay



Seconds to sleep between failed attempts (passed straight to ` sleep `, fractional values are fine)\.



*Type:*
string



*Default:*

```nix
"1.5"
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.publicKeyWorldReadable



Whether this host’s own generated/configured public keys are
readable by any local user (so ` nix-dynamic-builders-show-key ` just
works) or root-only (so the command needs sudo)\. Public keys aren’t
secret, so ` true ` is the default; ` peers.<name>.publicKeyWorldReadable `
inherits this unless a peer overrides it\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.runtimeDir



Ephemeral runtime directory (tmpfs, recreated fresh every boot):
the assembled ` machines ` file nix-daemon reads and each peer’s own
fragment\. Liveness has no meaning across a reboot, so this lives
outside ` baseDir ` on purpose\.



*Type:*
absolute path



*Default:*

```nix
"/run/nix-dynamic-builders"
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.sshKey



The shared default identity key used by any peer that doesn’t set
its own ` peers.<name>.sshKey `:

 - ` true `: generate one at ` baseDir/ssh-keys/_default/ssh_key ` the
   first time it’s needed, if it doesn’t already exist\.
 - ` false `: no shared default – every peer must set its own key, or
   evaluation fails naming the peer that didn’t\.
 - a path or string: use this exact pre-existing key as the shared
   default\.



*Type:*
boolean or absolute path or string

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)



## services\.nixDynamicBuilders\.strictHostKeyChecking



` ssh -o StrictHostKeyChecking ` for the probe\. “accept-new” is
TOFU – see docs/decisions/0002\. ` "ask" ` is deliberately not an
option here (excluded by explicit choice, not a technical
requirement – ` BatchMode=yes `, which is always on, would make it
fail rather than hang either way)\.



*Type:*
one of “yes”, “accept-new”, “no”



*Default:*

```nix
"accept-new"
```

*Declared by:*
 - [/home/dennis/nixos-remote-builder-liveness-module/nixosModule/options\.nix](file:///home/dennis/nixos-remote-builder-liveness-module/nixosModule/options.nix)


