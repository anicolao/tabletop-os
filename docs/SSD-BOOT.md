# Booting the Orange Pi from an NVMe SSD

Moving the Orange Pi 5 Plus off its SD card and onto an M.2 SSD.

**Status: implemented, not yet run against hardware.**

```sh
nix run .#provision-ssd    # partition the SSD and install onto it
nix run .#flash-spi        # write U-Boot to SPI, making the SSD bootable
```

Both refuse to do anything until a confirmation is typed, and everything before
that prompt is read-only. Run them in that order, with the SD card inserted
throughout.

## The one constraint that shapes everything

**The RK3588 boot ROM cannot read NVMe.** It looks for a bootloader on SPI NOR,
eMMC and SD, and nowhere else. So "boot from SSD" always means: something else
starts U-Boot, and U-Boot loads the kernel from NVMe.

That leaves exactly three places for U-Boot on this board — SPI NOR, an eMMC
module, or the SD card — and the SD card is the thing being removed.

Two facts, checked against the U-Boot this repository already builds
(`pkgs.ubootOrangePi5Plus`) rather than assumed:

```
u-boot-rockchip-spi.bin                              a SPI NOR image is built
boot_targets=mmc1 mmc0 nvme scsi usb pxe dhcp spi    NVMe is already in the order
```

So no U-Boot patching or environment editing is needed. Write the SPI image
once and U-Boot will find an extlinux configuration on NVMe by itself.

Note the order: **mmc comes before nvme**. An SD card with a valid
`/boot/extlinux/extlinux.conf` still wins. That is a feature — it makes a
bootable SD card a permanent rescue path that overrides a broken SSD without
touching the SSD.

## Options

| | Where U-Boot lives | SD needed? | One-time cost | Verdict |
|---|---|---|---|---|
| **A** | SD card | yes, permanently | none | Stepping stone |
| **B** | **SPI NOR** | **no** | **flash SPI once per board** | **Recommended** |
| C | eMMC module | no | buy eMMC | Not applicable — the SSD is bought |

**Option A — SD boots, SSD holds the root.** Keep the SD exactly as it is, move
only the root filesystem to NVMe. Every write the kiosk makes (Chromium
profile, logs, nix store) lands on the SSD, so SD wear largely stops. But the
card must stay in the slot, and `/boot` still lives on it, so every
`nixos-rebuild` writes to the card. Worth doing only as an intermediate step, or
if the SPI flash turns out to be unusable.

**Option B — U-Boot in SPI NOR, everything else on NVMe.** The SD slot is empty
in normal operation. This is the real answer, and the extra work is one
`flashcp` per board.

## Partition layout for the SSD

U-Boot reads the kernel itself, so `/boot` must be on a filesystem U-Boot
understands — ext4 or FAT. That rules out putting `/boot` on btrfs or f2fs.
Keep it simple:

```
GPT
  p1   512 MiB  FAT32  label TABLETOP_FW    /boot/firmware
  p2   rest     ext4   label TABLETOP_ROOT  /
                                            (with /boot inside it)
```

**`p1` was dropped for the Orange Pi.** U-Boot reads `/boot` from the ext4 root
perfectly well, as it does on the SD card today. The FAT partition existed only
to keep `wifi.conf` editable from a laptop, and this board has Ethernet and no
radio — `tabletop.wifi.enable` is false here — so it would be an empty partition
inside a sealed case. What is actually built is p2 alone, filling the drive. The
FAT partition stays in the plan for the Raspberry Pi, where it is load-bearing.

128 GB is far more than this needs. The nix store on a kiosk is a few
gigabytes, so the spare capacity is worth spending on generous
`configurationLimit` for rollbacks rather than on partitions.

## Configuration changes

The board differences are small and belong in `hosts/`, not `modules/`:

- **Root by label, not `root=fstab`.** The SD image gets its root device from
  `sd-image.nix`. An NVMe host needs explicit `fileSystems."/"` with
  `device = "/dev/disk/by-label/TABLETOP_ROOT"`, and `fsType = "ext4"`.
- **Drop `sd-image.nix`.** That module exists to produce an SD card image and
  brings the firmware partition, the `firmwarePartitionOffset` and the
  `u-boot at sector 64` write with it. None of that applies to NVMe.
- **`boot.loader.generic-extlinux-compatible` stays as is.** It is what writes
  the `extlinux.conf` U-Boot will read.
- **`boot.initrd.availableKernelModules` already has what is needed** — `nvme`,
  `phy_rockchip_snps_pcie3` and `pcie_rockchip_host` are in `hosts/opi5plus.nix`
  today, added in anticipation of exactly this.
- **Add `services.fstrim.enable = true`.** Nothing trims an SSD otherwise.

A `tabletop.storage` option was considered and rejected: `imports` cannot depend
on `config`, so a module cannot choose whether to import `sd-image.nix` based on
an option it defines itself. Composing two modules in `flake.nix` does the same
job without fighting the module system — see "How it is put together" above.

## Workflow: migrating the board that already exists

The kiosk holds almost no state — a Chromium profile and, on WiFi boards, a
`wifi.conf`. This is a reinstall, not a migration, and that is much safer than
cloning a live filesystem.

