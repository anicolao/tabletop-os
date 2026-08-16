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
    txPowerDbm = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      example = 15;
      description = ''
        Cap the radio's transmit power, in dBm, or null to leave it alone.

        This exists because of power, not range. On the battery-powered table
        the radio comes up at 31 dBm — the regulatory maximum, on 5GHz with an
        80MHz channel, which is the most expensive mode it has. Scanning at that
        power means repeated full-power transmit bursts, and on battery the
        supply collapses partway through: five boots died in the window between
        systemd-rfkill idling out and wpa_supplicant associating, while boots on
        wall power survived. The undervoltage warning does not reliably fire,
        because rpi_volt samples on a ~2s cadence and the collapse is faster
        than that.

        15 dBm is roughly a sixtieth of the radiated power of 31 dBm and is
        ample for an access point in the same room.

        Applied from a udev rule rather than a service, because it has to be in
        force before the first scan, and the first scan happens well before
        anything ordered after NetworkManager could run.
      '';
    };

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
    # Cap transmit power the moment the interface appears — before the first
    # scan, which is what the boot has to survive. KERNEL=="wl*" matches both
    # wlan0 and the wld0 it is renamed to.
    services.udev.extraRules = lib.mkIf (cfg.txPowerDbm != null) ''
      SUBSYSTEM=="net", ACTION=="add", KERNEL=="wl*", RUN+="${pkgs.iw}/bin/iw dev %k set txpower fixed ${toString (cfg.txPowerDbm * 100)}"
    '';

    # Re-assert it after association. Associating triggers a regulatory-domain
    # change (CTRL-EVENT-REGDOM-CHANGE ... alpha2=CA in the logs), and a regdom
    # change re-evaluates the power limit, which can undo the cap set above.
    # The udev rule protects the scan; this protects everything after it.
    systemd.services.tabletop-wifi-txpower = lib.mkIf (cfg.txPowerDbm != null) {
      description = "Re-apply the WiFi transmit power cap after association";
      after = [ "NetworkManager.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe (
          pkgs.writeShellApplication {
            name = "tabletop-wifi-txpower";
            runtimeInputs = with pkgs; [
              iw
              coreutils
            ];
            text = ''
              for dev in /sys/class/net/wl*; do
                [ -e "$dev" ] || continue
                name=$(basename "$dev")
                iw dev "$name" set txpower fixed ${toString (cfg.txPowerDbm * 100)} || true
                echo "$name txpower -> ${toString cfg.txPowerDbm} dBm"
              done
            '';
          }
        );
      };
    };

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
