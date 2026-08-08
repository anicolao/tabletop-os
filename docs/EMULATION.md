# Emulation

```sh
nix run .#vm
```

Boots the kiosk in QEMU and opens a window. Console login is `admin` /
`tabletop` (the VM config sets a password precisely because it never reaches
hardware — `hosts/opi5plus.nix` does not import `hosts/vm.nix`).

## What this proves, and what it does not

Be clear about this before trusting a green run.

| Layer | Emulated? | Notes |
| --- | --- | --- |
| Launcher loads and renders | **yes** | the most common thing to break |
| Chromium flags are accepted | **yes** | typos and removed flags surface here |
| cage starts and gets a DRM device | **yes** | via virtio-gpu |
| systemd ordering, network-online gating | **yes** | |
| Users, SSH config, firewall | **yes** | |
| Touch input mapping | partially | a QEMU tablet is absolute, not multi-touch |
| **GPU acceleration** | **no** | llvmpipe here, panfrost on the board |
| **Bootloader / U-Boot** | **no** | |
| **Device tree, panthor, HDMI** | **no** | |
| **SD image layout** | **no** | |

QEMU has no RK3588 machine model. The SD image built by `hosts/opi5plus.nix`
**cannot be booted here at any fidelity** — not with a different machine type,
not with a substituted device tree. The bootloader, device tree, panthor and the
whole display pipeline are exactly the parts emulation cannot reach.

What it runs is the *same software stack* — same `modules/`, same cage, same
Chromium invocation, same launcher URL — on a generic `virt` machine. Most kiosk
bugs are software bugs: a wrong flag, a service ordering mistake, a launcher that
does not load. Those reproduce here in seconds instead of a reflash-and-reboot
cycle.

**Never read a performance number out of the VM.** Rendering is llvmpipe on the
host CPU. `chrome://gpu` will correctly report software rendering, and that is
expected here and a bug on the board.

## Running it from macOS

The runner script is built for whichever machine runs QEMU, not for the guest.
`hosts/vm.nix` sets:

```nix
virtualisation.host.pkgs = hostPkgs;
```

and `flake.nix` instantiates the VM twice — once with `aarch64-darwin` host
packages, once with `aarch64-linux`. Without this, `nix run .#vm` on a Mac would
produce an `aarch64-linux` script the Mac cannot execute.

On Apple Silicon the guest runs **natively under HVF**, so it is genuinely fast —
no instruction emulation, since both host and guest are aarch64.

## Disk state

The VM writes a `tabletop-vm.qcow2` in the current directory and reuses it
across runs, so browser profile state survives. Delete it for a clean boot:

```sh
rm -f tabletop-vm.qcow2 && nix run .#vm
```

## Headless

If the graphical window is unavailable or unwanted:

```sh
nix run .#vm -- -display none -serial stdio
```

The kiosk still starts; you get the serial console. Useful for checking service
ordering and `journalctl -u cage-tty1` without a display.

## When the VM passes but the board does not

That is the expected failure mode, and it narrows the problem usefully: if the
software stack is known good in emulation, a failure on hardware is in the layer
below the seam — bootloader, device tree, kernel modules, or firmware. Work
through [ARCHITECTURE.md's verification section](ARCHITECTURE.md#verifying-acceleration--the-one-check-that-matters)
in order rather than re-reading the kiosk config.
