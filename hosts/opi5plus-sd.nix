# Orange Pi 5 Plus booting from the SD card.
#
# The original arrangement: the Rockchip boot ROM reads U-Boot from a fixed raw
# offset near the start of the card, U-Boot reads extlinux from the ext4 root,
# and the root filesystem is the card itself. Composed with hosts/opi5plus.nix,
# which describes the board itself.
#
# Keep this buildable even after the SSD takes over. A bootable SD card outranks
# NVMe in U-Boot's boot order, which makes it the rescue path: a card that boots
# overrides a broken SSD simply by being inserted.
{
  config,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [ "${modulesPath}/installer/sd-card/sd-image.nix" ];

  sdImage = {
    # Flashing tools on macOS handle a raw .img more predictably than .img.zst,
    # and the size difference does not matter over USB.
    compressImage = false;
    # (option is `image.baseName`; `sdImage.imageBaseName` was renamed)

    # Rockchip boot ROM loads from a fixed offset near the start of the card,
    # so the first partition has to get out of the way. u-boot-rockchip.bin is
    # ~9.1 MiB written at sector 64 (32 KiB), so it occupies roughly
    # 0.03–9.2 MiB. The default 8 MiB partition offset would land inside it;
    # 16 MiB clears it with room to spare.
    firmwarePartitionOffset = 16;

    # Nothing on this board reads the FAT partition — U-Boot comes from the raw
    # offset above and the kernel from ext4. It exists only because sd-image.nix
    # always creates one.
    firmwareSize = 16;
    populateFirmwareCommands = "";

    populateRootCommands = ''
      mkdir -p ./files/boot
      ${config.boot.loader.generic-extlinux-compatible.populateCmd} \
        -c ${config.system.build.toplevel} -d ./files/boot
    '';

    # u-boot-rockchip.bin is the combined TPL+SPL+U-Boot blob. Writing this one
    # file at sector 64 is the canonical mainline method; the older two-step
    # idbloader.img + u-boot.itb dance is no longer necessary.
    postBuildCommands = ''
      dd if=${pkgs.ubootOrangePi5Plus}/u-boot-rockchip.bin of=$img \
         seek=64 conv=notrunc,fsync
    '';
  };
}
