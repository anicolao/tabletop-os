# System basics shared by every board and by the emulator.
#
# Deliberately small. Anything a tabletop does not need is a thing that can
# break, consume flash, or delay boot on a device with no keyboard attached.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  system.stateVersion = "26.05";

  time.timeZone = lib.mkDefault "America/Toronto";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  networking = {
    hostName = lib.mkDefault "tabletop";
    # Ethernet + DHCP is the whole story today, and it is enough: the Orange Pi
    # 5 Plus has 2x2.5GbE and *no onboard wireless* — only an empty M.2 E-key
    # slot for an optional Wi-Fi6/BT module.
    #
    # There is deliberately no WiFi configuration anywhere in this repo. When
    # the Raspberry Pi hosts land they do have onboard wireless and will need
    # it; the plan is to read credentials from the FAT partition of the SD card
    # at boot rather than commit a PSK to a public repository or bake one into
    # a world-readable nix store. Until there is hardware to test against,
    # writing that would be writing untested code.
    networkmanager.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };

  # Wait for an address before declaring the network up, so the kiosk's
  # network-online.target dependency means what it says.
  systemd.services.NetworkManager-wait-online.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      # There is no console on a tabletop. SSH is the only way in, and it must
      # be key-only.
      PermitRootLogin = "prohibit-password";
    };
  };

  # An admin account for `ssh admin@tabletop`. There is deliberately no
  # password anywhere in this repo; keys in ../admin-keys.nix are the only way
  # in. An empty list there trips a NixOS assertion at build time rather than
  # producing an image nobody can log into.
  users.users.admin = {
    isNormalUser = true;
    description = "Tabletop administrator";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    openssh.authorizedKeys.keys = import ../admin-keys.nix;
  };
  users.mutableUsers = lib.mkDefault false;
  security.sudo.wheelNeedsPassword = false;

  # mkDefault throughout: qemu-vm.nix has its own opinions about several of
  # these, and the emulator should be allowed to win.
  services.timesyncd.enable = lib.mkDefault true;

  environment.systemPackages = with pkgs; [
    git
    htop
    neovim
    tmux
    # Diagnosing "is the GPU actually being used" — see docs/ARCHITECTURE.md.
    mesa-demos
    libva-utils
    vulkan-tools
    wayland-utils
    evtest

    # Serial and USB work. The touch panel is driven by a separate box over
    # UART, and the panel itself is a non-HID USB device, so both buses need
    # to be inspectable from here.
    #
    # Use /dev/ttyS0 (uart6, on 40-pin header pins 8/10) for that link — NOT
    # ttyS2, the debug UART carrying the kernel console and a live getty.
    picocom
    socat
    usbutils
    psmisc # fuser, for finding what already holds a tty
  ];

  # These boards run from flash with no swap partition. zram buys headroom
  # without wearing the card out.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 25;
  };

  # A kiosk is left powered on for hours; never let anything blank or suspend.
  powerManagement.enable = lib.mkDefault false;
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandlePowerKey = "poweroff";
    IdleAction = "ignore";
  };

  documentation = {
    enable = false;
    nixos.enable = false;
    man.enable = false;
  };

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    auto-optimise-store = true;

    # Required for `nixos-rebuild --target-host`. Without this the board
    # refuses locally-built paths with "lacks a signature by a trusted key" —
    # packages fetched from cache.nixos.org carry signatures and copy fine, but
    # anything built on the laptop (system-path, the closure itself) does not.
    #
    # No escalation: these accounts already have passwordless sudo, so being
    # able to insert store paths grants nothing they could not already do.
    trusted-users = [
      "root"
      "@wheel"
    ];
  };
}
