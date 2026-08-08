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

## Serial: which UART to use

The board exposes two UARTs, and picking the wrong one wastes an evening.

```
ttyS2 = feb50000.serial = uart2   gpio0-13, gpio0-14   debug UART
ttyS0 = febc0000.serial = uart9   gpio2-18, gpio2-20   free
```

(Read off the running board with
`grep uart /sys/kernel/debug/pinctrl/*/pinmux-pins`.)

**`ttyS2` is the RK3588 debug UART and is already spoken for** — it carries the
kernel console at **1500000** baud *and* runs a `serial-getty`. Attach another
device there and it receives boot logs and a login prompt, while anything it
sends is typed into a shell.

**Use `/dev/ttyS0` for talking to other hardware.** It is registered, has no
console, no getty, and nothing holds it open.

`gpio2-18` and `gpio2-20` are **GPIO2_C2** and **GPIO2_C4**. Confirm which
physical header pins those are against the Orange Pi pinout before wiring — the
40-pin header is *physically* Raspberry Pi compatible (same power and ground
positions, a Pi ribbon fits) but the **GPIO functions are not the Pi's**, so
pins 8/10 are not necessarily UART here.

Wiring to another 3.3V board — a Pi, say — needs no level shifter, but needs
three wires, not two:

```
TX  →  RX
RX  →  TX
GND →  GND      mandatory; without a shared reference you get silence or garbage
```

Do **not** connect 5V or 3.3V between two independently powered boards.

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
