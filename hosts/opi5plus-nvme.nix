# Orange Pi 5 Plus booting from the NVMe SSD.
#
# The boot ROM cannot read NVMe — it looks only at SPI NOR, eMMC and SD — so the
# chain is: boot ROM -> U-Boot in SPI flash -> extlinux on the SSD -> kernel and
# root on the SSD. Writing U-Boot to SPI is a separate, one-time step per board;
# see docs/SSD-BOOT.md and `nix run .#flash-spi`.
#
# Nothing here selects a bootloader. hosts/opi5plus.nix already enables
# generic-extlinux-compatible, and U-Boot's stock boot order on this board
# already includes nvme:
#
#   boot_targets=mmc1 mmc0 nvme scsi usb pxe dhcp spi
#
# Note mmc precedes nvme. That is deliberate insurance rather than an oversight:
# an SD card carrying a valid extlinux.conf still wins, so a bootable card
# overrides a broken SSD by being inserted, without touching the SSD.
{
  lib,
  pkgs,
  ...
}:

{
  # Found by label so the installer never has to hardcode a device node, and so
  # the initrd's root=fstab lookup resolves the same way it does on the card.
  # scripts/provision-ssd.sh writes this label; the two must agree.
  fileSystems."/" = {
    device = "/dev/disk/by-label/TABLETOP_ROOT";
    fsType = "ext4";
    # An SD card was worth mounting noatime to spare the flash. The SSD does not
    # need protecting, but a kiosk still has no use for access times.
    options = [ "noatime" ];
  };

  # Nothing trims an SSD on its own, and a kiosk never runs a maintenance task
  # by hand.
  services.fstrim.enable = true;

  # 128 GB against a root closure of a few gigabytes. Spend the space on being
  # able to roll back a long way rather than on partitions: every entry here is
  # a bootable generation in U-Boot's menu.
  boot.loader.generic-extlinux-compatible.configurationLimit = lib.mkDefault 30;

  environment.systemPackages = with pkgs; [
    # flashcp and flash_erase, for writing U-Boot to SPI. Without these the
    # board cannot provision its own bootloader, which is the one job that
    # cannot be done from the workstation.
    mtdutils
    # nvme-cli, for reading SMART data off the drive.
    nvme-cli
  ];

  # So `nixos-rebuild list-generations` and the boot menu say which medium a
  # given build was for. Two systems for one board is exactly the situation
  # where that ambiguity bites.
  system.nixos.tags = [ "nvme" ];
}
