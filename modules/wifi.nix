# WiFi credentials delivered on the SD card's FAT partition.
#
# Off by default. The Orange Pi 5 Plus has no onboard wireless at all — only an
# empty M.2 E-key slot — so this is meaningful only on the Raspberry Pi hosts.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.tabletop.wifi;

  provision = pkgs.writeShellApplication {
    name = "tabletop-wifi-provision";
    runtimeInputs = with pkgs; [
      coreutils
      gnused
    ];
    text = ''
      TABLETOP_WIFI_FILE=${lib.escapeShellArg cfg.credentialsFile}
      TABLETOP_NM_DIR=/etc/NetworkManager/system-connections
    ''
    + builtins.readFile ../scripts/wifi-provision.sh;
  };
in
{
  options.tabletop.wifi = {
    enable = lib.mkEnableOption ''
      reading WiFi credentials from the SD card's FAT partition at boot.

      Intended for the Raspberry Pi hosts, which have onboard wireless. The
      Orange Pi 5 Plus does not, so this stays off there
    '';

    credentialsFile = lib.mkOption {
      type = lib.types.str;
      default = "/boot/firmware/wifi.conf";
      description = ''
        Path to the credentials file, on the FAT partition that the Raspberry
        Pi bootloader already requires. That partition mounts as a plain
        removable volume on any laptop, which is the whole point: it is
        reachable without the network it exists to provide.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.tabletop-wifi-provision = {
      description = "Provision WiFi credentials from the SD card";
      # Before NetworkManager, so the profile exists the first time it looks,
      # and after the FAT partition is mounted, so there is something to read.
      before = [ "NetworkManager.service" ];
      after = [ "boot-firmware.mount" ];
      requires = [ "boot-firmware.mount" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe provision;

        # Tell NetworkManager to re-read the keyfile, if it is already running.
        #
        # At boot the ordering above is enough: the profile exists before
        # NetworkManager starts. On a nixos-rebuild switch it is not — this
        # service reruns while NetworkManager is live, which leaves it holding a
        # cached copy of the connection without the passphrase. The symptom is
        # obscure and cost real time: NetworkManager logs "no secrets: No agents
        # were available for this request" and refuses to associate, while the
        # keyfile on disk is perfectly correct. A reload fixes it immediately.
        #
        # `-` prefix: NetworkManager not running is the normal boot case, not a
        # failure.
        ExecStartPost = "-${pkgs.networkmanager}/bin/nmcli connection reload";
      };
      unitConfig = {
        # A missing or malformed file is not a failure — the device may be on
        # Ethernet. The script says so and exits 0.
        ConditionPathExists = "!/etc/NetworkManager/system-connections/tabletop-wifi.nmconnection.keep";
      };
    };

    # An example the user can copy, since the format has to be guessed at
    # otherwise. Lives in the store, not on the FAT partition — writing it
    # there would mean shipping a file that looks like configuration but is not.
    environment.etc."tabletop/wifi.conf.example".text = ''
      # Copy this to the FIRMWARE partition of the SD card as `wifi.conf`.
      # It mounts as a removable volume when the card is in a laptop.
      #
      # Read at boot and turned into a NetworkManager profile. Values may be
      # quoted or not; CRLF line endings are tolerated.
      ssid = YourNetworkName
      psk = your-passphrase

      # Uncomment for a non-broadcast SSID:
      # hidden = true
    '';
  };
}
