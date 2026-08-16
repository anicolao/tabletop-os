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
      TABLETOP_WIFI_BAND=${lib.escapeShellArg (if cfg.band == null then "" else cfg.band)}
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

        Applied from a systemd unit ordered after NetworkManager, so it takes
        effect from the first association onward rather than at interface
        creation. It used to run from a udev RUN+= rule, to get in before the
        first scan. Do not put it back there: that is what was hanging the
        board mid-boot, for the reasons written up in the config block.
      '';
    };

    enable = lib.mkEnableOption ''
      reading WiFi credentials from the SD card's FAT partition at boot.

      Intended for the Raspberry Pi hosts, which have onboard wireless. The
      Orange Pi 5 Plus does not, so this stays off there
    '';

    band = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "a" "bg" ]);
      default = null;
      example = "a";
      description = ''
        Restrict the WiFi profile to one band — "a" for 5GHz, "bg" for 2.4GHz —
        or null to let the supplicant choose.

        This exists because on the Raspberry Pi 5 the choice is not free. See
        the config block for the measurements: the 2.4GHz radio here fails the
        WPA2 four-way handshake, the 5GHz radio does not, and because 2.4GHz is
        the stronger signal it is the one the supplicant tries first every time.

        A second, unrestricted profile is provisioned alongside the restricted
        one at a lower autoconnect priority, so a table carried out of range of
        the preferred band still gets a link. The restriction is a preference
        with teeth, not a lockout.
      '';
    };

    regulatoryDomain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "CA";
      description = ''
        ISO 3166-1 alpha-2 country code to pin the radio's regulatory domain
        to, or null to leave the kernel at its default.

        Leaving it at the default is not neutral. The kernel boots into domain
        `00` — "world" — and the radio then learns the real domain from the
        access point's country information element *during association*, then
        reverts to world when the attempt ends. Setting this cuts the scan work
        and stops the kernel asking the firmware for channels it will refuse.

        It does not stop the flapping, which is what it was originally added to
        do. `cfg80211.ieee80211_regdom=` registers as a *user* hint rather than
        the core default, so the revert to world still happens and a USER hint
        restoring the country follows it. Nor does it fix association — that
        was the band, see `band` above. Measured on this hardware it was worth
        one handshake failure and ~18s of boot on its own, and nothing at all
        once the band preference was in place.

        Left here because it is cheap and correct, not because anything now
        depends on it. hosts/rpi5.nix explains why that host leaves it unset.
      '';
    };

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
    # Power save off. Worth having, and — despite what this comment used to
    # say — not the fix. The band preference below is. Read this block as the
    # record of a real contributing factor, not of a solved case.
    #
    # brcmfmac defaults to power save on, and on this board that hurts the WPA2
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
    # 14 boots, 18 handshake failures, zero successful associations.
    #
    # This is necessary but not sufficient, and an earlier version of this
    # comment claimed more than the evidence supported. Turning power save off
    # produced one clean cold boot, which was a lucky sample: a later boot with
    # the udev rule below confirmed active still failed three handshakes. The
    # regulatory-domain pin further down is the other half.
    networking.networkmanager.wifi.powersave = false;

    # NO udev RUN+= rule here, and this is the important part of this file.
    #
    # There used to be one — `RUN+="iw dev %k set power_save off"` on the net
    # `add` event, with the transmit power cap using the same mechanism before
    # it. The argument for it was sound: udev is the only thing that runs early
    # enough to beat the first association. It is also, on this hardware, what
    # hangs the board.
    #
    # The boot hang that cost an entire night of bisecting every power-related
    # setting in this repository first appears the same evening `iw`-from-udev
    # was introduced, and once the serial console was capturing continuously it
    # turned out not to be random at all. Four consecutive hangs, last line
    # identical every time:
    #
    #   [    8.978] brcmfmac mmc1:0001:1 wld0: renamed from wlan0
    #   [    9.087] brcmfmac mmc1:0001:1 wld0: renamed from wlan0
    #   [    9.096] brcmfmac mmc1:0001:1 wld0: renamed from wlan0
    #   [    9.143] brcmfmac mmc1:0001:1 wld0: renamed from wlan0
    #
    # Then nothing — no panic, no oops, dead serial. That line is the rename
    # this rule keys on, so what died is the udev worker's RUN program calling
    # into nl80211 on a brcmfmac interface that is still coming up on SDIO,
    # while udev holds the device and `iw` takes rtnl_lock.
    #
    # This also explains why every theory in the previous diagnosis survived
    # testing. Capping transmit power, uncapping it, blacklisting Bluetooth,
    # pinning the governor — all of them left the rule in place, and the one
    # experiment that looked like it exonerated the radio (capping TX power)
    # was in fact *adding* a second RUN of the same kind.
    #
    # None of it is needed any more. The first association no longer races
    # anything, because tabletop.wifi.band keeps it off the radio that was
    # failing; NetworkManager's powersave=false above covers every association
    # from activation onward. If something ever genuinely must touch the
    # interface at creation time, do it from a systemd unit pulled in by
    # SYSTEMD_WANTS — not from RUN+=, which runs inside the udev worker and
    # takes the whole board down with it when it blocks.

    # What actually breaks association here: the 2.4GHz radio.
    #
    # This is the third diagnosis of this bug and the first one with a control.
    # Power save (below) and the regulatory domain (further down) were both real
    # findings that each removed a failure or two, and neither fixed it: a boot
    # with both in place still burned two handshake timeouts. What finally shows
    # the mechanism is looking at *which* access point each attempt used.
    #
    #   Associated with e0:63:da:7d:45:54  ->  reason=15, handshake failed
    #   Associated with e0:63:da:7d:45:54  ->  reason=15, handshake failed
    #   Associated with e0:63:da:7d:45:54  ->  connected, then reason=15
    #   Associated with e0:63:da:7e:45:54  ->  connected, stayed up
    #
    # And the previous boot: three failures on ...7d:45:54, then success on
    # ...7e:44:23 — a different physical access point, same story. Every failure
    # is on a 7d BSSID and every success is on a 7e one. `nmcli device wifi
    # list` says what those are:
    #
    #   E0:63:DA:7D:45:54   chan 1     2412 MHz   signal 74
    #   E0:63:DA:7E:45:54   chan 149   5745 MHz   signal 61
    #
    # So 7d is 2.4GHz and 7e is 5GHz, and the failure is band-specific across
    # two different access points — which rules out one sick AP. It also
    # explains why this looked random for so long: 2.4GHz is the *stronger*
    # signal, so the supplicant ranks it first and tries it first on every
    # single boot. The link was never intermittent. It failed deterministically,
    # then fell through to 5GHz and worked, and how long that took depended only
    # on how many attempts the retry loop needed.
    #
    # That also retires the last claim of the power-save commit, that the
    # identical association "succeeds immediately once the system is up". It
    # does — on 2.4GHz too. Whatever the interference is, it is present during
    # boot and gone afterwards, which is consistent with the panel: this host
    # drives HDMI at 2560x1440@70Hz, and pixel clocks in that range are a
    # well-known source of 2.4GHz noise on Raspberry Pi hardware. Not proven,
    # and not needed to act — preferring the band that works is right either way.
    #
    # The band preference itself is set per host, because it is a fact about a
    # radio and a room rather than about this module. See hosts/rpi5.nix.

    # Pin the regulatory domain, so the radio is never renegotiating one during
    # a handshake.
    #
    # This one is worth keeping but it is not the fix, and the first version of
    # this comment overstated it. Pinning CA did measurably help — handshake
    # failures 3 -> 2, association 55.7s -> 38.0s, and channel 14 stopped being
    # scanned — but the flapping it was meant to stop does not stop, because
    # `cfg80211.ieee80211_regdom=` is applied as a *user* hint rather than as
    # the core default. The journal still shows the revert:
    #
    #   CTRL-EVENT-REGDOM-CHANGE init=CORE type=WORLD
    #   CTRL-EVENT-REGDOM-CHANGE init=USER type=COUNTRY alpha2=CA
    #
    # Keep it anyway: it is correct for where this table lives, it cuts the
    # scan work, and the residual `set chanspec ... reason -52` lines are the
    # firmware's own country list disagreeing with cfg80211 about channels 12
    # and 13 and the 5GHz DFS band — noisy, but harmless, and not on the path
    # of anything that now matters.
    #
    # Turning power save off is necessary but it is not sufficient: a cold boot
    # with the udev rule above confirmed active — `power save disabled` logged
    # three seconds after the interface appeared — still burned three four-way
    # handshake timeouts and took 56s to associate. So there is a second cause,
    # and the journal names it. Every attempt looks like this:
    #
    #   02:25:40  Associated with e0:63:da:7d:45:54
    #   02:25:40  CTRL-EVENT-REGDOM-CHANGE init=COUNTRY_IE type=COUNTRY alpha2=CA
    #   02:25:44  CTRL-EVENT-DISCONNECTED reason=15
    #   02:25:44  WPA: 4-Way Handshake failed
    #   02:25:44  CTRL-EVENT-REGDOM-CHANGE init=CORE type=WORLD
    #
    # The board boots in domain 00 and learns CA from the access point's country
    # IE at the moment it associates, then reverts to WORLD when the attempt
    # fails — flapping once per retry. A regdom change re-evaluates channel and
    # power limits, which is why the note below had to re-assert the transmit
    # power cap after association for the same reason; here it lands in the
    # middle of the handshake instead. The re-assert of power save is visible
    # arriving at 02:25:45, one second *after* the handshake it was meant to
    # protect had already timed out.
    #
    # The same flapping explains the `brcmf_set_channel: set chanspec ... fail,
    # reason -52` spam, which appears only inside the retry window and nowhere
    # else. Decoded, the rejected channels are 12, 13 and 14 on 2.4GHz and 34,
    # 38, 42, 46, 120, 124 and 128 on 5GHz: what a world-domain scan asks for
    # and CA firmware refuses.
    #
    # On the kernel command line rather than `iw reg set` deliberately — see the
    # option's description. This sets the domain the kernel *reverts* to, which
    # a user hint does not.
    boot.kernelParams = lib.mkIf (
      cfg.regulatoryDomain != null
    ) [ "cfg80211.ieee80211_regdom=${cfg.regulatoryDomain}" ];

    # Without the database the domain above is a name the kernel cannot resolve,
    # and it silently stays at 00.
    hardware.wirelessRegulatoryDatabase = lib.mkIf (cfg.regulatoryDomain != null) true;

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

              # In profile order: the band-restricted profile first, then the
              # unrestricted fallback if provisioning wrote one. Autoconnect
              # priority already expresses this preference to NetworkManager,
              # but this unit activates by name, so it has to know the order
              # too — otherwise a table somewhere with no 5GHz would sit here
              # retrying a profile that cannot match anything in range.
              profiles=""
              for p in tabletop-wifi tabletop-wifi-any; do
                if nmcli -t -f NAME connection show 2>/dev/null | grep -qx "$p"; then
                  profiles="$profiles $p"
                fi
              done
              if [ -z "$profiles" ]; then
                echo "no tabletop-wifi profile; nothing to activate"
                exit 0
              fi

              for attempt in 1 2 3 4 5 6; do
                if nmcli -t -f DEVICE,STATE,CONNECTION device status 2>/dev/null \
                     | grep -qE "^wl.*:connected:tabletop-wifi(-any)?$"; then
                  echo "wifi connected (after $((attempt - 1)) retries)"
                  exit 0
                fi
                # Check the result rather than sleeping through it. `nmcli
                # connection up` blocks until the activation resolves, so when
                # it succeeds the link is already up and the sleep below was
                # five seconds of pure boot latency.
                for p in $profiles; do
                  if nmcli connection up "$p" >/dev/null 2>&1; then
                    echo "wifi connected on attempt $attempt via $p"
                    exit 0
                  fi
                done
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
