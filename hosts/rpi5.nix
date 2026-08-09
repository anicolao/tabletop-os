# Raspberry Pi 5 — BCM2712, VideoCore VII.
#
# The portable tabletop: HDMI display with a USB touchscreen.
#
# Unlike the Orange Pi, this does NOT use mainline. nixpkgs has no
# `linuxPackages_rpi5` at all — only rpi0 through rpi4 — so the choice is the
# nixos-raspberrypi flake's vendor kernel or compiling one from source. That
# flake also supplies matched firmware, device trees and, critically,
# `display-vc4`, which configures **full KMS**.
#
# Full KMS matters. The predecessor repository (nix-tabletop) used
# `hardware.raspberry-pi."4".fkms-3d`, the older *firmware* KMS path that
# routes display through the VideoCore blob. nixos-hardware still offers only
# that for the Pi 4 and has no display module for the Pi 5 at all — its
# raspberry-pi/5 directory is a single stub file. Full KMS is what Raspberry Pi
# OS itself defaults to now, and it is the path Mesa's v3d driver expects.
{
  config,
  lib,
  pkgs,
  nixos-raspberrypi,
  ...
}:

{
  imports = with nixos-raspberrypi.nixosModules; [
    raspberry-pi-5.base
    raspberry-pi-5.display-vc4
  ];

  networking.hostName = "tabletop-rpi5";

  # Tag the generation so `nixos-rebuild list-generations` and the boot menu say
  # which board and bootloader a given build was for — easy to lose track of
  # once there are two board types in one repo.
  system.nixos.tags =
    let
      cfg = config.boot.loader.raspberry-pi;
    in
    [
      "raspberry-pi-${cfg.variant}"
      cfg.bootloader
      config.boot.kernelPackages.kernel.version
    ];

  # The image is built through nixos-images' sdimage-installer module, which
  # brings installer-profile opinions with it. Some are wrong for a device that
  # lives permanently on a network, so override them deliberately rather than
  # letting the installer win by accident.
  networking.firewall.enable = lib.mkForce true;

  # The installer profile pulls in ZFS, which drags a kernel-module build along
  # with it. A kiosk booting from an SD card has no use for it, and building it
  # is a large fraction of the total image build time.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # The installer profile permits root SSH outright. Keep base.nix's policy:
  # key-only, and root has no keys, so there is no root login at all.
  services.openssh.settings.PermitRootLogin = lib.mkForce "prohibit-password";

  # The touchscreen here is a normal USB HID device, unlike the big table's
  # RAPT panel which needs an external box to translate it. So this is the host
  # where modules/touchscreen.nix earns its keep directly.
  tabletop.touchscreen.enable = true;

  # VideoCore VII is a much smaller GPU than Mali-G610. The kiosk's Chromium
  # flags are unchanged — `--use-angle=gles-egl` is the right backend for v3d
  # exactly as it is for Panfrost, and `--ignore-gpu-blocklist` is required
  # because Chromium blocklists v3d too.
  hardware.graphics.enable = true;

  # Onboard wireless exists here (it does not on the Orange Pi), and a
  # *portable* table is precisely the device that needs it. Still not
  # configured: a PSK cannot go in a public repository, and the FAT-partition
  # credential scheme described in modules/base.nix is unwritten and untested.
  #
  # Consequence for first boot: this needs **Ethernet**. Without a network the
  # kiosk waits on network-online.target, and there is no way in to fix it —
  # SSH needs the network it does not have.
}
