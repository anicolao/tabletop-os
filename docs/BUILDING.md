# Building

Everything here is `aarch64-linux`. macOS cannot build it natively, so a Linux
builder is mandatory.

```sh
nix build .#image      # SD card image for the Orange Pi 5 Plus
nix build .#toplevel   # just the system closure, no image wrapper
nix run   .#vm         # emulator, see EMULATION.md
```

The image lands at `result/sd-image/*.img` — uncompressed, because macOS
flashing tools handle a raw `.img` more predictably than `.img.zst` and the size
difference does not matter over USB.

## Builder on macOS

nix-darwin's `linux-builder` runs a NixOS VM under HVF. Both host and guest are
aarch64, so guest code runs natively — properly configured this is a fast
builder, not a fallback.

Its stock defaults are **1 vCPU, 3 GiB RAM, `maxJobs = 1`**, which makes every
Linux build effectively single-threaded. Check what you actually have:

```sh
ps aux | grep '[q]emu-system-aarch64' | grep -oE '\-m [0-9]+|\-smp [0-9]+'
cat /etc/nix/machines
```

A functional smoke test, which is worth more than reading the config:

```sh
nix build --impure --no-link --print-out-paths --expr \
  'with import <nixpkgs> { system = "aarch64-linux"; };
   runCommand "t" {} "{ nproc; uname -m; grep MemTotal /proc/meminfo; } > $out"'
```

### The 8 vCPU ceiling

`nixos/lib/qemu-common.nix` pins `-machine virt,gic-version=2` for
`aarch64-darwin` hosts, and **GICv2 supports at most 8 vCPUs**. QEMU refuses to
start above that:

```
qemu-system-aarch64: Number of SMP CPUs requested (12) exceeds max CPUs
supported by machine 'mach-virt' (8)
```

GICv3 would allow more, but HVF cannot virtualise one, so QEMU would silently
fall back to TCG emulation — far slower than 8 native cores. 8 is the real
ceiling; do not try to raise it.

Two smaller builders instead of one larger one is also the wrong trade here:
the expensive derivations (kernel, initrd, image assembly) are *single*
derivations that cannot span builders, so splitting makes exactly the slow steps
slower while adding parallelism where it is not needed.

### Do not use `boot.kernelPatches`

It discards the binary cache and forces a from-source aarch64 kernel build. This
is what made the predecessor repository's final branch unfinishable. If a kernel
module seems to be missing, check `boot.kernelModules` and the device tree first
— on mainline RK3588 the module almost certainly exists already.

## A second, genuinely additive builder

The Orange Pi 5 Plus is 8 native cores with a real store and no virtualisation
overhead. Once a board is running, it is a better second builder than anything
else available, because it is *additional* hardware rather than a subdivision of
the laptop.

Check the RAM before leaning on it: the board here reports **8 GB**, not the
16 GB variant, which makes `max-jobs = 8` roughly one job per gigabyte. That is
fine for ordinary derivations and tight for large link steps, and there is no
swap beyond zram.

`nix-darwin-config/flake.nix` already reads an optional `build-machines.nix`:

```nix
[
  {
    hostName = "tabletop";
    sshUser = "admin";
    sshKey = "/Users/anicolao/.ssh/nix-remote-builder";
    system = "aarch64-linux";
    maxJobs = 8;
    supportedFeatures = [ "benchmark" "big-parallel" ];
  }
]
```

The matching public key is already in `admin-keys.nix`, so this works without
reflashing.

## Deploying to a running board without reflashing

Once a board is up, config changes do not need a new card:

```sh
nix run nixpkgs#nixos-rebuild -- switch --flake .#opi5plus \
  --target-host admin@tabletop-opi5plus --sudo
```

This builds on the linux-builder, copies the closure over SSH and activates.
NixOS keeps the previous generation, so `nixos-rebuild --rollback` (or picking
the old entry at boot) undoes it. Activation does not restart the kiosk unless
something it depends on changed — verified: `cage-tty1` stayed up with its
renderers intact across a switch.

### Bootstrapping trust on a freshly flashed card

The first deploy to a new card fails partway:

```
error: cannot add path '/nix/store/...-system-path' because it lacks a
signature by a trusted key
```

Packages fetched from cache.nixos.org carry signatures and copy fine; anything
built locally does not, and the board's daemon rejects unsigned paths from a
user that is not in `trusted-users`. `modules/base.nix` now sets
`trusted-users = [ "root" "@wheel" ]`, but a card flashed before that change
cannot receive the very config that fixes it.

`--no-check-sigs` does **not** help — it is a client-side flag, and the
enforcement happens in the daemon on the board.

Break the loop by importing as root, which is always trusted:

```sh
T=$(nix build --no-link --print-out-paths .#toplevel)

# only the paths the board is missing — typically a handful of megabytes
nix-store -qR "$T" > closure.txt
ssh admin@tabletop-opi5plus 'while read -r p; do [ -e "$p" ] || echo "$p"; done' \
  < closure.txt > missing.txt

nix-store --export $(cat missing.txt) \
  | ssh admin@tabletop-opi5plus 'sudo nix-store --import'

ssh admin@tabletop-opi5plus \
  "sudo nix-env -p /nix/var/nix/profiles/system --set $T && \
   sudo $T/bin/switch-to-configuration switch"
```

After that one activation, `nixos-rebuild --target-host` works normally.

Granting `@wheel` trust is not an escalation here: those accounts already have
passwordless sudo, so inserting store paths grants nothing they could not
already do.

## Caches

Only `cache.nixos.org` is configured. Mainline kernels and U-Boot for this board
are all cached upstream, so a first build is mostly downloads.

If a build starts compiling a kernel from source, something has diverged from
nixpkgs — check whether `linuxPackages_latest` moved, rather than waiting it out.

## Troubleshooting

**`getting attributes of path '/nix/store/...': No such file or directory`
during "setting up the build environment"** — the host failed to copy an input
to the builder. If you have recently *replaced* the builder VM (for example by
toggling `ephemeral`), the long-running `nix-daemon` can hold cached path-info
from the previous VM's store and skip copies it believes are unnecessary.
Restart it:

```sh
sudo launchctl kickstart -k system/org.nixos.nix-daemon
```

**`error: a 'aarch64-linux' with features {} is required to build ...`** — no
builder is registered or it is not running. Check `/etc/nix/machines` and that
qemu is alive.

**GC aborts with `chmod ... Operation not permitted` on a `.app` bundle** — a
macOS App Management (TCC) restriction, not a Nix problem, and it blocks the
*entire* GC rather than just that path. Grant Full Disk Access to nix, run
`nix-collect-garbage -d`, then revoke it again.