1. Fit the SSD in the M.2 slot. Boot from the SD card as usual.
2. Confirm the SSD enumerated: `lsblk`, `/dev/nvme0n1` present.
3. Partition and format per the layout above.
4. Install the closure onto it. Either `nixos-install --root /mnt --flake
   .#opi5plus-nvme`, or `nix copy` the closure across and run
   `switch-to-configuration boot` in the target root. The former is less
   fiddly.
5. **Flash SPI while the SD card is still in place**, so the board remains
   bootable no matter what happens:
   `flashcp -v u-boot-rockchip-spi.bin /dev/mtd0`
6. Reboot with the SD still inserted. It should boot exactly as before — mmc
   precedes nvme in the boot order, so this proves the SPI write did not break
   anything without yet testing the new path.
7. Power off, remove the SD, power on. Now U-Boot comes from SPI and the kernel
   from NVMe.
8. Keep that SD card. It is the rescue path, and it works by simply being
   inserted.

Steps 5 and 6 in that order are the whole safety argument. Flashing SPI last,
or removing the SD before verifying, turns a recoverable mistake into a
maskrom-cable exercise.

## Workflow: a new board with a blank SSD

Two candidate routes. The first is better and the reason is not obvious.

**Route 1 — provision from an SD card (recommended).** Keep one SD card flashed
with the ordinary image as a provisioning tool. Fit the blank SSD, boot the new
board from that card, then run one command from the workstation —
`nix run .#provision-ssd -- --host <board>` to partition, format and install,
then `nix run .#flash-spi -- --host <board>` to make it bootable. Power off,
pull the card, done. The same card provisions every future board.

They are two commands rather than one on purpose: the first is recoverable by
rerunning it, the second writes the bootloader. Bundling them would remove the
point at which the install can be checked while the SD card is still in charge.

**Route 2 — image the SSD directly.** Put the blank SSD in a USB-NVMe enclosure
on the workstation and write a prebuilt image to it, the way `nix run .#burn`
writes SD cards today.

Route 2 looks simpler and is not, because it only does half the job: a virgin
board still has nothing in SPI, so it still needs one SD boot (or a maskrom
cable) before it can start U-Boot at all. Route 1 does both halves in one pass
with hardware already on hand. Route 2 is worth building only if boards are
ever provisioned in quantity, where imaging SSDs in parallel would win.

## Risks and recovery

- **A bad SPI image.** Recovery is the maskrom button plus a USB-C cable to a
  host running `rkdeveloptool`, which is a real but tedious path. The mitigation
  is the ordering above: a bootable SD card overrides SPI, so a broken SPI image
  is a nuisance rather than a brick as long as a card exists.
- **`/dev/mtd0` was the open risk and is resolved.** The flash is exposed as
  `mtd0`, 16 MiB with a 4 KiB erase size. Had it not been, the design would have
  fallen back to Option A until the device tree was fixed.
- **Boot ROM order is asserted from documentation, not measured here.** It does
  not change the design — SPI, eMMC and SD are all tried before maskrom — but
  the precise precedence is worth confirming on the bench rather than trusting a
  wiki.
- **The SSD is inside the case.** Anything that requires editing files on the
  boot partition from a laptop now means disassembly. That is an argument for
  moving WiFi credentials to sops-nix on any board that needs them, once the
  board is network-reachable, rather than keeping the FAT-partition bootstrap
  forever.

## Verified on the hardware

Checked on the board before writing any of this, since the first item could
have forced the design onto the inferior option:

| check | result |
|---|---|
| SPI NOR exposed | **`mtd0: 01000000 00001000 "spi5.0"`** — 16 MiB, `/dev/mtd0` present |
| SPI contents | all zeros, not the `0xff` of erased NOR — no vendor bootloader to preserve |
| SSD enumerates | `nvme0n1`, Patriot M.2 P320, 128.0 GB, no partition table |
| PCIe link | **8.0 GT/s x4** — full PCIe 3.0 x4, not a reduced lane |
| U-Boot SPI image | `u-boot-rockchip-spi.bin`, 1,608,704 bytes, fits 16 MiB with room to spare |

## How it is put together

`hosts/opi5plus.nix` is now the board alone — SoC, kernel, device tree, GPU,
panel — and says nothing about where it boots from. The medium is a second
module composed alongside it in `flake.nix`:

```
hosts/opi5plus.nix        the board
hosts/opi5plus-sd.nix     + sd-image.nix, sdImage, U-Boot at sector 64
hosts/opi5plus-nvme.nix   + root by label, fstrim, mtd-utils
```

giving `nixosConfigurations.opi5plus` and `nixosConfigurations.opi5plus-nvme`.
Keeping the SD configuration buildable forever is deliberate: it is the rescue
path.

The layout on the SSD is a single ext4 partition labelled `TABLETOP_ROOT`, with
`/boot` inside it. The FAT firmware partition sketched below was dropped for
this board — it existed to keep `wifi.conf` editable from a laptop, the Orange
Pi has Ethernet and no radio, and the drive is now inside the case. It stays in
the plan for the Raspberry Pi, where it is load-bearing.
