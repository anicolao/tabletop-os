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
        Null everywhere at present; kept because the mechanism is fiddly enough
        to be worth not rewriting if it is ever needed.

        The intent was power draw, not range. The radio comes up at 31 dBm — the
        regulatory maximum, on 5GHz with an 80MHz channel, its most expensive
        mode — and the hypothesis was that full-power scan bursts were collapsing
        the battery supply during boot, since several boots died in the window
        between systemd-rfkill idling out and wpa_supplicant associating.

        That hypothesis is not supported. Failed boots later turned up on wall
        power as well, which the theory does not allow, and the board has since
        booted repeatedly on battery with no cap at all. The boot failures had
        some other cause; capping transmit power was not what fixed them.

        Do not reach for this to fix an association problem — it cannot, and it
        can hurt. A cap only weakens the uplink, and the failure mode actually
        observed on this hardware was the access point failing to hear us. See
        the power-save note in this module's config block.

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
    # Power save off. This is not a tuning preference — it is the fix for a
    # WiFi that never once associated.
    #
    # brcmfmac defaults to power save on, and on this board that breaks the WPA2
    # four-way handshake in one specific direction. Traced with wpa_supplicant
    # at DebugLevel=debug:
    #
    #   RX message 1 of 4  ->  Sending EAPOL-Key 2/4
    #   RX message 3 of 4  ->  Sending EAPOL-Key 4/4
    #   RX message 3 of 4  ->  Sending EAPOL-Key 4/4     (x4, then reason=15)
    #
    # Message 3 arriving at all is the important part: the access point only
    # sends it after verifying the MIC on our message 2, which proves both ends
    # derived the same PTK from the same passphrase. The credentials were never
    # wrong. Our 4/4 simply never reached the AP — the radio was dozing between
    # the AP's retransmissions — so the AP retried message 3 until it gave up
    # with reason=15, "4-way handshake timeout".
    #
    # Everything confusing about this failure follows from that one fact:
    #
    #   - NetworkManager reports "no secrets: No agents were available for this
    #     request". That is its generic conclusion whenever a handshake times
    #     out, and it is a red herring: `nmcli --show-secrets` returns the psk
    #     perfectly well, and the keyfile on disk is correct.
    #   - It looks intermittent, because power save only engages once the link
    #     has been idle, so an association early in boot can succeed and the
    #     next one fail.
    #   - Raising transmit power does not help. The link is strong in both
    #     directions; the frame is not weak, it is asleep.
    #
    # 14 boots, 18 handshake failures, zero successful associations. With this
    # off it associated first try and has stayed up.
    networking.networkmanager.wifi.powersave = false;

    # And turn it off the moment the interface appears, not just when
    # NetworkManager activates a connection.
    #
    # The setting above is applied by NetworkManager during activation, which
    # leaves the very first association running against the driver default of
    # power save ON. That race is visible in the boot journal: with only the
    # NetworkManager setting, a cold boot still burned four failed handshakes
    # against the 2.4GHz radio before succeeding on the fifth attempt 66s in,
    # while the identical association pinned to that same BSSID succeeds
    # immediately once the system is up.
    #
    # Same reasoning, and the same mechanism, as the optional transmit power cap
    # appended below: udev is the only thing that runs early enough. The two
    # settings agree — NetworkManager's powersave=2 means "disable", so it will
    # not turn this back on afterwards.
    #
    # KERNEL=="wl*" matches both wlan0 and the wld0 it is renamed to. The
    # transmit power cap, when one is configured, has to be in force before the
    # first scan for the same reason, so both rules live in one definition.
    services.udev.extraRules = ''
      SUBSYSTEM=="net", ACTION=="add", KERNEL=="wl*", RUN+="${pkgs.iw}/bin/iw dev %k set power_save off"
    ''
    + lib.optionalString (cfg.txPowerDbm != null) ''
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

    # Make sure the profile actually activates.
    #
    # This was originally written to work around "no secrets: No agents were
    # available for this request" on first autoconnect. That diagnosis was
    # wrong: the real fault was the power-save handshake failure documented at
    # the top of this module, and the retry loop only ever appeared to help
    # because a later attempt occasionally got its 4/4 out in time.
    #
    # It stays because it is still the right thing for a board whose only link
    # is WiFi — an access point that is slow to appear, or briefly out of range
    # at power-on, should not cost the table its network for the whole session.
    # It should now succeed on the first attempt.
    #
    # Bounded and exits 0 either way: a tabletop with no access point in range
    # must still finish booting.
    systemd.services.tabletop-wifi-connect = {
      description = "Ensure the WiFi profile is activated";
      after = [
        "NetworkManager.service"
        "tabletop-wifi-provision.service"
      ];
      wants = [ "NetworkManager.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe (
          pkgs.writeShellApplication {
            name = "tabletop-wifi-connect";
            runtimeInputs = with pkgs; [
              networkmanager
              coreutils
              gnugrep
            ];
            text = ''
              # Pick up a keyfile that tabletop-wifi-provision has just written
              # or changed. This is the reload that used to sit in that unit's
              # ExecStartPost, where it blocked for 2m21s waiting on a
              # NetworkManager systemd had not started yet. Here NetworkManager
              # is already up, so it returns immediately.
              nmcli connection reload >/dev/null 2>&1 || true

              if ! nmcli -t -f NAME connection show 2>/dev/null | grep -qx tabletop-wifi; then
                echo "no tabletop-wifi profile; nothing to activate"
                exit 0
              fi
              for attempt in 1 2 3 4 5 6; do
                if nmcli -t -f DEVICE,STATE,CONNECTION device status 2>/dev/null \
                     | grep -q "^wl.*:connected:tabletop-wifi$"; then
                  echo "wifi connected (after $((attempt - 1)) retries)"
                  exit 0
                fi
                # Check the result rather than sleeping through it. `nmcli
                # connection up` blocks until the activation resolves, so when
                # it succeeds the link is already up and the sleep below was
                # five seconds of pure boot latency.
                if nmcli connection up tabletop-wifi >/dev/null 2>&1; then
                  echo "wifi connected on attempt $attempt"
                  exit 0
                fi
                sleep 5
              done
              echo "wifi did not activate after 6 attempts; continuing without it" >&2
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

        # No ExecStartPost here, deliberately. There used to be an
        # `nmcli connection reload` at this point, to make a live NetworkManager
        # re-read the keyfile after a nixos-rebuild switch. It cost 2m21s of
        # every boot.
        #
        # The reason is the `before` ordering above. At boot NetworkManager is
        # not running yet, so nmcli sits waiting on a D-Bus name belonging to a
        # unit that systemd will not start until this one finishes — and the `-`
        # prefix does not help, because the command is not failing, it is
        # blocking. The reload now lives in tabletop-wifi-connect, which is
        # ordered after NetworkManager and can therefore actually talk to it.
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
