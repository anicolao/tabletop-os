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

  # The `lib.mkForce` overrides that used to live here are gone, along with the
  # installer profile they were fighting. flake.nix explains what that profile
  # was doing; what matters here is that seven forced overrides — firewall on,
  # ZFS off, PermitRootLogin, systemd-networkd off, useNetworkd off, iwd off,
  # Tor off — existed only to undo it, one symptom at a time, and were still
  # losing. Removing the cause removes all of them.
  #
  # The one that is worth remembering, because it cost a deploy to find: forcing
  # `networking.useNetworkd` did nothing, because the profile set
  # `systemd.network.enable` directly. Two of those overrides also encoded real
  # failures — systemd-networkd running beside NetworkManager and burning its
  # full 121s wait-online timeout on every boot, and iwd being enabled while
  # networkmanager.wifi.backend stayed "wpa_supplicant", which is why the radio
  # sat permanently "unavailable". Neither can recur now; if either does, the
  # installer profile has come back.
  #
  # There is an assertion at the bottom of this file that fails the build if it
  # does.

  # One of those seven has to stay, and its old comment was wrong about why.
  # ZFS does not come from the installer profile — it survived its removal, and
  # a unit diff against the previous build showed twenty zfs-* units reappearing
  # the moment this line was dropped. It comes from nixos-raspberrypi's own
  # full config. A kiosk booting from an SD card has no use for it, and it drags
  # a kernel-module build along with it, which is a large fraction of the total
  # image build time.
  boot.supportedFilesystems.zfs = lib.mkForce false;

  # --- Boot-time power smoothing --------------------------------------------
  #
  # This board runs from a battery that drove the official Raspberry Pi image
  # for months without trouble, so the supply is not the variable — this image
  # is. systemd coldplugs every device at once around 8.4s, while four
  # Cortex-A76 cores are free to run at 2.4GHz and the WiFi and Bluetooth
  # firmware loads land in the same window.
  #
  # Measured across six boots: "hwmon rpi_volt: Undervoltage detected!" at
  # 10.7-11.8s on every single one, and three consecutive boots stopped logging
  # at exactly 14s with the compositor never starting. A timeout leaves logs
  # behind; this leaves nothing, which is what a brownout looks like.
  #
  # Three reductions, cheapest first.

  # 1. No Tor — nothing to do here any more. Tor and hidden-ssh-announce came
  #    from the installer profile, which is gone. Disabling them by hand was
  #    also never as complete as it looked: it stopped the daemon and the
  #    announce unit, but not the status screen that printed "Onion address:
  #    Waiting for tor network to be ready..." on tty1 forever, precisely
  #    *because* Tor would now never be ready.

  # 2. No Bluetooth. Nothing here uses it, and the BCM4345C0 firmware patch runs
  #    from 9.8s to 10.5s — immediately before the undervoltage, on the same
  #    radio die as the WiFi that is also initialising.
  #    btsdio is the one that matters and was missed on the first attempt: the
  #    Pi 5's Bluetooth hangs off SDIO, so btsdio is what pulls the stack in.
  #    Blacklisting the other three alone left "bluetooth 966656 1 btsdio" in
  #    lsmod — the reduction had simply not happened.
  boot.blacklistedKernelModules = [
    "btsdio"
    "btbcm"
    "hci_uart"
    "bluetooth"
  ];

  # brcmfmac is deliberately NOT blacklisted-and-deferred here, though it was
  # tried. That experiment is worth not repeating: the boot hang looked like it
  # lived in brcmfmac, because six consecutive deaths ended on the same line —
  # `brcmfmac mmc1:0001:1 wld0: renamed from wlan0` — with nothing after it.
  # Loading the driver from a unit after the coldplug storm instead, so it was
  # not in that window at all, did not help. The board hung twice more at 8.879s
  # and 8.918s, now ending on the DRM framebuffer line instead.
  #
  # So brcmfmac was never the cause; it was whatever printed last. See
  # NEXT_STEPS.md for where that leaves the diagnosis.

  # 3. Hold the CPU at its lowest frequency until the kiosk is up.
  #
  #    This is the largest single draw: four A76 cores under schedutil ramp to
  #    2.4GHz to service the coldplug storm, and DVFS raises core voltage with
  #    frequency, so the current cost is worse than linear. 1.5GHz is the lowest
  #    this SoC offers. Boot takes slightly longer and stops browning out, which
  #    is the trade being made deliberately.
  #    Done with a kernel parameter rather than a service, because a service
  #    cannot win this race: the first attempt ran at 11.47s, which is *after*
  #    the 10.7-11.8s brownout window it was meant to protect. systemd simply
  #    does not schedule anything of ours early enough. cpufreq applies its
  #    default governor the moment it registers a policy, long before userspace,
  #    so the cap is in force for the whole coldplug storm.
  boot.kernelParams = [ "cpufreq.default_governor=powersave" ];

  systemd.services.tabletop-cpu-uncap = {
    description = "Restore full CPU frequency once the kiosk is up";
    wantedBy = [ "graphical.target" ];
    after = [ "cage-tty1.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe (
        pkgs.writeShellApplication {
          name = "tabletop-cpu-uncap";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            # The browser is the thing that wants the cores, and by now it has
            # them. Hand the frequency back so the launcher is not permanently
            # slow — powersave pins every core to the minimum, which is fine for
            # bringing hardware up and not fine for compositing at 4K.
            for p in /sys/devices/system/cpu/cpufreq/policy*; do
              if [ -w "$p/scaling_governor" ]; then
                echo schedutil > "$p/scaling_governor" || true
              fi
              max=$(cat "$p/cpuinfo_max_freq" 2>/dev/null || echo "")
              if [ -n "$max" ] && [ -w "$p/scaling_max_freq" ]; then
                echo "$max" > "$p/scaling_max_freq" || true
              fi
            done
            echo "restored: governor=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null) max=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null) kHz"
          '';
        }
      );
    };
  };

  # --- Recover from the boot hang without a human ----------------------------
  #
  # This board intermittently hangs partway through boot. The kernel simply
  # stops emitting — no panic, no oops, no undervoltage warning at the moment of
  # death — and the serial console goes completely dead, accepting no input, so
  # only a physical power cycle clears it. Death times observed so far: 7s, 8s,
  # 9.2s, 14s, 15s, 41s.
  #
  # The cause is not known. Every software theory tried has been disproved by
  # evidence rather than argument: it happens on wall power as well as battery,
  # on two different SD cards, with the radio's transmit power capped, with
  # Bluetooth blacklisted, with all four cores pinned to minimum for the whole
  # of boot, and with the installer profile's extra services disabled. A hard
  # hang that is indifferent to every power reduction, at a time that varies by
  # a factor of six, does not look like any of those.
  #
  # So this does not fix it. It makes it self-clearing, which is worth more
  # here than a diagnosis: systemd is already running well before every observed
  # death time, so it has opened /dev/watchdog and started petting it. A full
  # lockup stops the petting, and the SoC resets itself rather than waiting for
  # someone to walk over to the table and pull the plug.
  #
  # That turns "the tabletop sometimes does not come up" into "the tabletop
  # occasionally takes an extra minute to come up" — which, for an appliance
  # nobody logs into, is the difference that matters.
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "2min";
  };

  # The touchscreen here is a normal USB HID device, unlike the big table's
  # RAPT panel which needs an external box to translate it. So this is the host
  # where modules/touchscreen.nix earns its keep directly.
  tabletop.touchscreen.enable = true;

  # VideoCore VII is a much smaller GPU than Mali-G610. The kiosk's Chromium
  # flags are unchanged — `--use-angle=gles-egl` is the right backend for v3d
  # exactly as it is for Panfrost, and `--ignore-gpu-blocklist` is required
  # because Chromium blocklists v3d too.
  hardware.graphics.enable = true;

  # Onboard wireless exists here, unlike the Orange Pi, and a *portable* table
  # is precisely the device that needs it. Credentials come off the SD card's
  # FAT partition rather than the repository — see modules/wifi.nix for why
  # this is a bootstrap problem that sops-nix cannot solve.
  #
  # Ethernet still works and takes priority if plugged in. If neither is
  # available the kiosk waits on network-online.target with no way in, since
  # SSH needs the network it does not have.
  # HDMI presents EDID as soon as the panel is awake; it has none of the
  # DisplayPort alt-mode negotiation the Orange Pi waits through, so the 180s
  # default is three minutes of nothing if the screen happens to be asleep at
  # power-on. Observed exactly that: "no usable display after 180s", with the
  # cable connected and the monitor simply off.
  tabletop.kiosk.displayTimeoutSeconds = 45;

  tabletop.wifi.enable = true;

  # Regulatory domain deliberately left unset, though this table is in Canada
  # and the option exists.
  #
  # Pinning it to CA was tried and measured. On its own it did help — handshake
  # failures 3 -> 2, association 55.7s -> 38.0s — but the band preference below
  # subsumes all of it: with band=a the rejected-channel spam it was meant to
  # cure went to zero on its own, because the scan no longer visits 2.4GHz at
  # all. So it buys nothing here.
  #
  # And it is not free. Setting it pulls wireless-regdb in and makes the kernel
  # load and verify the signed regulatory database during early boot, landing
  # at t=8.6s — roughly 400ms before the point where this board's intermittent
  # boot hang strikes. Three consecutive hangs were captured with it enabled,
  # all at t=8.98s, 9.09s and 9.14s and all on the same line:
  #
  #   brcmfmac mmc1:0001:1 wld0: renamed from wlan0
  #
  # That is not proof it is the cause — the hang predates this option and two
  # boots with it enabled came up fine — but it is a change with no remaining
  # benefit sitting on top of the one unexplained fault in this image, and that
  # is a bad trade. If the domain is ever needed, set it and re-measure the
  # hang rate deliberately rather than as a side effect.
  # tabletop.wifi.regulatoryDomain = "CA";

  # Prefer 5GHz. On this board 2.4GHz fails the WPA2 four-way handshake during
  # boot while 5GHz associates first try, and since 2.4GHz is the stronger
  # signal here it is what the supplicant reaches for unless told otherwise —
  # so every boot spent 30-55s failing before falling through to the band that
  # works. modules/wifi.nix has the per-BSSID evidence.
  #
  # Not a lockout: provisioning also writes an unrestricted profile at a lower
  # autoconnect priority, so a table carried somewhere with only 2.4GHz still
  # comes up. It is the *order* that was costing the boot, not the existence of
  # the other band.
  tabletop.wifi.band = "a";

  # No txPowerDbm cap here, deliberately. It was set to 15 dBm on the theory
  # that full-power scan bursts were browning out the battery, and that theory
  # did not survive: failed boots happened on wall power too, and the board has
  # since booted repeatedly on battery without the cap.
  #
  # It is also the wrong direction to push. The one proven fragility on this
  # link is uplink — see modules/wifi.nix on the four-way handshake, where the
  # access point could not hear our EAPOL 4/4 — and a sixtieth of the radiated
  # power makes that worse, not better. The option still exists if a future
  # measurement actually justifies it.

  # --- Keep the installer profile out ---------------------------------------
  #
  # These check for the things that profile did, not for the profile itself,
  # because the damage was never the module — it was a root password on the
  # screen and a getty holding the kiosk's VT. An import path can be renamed;
  # these facts are what actually matter, and they are cheap to assert.
  #
  # This exists because the profile was present for the entire life of this
  # host without anyone noticing, while `hosts/rpi5.nix` disabled its symptoms
  # one by one. A build-time check is the difference between that and finding
  # out from a photograph of the table.
  assertions = [
    {
      assertion =
        config.users.users.root.hashedPassword == null
        && config.users.users.root.initialHashedPassword == null
        && config.users.users.root.password == null;
      message = ''
        A root password is set on tabletop-rpi5. Nothing in this repository
        sets one, so an installer profile has come back — nixos-images'
        image-installer sets one with chpasswd on every activation and prints
        it on the attached screen. Check flake.nix: this host must use
        `nixos-raspberrypi.lib.nixosSystemFull`, not `lib.nixosInstaller`.
      '';
    }
    {
      assertion = config.services.getty.autologinUser == null;
      message = ''
        tabletop-rpi5 would autologin ${toString config.services.getty.autologinUser}
        on the console. Besides being a login nobody asked for, that getty wants
        the same VT as cage-tty1 and is a suspect for the compositor restarts.
      '';
    }
    {
      assertion = !config.services.tor.enable && !config.systemd.network.enable;
      message = ''
        Tor or systemd-networkd is enabled on tabletop-rpi5. Both arrive with
        the installer profile; networkd in particular runs beside NetworkManager
        and burns its full 121s wait-online timeout on every boot.
      '';
    }
  ];
}
