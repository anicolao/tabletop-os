# Orange Pi 5 Plus — Rockchip RK3588, Mali-G610 MP4.
#
# The primary target, and the fastest of the three boards by a wide margin.
#
# This uses *mainline* Linux and *upstream* U-Boot rather than a vendor BSP.
# That is a deliberate choice: the open panfrost/panthor stack is the only way
# to get a conformant GLES 3.1 driver here, and it exists only in mainline.
# The vendor-BSP NixOS flakes for this board (gnull/nixos-rk3588,
# tlan16/nixos-orange-5-pro) either list Mali support as a TODO or ship the
# closed libmali, so neither gets us where we need to be.
#
# Mainline prerequisites, for the record:
#   - Linux 6.10  panthor lands (Mali-G610, Valhall CSF)
#   - Linux 6.13  HDMI output on RK3588 becomes possible at all
#   - Linux 7.0   HDMI 2.1 FRL, plus H.264/HEVC stateless decoders
# `linuxPackages_latest` is therefore a hard requirement, not a preference.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [ "${modulesPath}/installer/sd-card/sd-image.nix" ];

  networking.hostName = "tabletop-opi5plus";

  boot = {
    kernelPackages = pkgs.linuxPackages_latest;

    loader = {
      grub.enable = false;
      # U-Boot's distro boot scans the bootable partition for
      # /boot/extlinux/extlinux.conf. sdImage.populateRootCommands below writes
      # exactly that.
      generic-extlinux-compatible.enable = true;
    };

    initrd.availableKernelModules = [
      # eMMC / SD
      "dw_mmc_rockchip"
      "mmc_block"
      "sdhci"
      "sdhci_pci"
      # NVMe on the M.2 slot, for booting from SSD later
      "nvme"
      "phy_rockchip_snps_pcie3"
      "pcie_rockchip_host"
      # USB, so a keyboard works in an emergency
      "xhci_pci"
      "usbhid"
    ];

    kernelModules = [
      # Mali-G610 is Valhall with a Command Stream Frontend, so it is panthor,
      # not the older panfrost kernel driver. Mesa's userspace driver is still
      # called panfrost, which is a reliable source of confusion.
      "panthor"
      # Display controller and HDMI. dw_hdmi_qp is the RK3588 controller;
      # without it the board comes up headless.
      "rockchipdrm"
      "dw_hdmi_qp"
      "phy_rockchip_samsung_hdptx"
    ];

    # RK3588's debug UART. 1500000 baud is the Rockchip standard, not a typo.
    kernelParams = [
      "console=ttyS2,1500000n8"
      "console=tty0"
    ];

    consoleLogLevel = lib.mkDefault 4;
  };

  hardware = {
    deviceTree = {
      enable = true;
      name = "rockchip/rk3588-orangepi-5-plus.dtb";
    };

    # panthor requests arm/mali/arch10.8/mali_csffw.bin at probe time. There is
    # no separate mali-g610-firmware package in nixpkgs — it ships inside
    # linux-firmware, which this pulls in. If the GPU does not come up, this is
    # the first thing to check: `dmesg | grep panthor`.
    enableRedistributableFirmware = true;

    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        # Mesa's panfrost gallium driver drives G610 through panthor.
        mesa
        # Video decode via the mainline stateless decoders.
        libva
        libva-vdpau-driver
      ];
    };
  };

  # 16 GiB of RAM and 8 cores make this a credible aarch64-linux build machine
  # in its own right — see docs/BUILDING.md.
  nix.settings.max-jobs = lib.mkDefault 8;

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
