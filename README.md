# tabletop-os

A NixOS-based browser kiosk for a large touchscreen tabletop gaming computer.

The machine boots straight into a fullscreen browser showing
[ttlauncher](https://anicolao.github.io/ttlauncher/). There is no desktop, no
window manager chrome, no login screen — a person walks up to the table and
touches a game.

## Targets

| Board | SoC | GPU | Status |
| --- | --- | --- | --- |
| **Orange Pi 5 Plus** | Rockchip RK3588 | Mali-G610 MP4 | primary |
| Raspberry Pi 5 | BCM2712 | VideoCore VII | planned |
| Raspberry Pi 4 | BCM2711 | VideoCore VI | planned |

The Orange Pi is substantially the fastest of the three and is where the
optimisation effort goes. The Pis are supported because they exist and are
already deployed, not because they are good at this.

The design goal is **WebGL, Canvas2D and CSS animation throughput**. Not boot
time, not image size. Where those trade against each other, frames win.

## Quick start

```sh
# Boot the kiosk in an emulator, no hardware needed
nix run .#vm
nix run .#vm -- --resolution 3840x2160     # match your real panel

# Write the image to an SD card, with safety checks and a confirmation prompt
nix run .#burn -- --list                   # find the card
nix run .#burn -- --sd /dev/rdisk4

# Build the image and print where it is
nix run .#image
nix build .#image                          # same, but leaves ./result

# Inspect the system closure without building a multi-gigabyte image
nix build .#toplevel
```

### Moving a board to its SSD

```sh
nix run .#provision-ssd    # partition the SSD and install onto it
nix run .#flash-spi        # write U-Boot to SPI, making the SSD bootable
```

Run in that order with the SD card inserted; U-Boot tries mmc before nvme, so
the card keeps winning until it is removed. That is what lets each step be
verified before anything depends on it, and it leaves the card as a rescue path
that works by being inserted. See [docs/SSD-BOOT.md](docs/SSD-BOOT.md).

### Seeing what the table is doing

```sh
nix run .#screenshot    # what the compositor drew, captured over SSH
nix run .#photo         # what the panel emits, via a webcam above the table
```

```sh
nix run .#cdp -- gpu      # what is hardware accelerated
nix run .#cdp -- fps      # frames actually delivered
nix run .#cdp -- profile-swipe 1200 1080 2600 1080   # profile a real interaction
```

`cdp` drives the kiosk's browser over DevTools — synthetic touch, frame rate,
and JS CPU profiles, all remotely. See
[docs/GRAPHICS-PERF.md](docs/GRAPHICS-PERF.md), which is the guide to hand
anyone optimising the launcher.

Use them together. A good screenshot with a black photo means the fault is the
cable, the monitor's input selection, or the panel — and no change in this
repository will fix it. Both black means the fault is ours. Guessing at this
from `systemctl is-active` once cost an entire evening; see
[docs/DISPLAYPORT-TEST.md](docs/DISPLAYPORT-TEST.md).

An SD image is a file rather than a program, so `nix run .#image` is wired to
an app that builds it and prints the path plus the `dd` invocation — otherwise
it would fail with a bare "No such file or directory".

Building requires an `aarch64-linux` builder. On macOS that means the
nix-darwin `linux-builder`; see [docs/BUILDING.md](docs/BUILDING.md).

## Layout

```
flake.nix              nixosConfigurations + packages
admin-keys.nix         SSH keys allowed onto a flashed board — edit this first
modules/
  base.nix             locale, networking, ssh, zram, power behaviour
  kiosk.nix            cage + Chromium. Identical on every board.
  touchscreen.nix      libinput, rotation, blanking
hosts/
  opi5plus.nix         RK3588: mainline kernel, U-Boot, panthor, SD image
  vm.nix               QEMU emulation target
docs/
  ARCHITECTURE.md      why the modules are split where they are
  BUILDING.md          builders, cross-compilation, cache
  EMULATION.md         what the VM does and does not prove
  FLASHING.md          writing an image and first boot
```

The important structural idea: **the boards share everything above the DRM
device and nothing below it.** Compositor, browser, flags, launcher, users and
networking are identical everywhere and live in `modules/`. Kernel, bootloader,
device tree and Mesa driver differ completely and live in `hosts/`. If a
board-specific `if` ever appears in `modules/`, the split has been drawn in the
wrong place.

## Before you flash

`admin-keys.nix` holds the SSH public keys that can log into a running board.
`users.mutableUsers = false` and there are no passwords anywhere, so those keys
are the only way in. An empty list fails the build deliberately rather than
producing an image nobody can reach.

## Related repositories

- [ttlauncher](https://github.com/anicolao/ttlauncher) — the launcher this kiosk
  displays. Served over the network rather than embedded, so it can be updated
  by pushing to its own repository without rebuilding or reflashing anything.
- [nix-tabletop](https://github.com/anicolao/nix-tabletop) and
  [tabletop-image](https://github.com/anicolao/tabletop-image) — earlier
  RPi4-only attempts, now archived. This repository is the authoritative source
  of tabletop images. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for what
  was learned from them and why neither was revived.

## License

Copyright (C) 2026 Alex Nicolaou

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the [GNU General Public License](LICENSE) for more
details.
