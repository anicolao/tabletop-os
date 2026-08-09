# Flashing and first boot

## Before you build

Check `admin-keys.nix`. Those keys are the **only** way into a flashed board:
`users.mutableUsers = false` and no password is set anywhere. There is no
runtime way to add a key — it takes a rebuild and a reflash.

## Write the card

```sh
nix run .#burn -- --list             # find the card
nix run .#burn -- --sd /dev/rdisk4
```

This builds the image if needed, then refuses to continue unless the target is
a **removable whole disk** that is **not the disk this machine booted from** and
is **at least as large as the image**. It prints what it found and makes you
type the device path again before it writes anything. Then it unmounts, `dd`s
with sudo, syncs and ejects.

It rejects partitions (`/dev/disk4s1`), typos (`/dev/rdsik4`), internal disks,
and warns if the target is over 512 GB — far too large for an SD card and a good
sign it is an external SSD holding something you want.

Prefer `/dev/rdiskN` over `/dev/diskN`; the raw device is several times faster,
and the script uses it automatically if you pass the buffered one.

### Doing it by hand

If you would rather not trust a script with `dd`:

```sh
nix build .#image
diskutil list                       # identify the card, e.g. /dev/disk4
diskutil unmountDisk /dev/disk4
sudo dd if=result/sd-image/*.img of=/dev/rdisk4 bs=4m status=progress
sync
diskutil eject /dev/disk4
```

Read `diskutil list` carefully. Device numbers change when you plug things in,
and the number that was right yesterday is the usual way people erase the wrong
disk.

## Image layout

Rockchip's boot ROM loads from a fixed offset near the start of the card, so the
partition table has to leave room:

```
sector 64 (32 KiB) ──► u-boot-rockchip.bin      (~9.1 MiB, TPL+SPL+U-Boot)
16 MiB             ──► partition 1, FAT32       (16 MiB, unused, vestigial)
32 MiB             ──► partition 2, ext4        bootable — rootfs + /boot
```

`u-boot-rockchip.bin` is the combined blob; writing that one file at sector 64
is the canonical mainline method, replacing the older two-step
`idbloader.img` + `u-boot.itb` dance.

The default `sd-image.nix` firmware-partition offset is 8 MiB, which lands
*inside* the U-Boot blob. `hosts/opi5plus.nix` sets `firmwarePartitionOffset =
16` for exactly that reason — if you change it, keep it above ~10 MiB.

Nothing reads the FAT partition on this board: U-Boot comes from the raw offset
and the kernel from ext4 via `/boot/extlinux/extlinux.conf`. It exists only
because `sd-image.nix` always creates one.

## First boot

The rootfs expands to fill the card on first boot, so allow an extra reboot.

Sequence to expect:

1. U-Boot on serial (`ttyS2`, **1500000** baud — a Rockchip convention, not a
   typo)
2. Kernel, then a Plymouth splash
3. Network comes up; `cage-tty1` waits for `network-online.target`
4. Chromium fullscreen on the launcher

If it reaches step 3 and stops, the board has no network — the kiosk waits
deliberately rather than showing an error page nobody is present to dismiss.

## Getting in

```sh
ssh admin@tabletop          # or by IP
```

`admin` has passwordless sudo. There is no console login.

## If the screen stays dark

Work down the stack rather than re-reading the kiosk config:

```sh
# 1. Did the display controller bind?
dmesg | grep -iE 'rockchip|dw-hdmi|hdptx'
ls /sys/class/drm/

# 2. Did the GPU bind? Missing firmware shows up here.
dmesg | grep -i panthor

# 3. Is Mesa using the GPU or falling back?
eglinfo | grep -i renderer      # expect Mali-G610 / panfrost, NOT llvmpipe

# 4. Is the compositor running?
systemctl status cage-tty1
journalctl -u cage-tty1 -b
```

