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

The Orange Pi 5 Plus is 8 native cores and 16 GiB with a real store and no
virtualisation overhead. Once a board is running, it is a better second builder
than anything else available, because it is *additional* hardware rather than a
subdivision of the laptop.

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
