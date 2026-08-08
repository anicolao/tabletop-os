# Emulation target.
#
# What this IS: the real kiosk stack — same base, same cage, same Chromium with
# the same flags, same launcher URL — booted in QEMU so it can be exercised
# without touching hardware.
#
# What this is NOT: a boot of the Orange Pi SD image. QEMU has no RK3588
# machine model, so the actual image built by hosts/opi5plus.nix cannot be run
# here at any fidelity. Bootloader, device tree, panthor and the whole display
# pipeline are exactly the parts this cannot test.
#
# It is still worth having, because most kiosk bugs are software bugs: a wrong
# Chromium flag, a service ordering mistake, a launcher that does not load.
# Those all reproduce here in seconds instead of a reflash-and-reboot cycle.
#
# See docs/EMULATION.md for what each layer does and does not cover.
{
  config,
  lib,
  pkgs,
  hostPkgs,
  modulesPath,
  ...
}:

{
  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

  networking.hostName = "tabletop-vm";

  # Build the runner for the machine that will run qemu, not for the guest.
  # Without this, `nix run .#vm` on a Mac produces an aarch64-linux script that
  # the Mac cannot execute.
  virtualisation.host.pkgs = hostPkgs;

  virtualisation = {
    memorySize = 4096;
    cores = 4;
    diskSize = 8192;

    # Open a window. The entire point is watching the launcher come up.
    graphics = true;

    # `ssh -p 2222 admin@localhost` reaches the guest, which is how you inspect
    # `systemctl status cage-tty1` and `journalctl` without fighting the
    # graphical console.
    forwardPorts = [
      {
        from = "host";
        host.port = 2222;
        guest.port = 22;
      }
    ];

    # qemu-vm.nix already supplies usb-ehci, usb-kbd and usb-tablet when
    # graphics is on, so only the GPU needs adding. A tablet gives absolute
    # pointer coordinates, which is the closest QEMU gets to touch input.
    qemu.options = [
      # virtio-gpu gives the guest a real DRM device, which is what cage needs
      # to start at all. Rendering is host-side rather than a Mali, so treat any
      # performance number from here as meaningless.
      "-device virtio-gpu-pci"
    ];
  };

  # There is no panthor here and no Mali firmware to load. Chromium will fall
  # back to software rendering via llvmpipe; that is expected in the VM and a
  # bug on the board.
  hardware.graphics.enable = true;

  # The image writes extlinux for U-Boot; the VM boots straight into the
  # kernel, so it needs a bootloader that qemu-vm understands.
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = false;

  # Serial console, so `nix run .#vm` prints something useful in the terminal
  # alongside the graphical window.
  boot.kernelParams = [ "console=ttyAMA0,115200n8" ];

  # Log in without a password on the console. Safe here precisely because this
  # configuration never reaches hardware — hosts/opi5plus.nix does not import it.
  services.getty.autologinUser = lib.mkDefault "admin";
  users.users.admin.password = lib.mkForce "tabletop";
  users.users.root.password = lib.mkForce "tabletop";
  services.openssh.settings.PermitRootLogin = lib.mkForce "yes";
  services.openssh.settings.PasswordAuthentication = lib.mkForce true;

  # NetworkManager cannot get anywhere useful behind qemu's user-mode NAT, and
  # the kiosk waits on network-online.target before starting. Use the simple
  # DHCP client so that target is actually reached.
  networking.networkmanager.enable = lib.mkForce false;
  networking.useDHCP = lib.mkForce true;
  systemd.services.NetworkManager-wait-online.enable = lib.mkForce false;
}