A dark screen with a healthy `cage-tty1` is a display-pipeline problem
(steps 1–2). A live screen with software rendering is a Mesa/firmware problem
(step 3). See
[ARCHITECTURE.md](ARCHITECTURE.md#verifying-acceleration--the-one-check-that-matters).

## Display: refresh rate is the animation ceiling

Check what the panel is actually running, not what it can display:

```sh
sudo grep -aE 'mode: "' /sys/kernel/debug/dri/*/state | grep -v '""'
```

The two numbers after the resolution are **refresh rate** and **pixel clock**:

```
mode: "3840x2160": 30 297000     ← 30 Hz at 297 MHz
```

297 MHz is the HDMI 1.4 ceiling; 4K@60 needs 594 MHz. If you see 30 Hz, read the
display's EDID before blaming the cable or the driver:

```sh
sudo cat /sys/class/drm/card*-HDMI-A-2/edid > /tmp/edid.bin
nix run nixpkgs#edid-decode -- /tmp/edid.bin | grep -iE "Maximum TMDS|HDMI Forum"
```

A `Maximum TMDS Clock` at or below 300 MHz, or the absence of an **HDMI Forum**
vendor block, means the panel itself is HDMI 1.4 and no cable will produce
4K@60. The display attached during bring-up reports exactly that — its product
name descriptor even reads `4K2KHDMI30`.

This matters more than it looks: **the panel's refresh rate caps everything**.
A GPU rendering 120 fps still presents 30. If a 4K panel is limited to 30 Hz,
forcing 1080p@60 may feel considerably better for animation:

```nix
boot.kernelParams = [ "video=HDMI-A-2:1920x1080@60" ];
```

`xrandr` will not help here, and cannot even run — this is Wayland under cage,
so there is no X server and no `DISPLAY`.

### DisplayPort over USB-C (experimental)

`hosts/opi5plus.nix` enables `dp0` on vp2, which makes a **`DP-1` connector**
appear. Confirmed on hardware: the driver binds
(`bound fde50000.dp (ops dw_dp_rockchip_component_ops)`) and the connector
exists, reading `disconnected` with nothing attached.

That proves the controller and VOP pipeline work. It does **not** prove USB-C
Alt Mode negotiation works — that additionally needs the DP endpoints wired
into `usbdp_phy0`'s port graph, which is deliberately left alone here because
this board's PHY graph differs from the mainline examples and getting it wrong
breaks USB rather than merely failing to display. If a USB-C→DP cable leaves
`DP-1` reading `disconnected`, that is the next thing to add — see
`rk3588s-indiedroid-nova.dts` for the full pattern.

Note that enabling DP renumbered the DRM cards (the display subsystem moved
from `card0` to `card1`), so prefer globs like `/sys/class/drm/card*-HDMI-A-2`
over hardcoded numbers.

## Serial: wiring the 40-pin header

Three UARTs are live on this image. Only one of them is on the 40-pin header,
and picking the wrong one wastes an evening:

```
ttyS0 = feb90000.serial = uart6   gpio1-0, gpio1-1     40-pin header  ← use this
ttyS1 = febc0000.serial = uart9   gpio2-18, gpio2-20   NOT on the header
ttyS2 = feb50000.serial = uart2   gpio0-13, gpio0-14   debug UART, console + getty
```

Confirm on any running board with
`grep uart /sys/kernel/debug/pinctrl/*/pinmux-pins`.

**Wire to `/dev/ttyS0`.** It is uart6, enabled by the device-tree overlay in
`hosts/opi5plus.nix`, with no console, no getty and nothing holding it open.

| Wire | Header pin | Signal |
| --- | --- | --- |
| Orange Pi **TX** → other device **RX** | **8** | GPIO33 / gpio1-1 |
| Orange Pi **RX** ← other device **TX** | **10** | GPIO32 / gpio1-0 |
| **GND** ↔ **GND** | **6** | (9, 14, 20, 25, 30, 34, 39 also work) |

These are the same positions the Raspberry Pi uses, which is deliberate on
Orange Pi's part — but note that is a coincidence of *this* UART. The 40-pin
header is physically Pi-compatible (a Pi ribbon fits, power and ground line up)
while the **GPIO functions generally are not** the Pi's, so do not assume any
other pin matches.

Derived by cross-referencing Orange Pi's own `wiringOP` `physToGpio_5PLUS`
table (pin 8 → GPIO33, pin 10 → GPIO32) with the board's live pinmux
(`uart6m1-xfer` occupies pins 32 and 33).

**TX vs RX above is strongly expected but was not directly verified** — the
kernel pinctrl source could not be fetched to confirm which of gpio1-0/gpio1-1
is which. Getting it backwards is harmless: you get no data, so swap the two
wires. The only mistake that damages hardware is putting a data line on a power
pin.

Confirm the wiring with a loopback before involving another device — jumper
**pin 8 to pin 10**, then:

```sh
picocom -b 115200 /dev/ttyS0     # typing should echo back; Ctrl-A Ctrl-X to exit
```

Characters coming back prove both pins are the UART and the mux is right,
without needing to know which is which.

Both sides are 3.3V, so no level shifter is needed — but you need **three**
wires, not two. Without a common ground you get silence or garbage. Do **not**
connect 5V or 3.3V between two independently powered boards.

### Reaching the UART from your laptop

`socat` is installed. Rather than opening a firewall port, tunnel over SSH —
`networking.firewall` only allows 22, so a plain TCP listener would be blocked
anyway:

```sh
# on the board
socat TCP-LISTEN:4000,bind=127.0.0.1,reuseaddr,fork /dev/ttyS0,raw,echo=0,b115200

# on the laptop
ssh -L 4000:localhost:4000 admin@tabletop-opi5plus
socat -,raw,echo=0 TCP:localhost:4000
```

For interactive use directly on the board, `picocom -b 115200 /dev/ttyS0`.

## Booting from NVMe later

The M.2 slot works and the required modules are already in
`boot.initrd.availableKernelModules`. The usual approach is to keep U-Boot on
the SD card (or write it to SPI flash) and move only the rootfs to the SSD.
Untested here — the SD path is what is validated.

## Raspberry Pi 5

```sh
nix run .#burn-rpi5 -- --list
nix run .#burn-rpi5 -- --sd /dev/rdisk4
```

Same safety checks as the Orange Pi. Two differences worth knowing:

- The Pi image is **zstd-compressed** (`.img.zst`), because it is produced by
  nixos-images' installer module rather than nixpkgs' `sd-image.nix`. `burn`
  decompresses it straight into `dd` rather than expanding it to a scratch file
  first, so the size it reports is the *decompressed* size.
- **First boot needs Ethernet.** The Pi 5 has onboard wireless, but there is no
  credential mechanism in this repo yet, and the kiosk waits on
  `network-online.target`. Without a network there is no way in, because SSH
  needs the network it does not have.

The build pulls the vendor kernel from `nixos-raspberrypi` — nixpkgs has no
`linuxPackages_rpi5` at all, only rpi0 through rpi4.

## WiFi on the Raspberry Pi (portable table)

The Pi has onboard wireless; credentials come off the SD card rather than the
repository. After flashing, reinsert the card — the **FIRMWARE** partition
mounts as a removable volume — and create `wifi.conf` on it:

```ini
ssid = YourNetworkName
psk = your-passphrase

# hidden = true      # only for a non-broadcast SSID
```

At boot, before NetworkManager starts, this becomes a keyfile at
`/etc/NetworkManager/system-connections/tabletop-wifi.nmconnection`, mode 0600.
Quotes are optional, surrounding spaces are trimmed, and CRLF line endings are
tolerated — the file gets edited on whatever laptop is to hand. A quoted value
keeps its interior spaces, so `ssid = "My Net "` is respected exactly.

No file means no WiFi, which is fine if you are on Ethernet — Ethernet takes
priority anyway. A copy of the format lives on the device at
`/etc/tabletop/wifi.conf.example`.

### Why not sops-nix

The rest of these machines use `sops-nix`, and it is the right tool for
everything *except* this. sops needs a decryption key on the device, and
getting that key onto a freshly flashed card has the identical chicken-and-egg
problem: no network, no keys, and the secret in question is what grants the
network. The out-of-band step is unavoidable; the FAT partition is simply the
cheapest channel that already exists on both boards.

The threat model is also narrower than it looks. The requirement is *do not
publish the passphrase to a public repository* — not *protect it from someone
holding the card*. NetworkManager stores the passphrase in plaintext on the root
filesystem regardless, and anyone with physical access to a tabletop very
likely has the network already.

Once a device is on the network, `sops-nix` is the right answer for every
subsequent secret, and this same file could carry an age identity instead of a
passphrase without changing the mechanism.
