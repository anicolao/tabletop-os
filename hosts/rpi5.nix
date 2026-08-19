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

  # --- Bluetooth is off, and the story behind it was wrong ------------------
  #
  # This was a "boot-time power smoothing" section, built on a claim that six
  # boots each logged "hwmon rpi_volt: Undervoltage detected!" at 10.7-11.8s.
  # That claim cannot be reproduced. in0_lcrit_alarm — the latched undervoltage
  # flag — reads 0, and no log still in existence contains an undervoltage
  # line, including rpi-boot-bat.log which is explicitly a battery boot. The
  # boots it referred to predate anything retained, so it can be neither
  # confirmed nor refuted; treat it as unsupported.
  #
  # Everything it justified has since been tested and cleared of causing the
  # boot hang: the transmit power cap (removed), the CPU governor cap (removed,
  # 33 boots at 39% with it gone), and Tor (gone with the installer profile).
  # The hang was plymouth — see docs/VC4-BOOT-HANG.md.
  #
  # What remains is the Bluetooth blacklist, kept on its own merits rather than
  # the power story: nothing on this device uses Bluetooth, and not loading a
  # radio stack that shares a die and an SDIO bus with the WiFi is a reasonable
  # default for an appliance. It is not a fix for anything.

  # 2. No Bluetooth. Nothing here uses it, and the BCM4345C0 firmware patch runs
  #    from 9.8s to 10.5s — immediately before the undervoltage, on the same
  #    radio die as the WiFi that is also initialising.
  #    btsdio is the one that matters and was missed on the first attempt: the
  #    Pi 5's Bluetooth hangs off SDIO, so btsdio is what pulls the stack in.
  #    Blacklisting the other three alone left "bluetooth 966656 1 btsdio" in
  #    lsmod — the reduction had simply not happened.
  # --- EXPERIMENT: no plymouth ----------------------------------------------
  #
  # The last item from the original Phase 2 plan that was never actually run.
  # Plymouth performs its own KMS/framebuffer handover during boot, in the same
  # window where vc4 is binding, and it is a genuine difference from the
  # known-good card's boot: that one passes plymouth.ignore-serial-consoles and
  # boots a far simpler, more serialised userspace, while this image runs the
  # full splash.
  #
  # `splash` comes off the kernel command line with it — plymouth without the
  # parameter is half a test.
  #
  # Ten hypotheses have now been eliminated by measurement (kernel version,
  # display output, brcmfmac, console_lock deadlock, framebuffer handover,
  # connector polling, fbdev emulation, the HPD IRQ handler, the duplicated
  # helper call, the governor cap). If this one fails too, the difference from
  # the working card is our userspace boot as a whole rather than any single
  # setting, and the next move is to boot working.img on this hardware and look
  # for a workaround we have not found.
  boot.plymouth.enable = lib.mkForce false;

  # Kernel version is NOT the variable, and 6.12.47 was tested to prove it.
  #
  # working.img — months of daily use, no hangs — runs 6.12.47 +rpt-rpi-2712.
  # Pinning this image to the identical nixos-raspberrypi release
  # (linux_rpi5_v6_12_47, stable_20250916) still hung: 6 boots, 3 hangs, 50%,
  # same signature. So the "regression between 6.12 and 6.18" theory is dead.
  # Left on the default kernel.


  # No boot.kernelPatches here, and the repo's rule against them stands.
  #
  # One was tried: patches/vc4-hdmi-single-hotplug.patch, removing a genuine
  # divergence from upstream where vc4_hdmi_handle_hotplug() calls
  # drm_atomic_helper_connector_hdmi_hotplug() twice. It cost a 41-minute
  # from-source aarch64 build and fixed nothing — 25 boots, 10 hangs, 40%, with
  # the hang signature completely unchanged. Verified the patched kernel really
  # booted (/run/booted-system/kernel matched the patched store path) before
  # accepting that result.
  #
  # The patch is kept in patches/ because the divergence is real and worth
  # reporting upstream. It is not applied here, because a 41-minute rebuild is a
  # steep standing cost for no measured benefit. See docs/VC4-BOOT-HANG.md.

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

  boot.kernelParams = [
    # cpufreq.default_governor=powersave REMOVED — this is the experiment.
    #
    # It pinned all four A76 cores to 1.5GHz for the whole of boot, which
    # perturbs timing in every driver. Two things make it the best remaining
    # suspect:
    #
    #   - It is one of only a handful of things this image adds to the kernel
    #     command line that the known-good card does not have. (The long list
    #     of coherent_pool/numa/vc_mem parameters that looked like differences
    #     are prepended by the Pi firmware on any card, including the working
    #     one — comparing our runtime /proc/cmdline against their cmdline.txt
    #     file was an invalid comparison on my part.)
    #   - It arrived in commit 106add8 at 21:15 on 08-15, the same evening the
    #     boot hangs started being reported. That commit was blamed once before
    #     for its iw-from-udev rule; the rule is long gone and the hangs
    #     continued, but the governor cap from the same commit had never been
    #     tested.
    #
    # It also rests on undervoltage measurements that cannot be reproduced:
    # in0_lcrit_alarm reads 0 and no surviving log contains an undervoltage
    # line. If removing it does not help, the rest of the "boot-time power
    # smoothing" section below should go too, on the same grounds.

    # --- Make the boot hang say something ------------------------------------
    #
    # This board hangs partway through boot with a dead console: no panic, no
    # oops, nothing in the journal. Ten deaths now sit between t=8.749s and
    # t=9.228s, and since the installer profile came out it happens on
    # essentially every boot, which finally makes it a reproducer rather than a
    # flake.
    #
    # The open question is whether the CPU is dead or merely blocked, and these
    # answer it without needing the console to work. If a task is stuck for 30s
    # the hung-task detector panics, and panic=10 reboots ten seconds later — so
    # a blocked-but-alive kernel comes back about 40s after the hang, where the
    # hardware watchdog currently takes a rock-steady 85s. The recovery interval
    # alone is the readout; nothing has to print for us to learn the answer.
    #
    # It may print anyway, which would be a bonus: panic() flushes the console
    # with console_flush_on_panic(), which deliberately bypasses console_lock —
    # the exact lock the leading theory says is stuck. If the fbcon handover is
    # the culprit, this is the one code path that can still get a word out.
    #
    # CONFIG_DETECT_HUNG_TASK=y and CONFIG_SOFTLOCKUP_DETECTOR=y are both set in
    # this kernel, and CONFIG_PANIC_TIMEOUT=0, so panic= is required rather than
    # merely reinforcing a default. Checked in the kernel config, not assumed.
    # hung_task_timeout_secs is deliberately NOT here. It looks like a boot
    # parameter and is not one: the kernel registers hung_task_panic= via
    # __setup, but the timeout exists only as a sysctl, defaulted from
    # CONFIG_DEFAULT_HUNG_TASK_TIMEOUT. Passing it on the command line is
    # silently ignored — verified on the running board, where /proc/cmdline
    # showed hung_task_timeout_secs=30 while kernel.hung_task_timeout_secs
    # still read 120.
    #
    # That mattered. At 120s the detector would have fired long after the
    # hardware watchdog resets the board at ~85s, so the experiment would have
    # produced a confident-looking null result and taught us nothing.
    # No debug instrumentation here. drm.debug=0x06, boot.consoleLogLevel = 8,
    # hung_task_panic, softlockup_panic and panic=10 were all used to find the
    # boot hang and are removed now that it is fixed. docs/VC4-BOOT-HANG.md
    # records how to put them back if this ever needs re-opening — in
    # particular that drm.debug is useless without consoleLogLevel = 8, because
    # drm_dbg() prints at KERN_DEBUG and the journal dies with the board.
    #
    # panic=10 is arguably worth having on an appliance regardless, so a panic
    # reboots instead of sitting there. Left out because it arrived as
    # instrumentation, not as a decision; re-add it deliberately if wanted.
  ];

  # The timeout the parameter above could not set.
  #
  # systemd-sysctl applies this at 7.46s and the earliest death observed is
  # 8.482s, so it is in force before the hang — with about a second to spare.
  # If a death is ever recorded earlier than ~7.5s, this stops being reliable
  # and the value would have to move into the kernel config instead.
  boot.kernel.sysctl."kernel.hung_task_timeout_secs" = 30;

  # tabletop-cpu-uncap is gone with the governor cap it existed to undo. It
  # restored schedutil once the kiosk was up; with nothing capping the governor
  # there is nothing to restore.


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
