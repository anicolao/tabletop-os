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

## Display resolution

virtio-gpu's own default is **1280x800**, too cramped to judge a tabletop
layout. The default here is 1920x1080, and it is a runtime flag — no rebuild:

```sh
nix run .#vm -- --resolution 3840x2160
nix run .#vm -- -r 1280x800
```

Change the default in `hosts/vm.nix` via `tabletop.vm.width` / `.height`.

The launcher is laid out radially for players on all four sides, so it is
sensitive to aspect ratio. Set this to match the real panel before drawing any
conclusion about spacing.

Verify the guest actually took the mode — the QEMU argument being accepted is
not the same as the mode being used:

```sh
ssh -p 2222 admin@localhost 'head -3 /sys/class/drm/card0-Virtual-1/modes'
```

The first line is the mode in use.

### How the override works

`hosts/vm.nix` bakes `-device virtio-gpu-pci,id=gpu0,xres=…,yres=…`, and
`scripts/run-vm.sh` appends `-set device.gpu0.xres=…`. Passing a second
`-device` would add a second GPU rather than reconfigure the first, which is why
it is done this way.

**`id=gpu0` is load-bearing.** Without it, `-set` fails with `there is no device
"gpu0" defined` and the VM refuses to start.

## Inspecting a running VM

Port 2222 on the host forwards to the guest's SSH. This is far easier than
fighting the graphical console:

```sh
ssh -p 2222 admin@localhost

systemctl status cage-tty1        # is the compositor up?
pgrep -af "type=renderer"         # one per loaded page — zero means no page
sudo journalctl -u cage-tty1 -b
curl -sS -o /dev/null -w '%{http_code}\n' https://anicolao.github.io/ttlauncher/
```

Your key from `admin-keys.nix` works; the VM also accepts the password
`tabletop`.

## Screenshots

The runner takes QEMU arguments after `--`, so a monitor socket gets you a
framebuffer capture without a display:

```sh
nix run .#vm -- -display none -monitor unix:mon.sock,server,nowait
```

The runner `cd`s into a fresh `nix-vm.XXXX` temp directory, so `mon.sock` lands
*there*, not where you launched from — find it with
`lsof -a -p $(pgrep -f qemu-system-aarch64) -d cwd`. Then `screendump
/path/to/shot.ppm` on the monitor socket.

## Disk state

The VM writes `tabletop-vm.qcow2` into the directory you launch from — that path
is resolved before the runner changes directory, so it is the launch cwd and not
the temp directory. It is reused across runs, so browser profile state survives
and a second boot is noticeably faster.

```sh
rm -f tabletop-vm.qcow2 && nix run .#vm     # clean boot
NIX_DISK_IMAGE=/tmp/scratch.qcow2 nix run .#vm   # or put it elsewhere
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
