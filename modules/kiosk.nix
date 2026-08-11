# The kiosk itself: a Wayland compositor with exactly one client, a browser.
#
# This module is identical on every board. Nothing here knows what GPU it is
# running on — the platform difference is confined to hosts/, which supplies a
# working DRM device and Mesa driver. If this file ever needs an `if board ==`
# in it, something has gone wrong.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.tabletop.kiosk;

  # Ordered roughly by how load-bearing they are, most first.
  chromiumFlags = [
    # --- correctness: without these the browser silently renders on the CPU ---

    # Chromium ships a GPU blocklist that covers both panfrost (Mali) and v3d
    # (VideoCore). Without this it falls back to SwiftShader and every number
    # below collapses. This is the single most important flag in the list.
    "--ignore-gpu-blocklist"

    # Talk to the compositor directly rather than through XWayland.
    "--ozone-platform=wayland"

    # Which ANGLE backend to use. `gles-egl` is native GLES, the path that
    # makes WebGL hardware-accelerated on Mali and VideoCore alike. (The older
    # `--use-gl=egl` spelling is deprecated and now ignored.)
    #
    # Pinning this means a failed GPU stack yields *no* WebGL rather than a
    # silent drop to software — deliberate on hardware, where slow-but-working
    # would hide the failure. The emulator overrides it, because QEMU on macOS
    # offers no accelerated 3D at all.
    "--use-angle=${cfg.angleBackend}"

    # --- performance ---

    "--enable-gpu-rasterization"
    "--enable-zero-copy"
    # Canvas2D on the GPU rather than the CPU.
    "--canvas-oop-rasterization"
    "--enable-features=VaapiVideoDecodeLinuxGL"
    "--num-raster-threads=4"

    # The panel is the panel. Let CSS pixels equal device pixels so that
    # compositor-driven animations are not resampled.
    "--force-device-scale-factor=1"

    # --- kiosk behaviour ---

    "--kiosk"
    "--no-first-run"
    "--noerrdialogs"
    "--disable-infobars"
    "--disable-session-crashed-bubble"
    "--disable-features=Translate"
    # A tabletop has no keyboard; there is no way to dismiss an update prompt.
    "--check-for-update-interval=31536000"
    # Touch scrolling should not trigger back/forward navigation.
    "--overscroll-history-navigation=0"
  ]
  ++ lib.optional cfg.incognito "--incognito"
  ++ cfg.extraChromiumFlags;
in
{
  options.tabletop.kiosk = {
    enable = lib.mkEnableOption "the browser kiosk" // {
      default = true;
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = "https://anicolao.github.io/ttlauncher/";
      description = ''
        The page the kiosk displays. Served over the network rather than
        embedded in the image, so the launcher can be updated by pushing to
        its own repository without rebuilding or reflashing anything.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "kiosk";
      description = "Unprivileged user the browser runs as.";
    };

    incognito = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run the browser in incognito mode. Off by default: the launcher is
        expected to hold a login, and a tabletop that forgets who you are on
        every power cycle is worse than one that accumulates a profile.
      '';
    };

    angleBackend = lib.mkOption {
      type = lib.types.str;
      default = "gles-egl";
      example = "swiftshader";
      description = ''
        ANGLE backend passed as `--use-angle=`.

        `gles-egl` is native GLES and is what makes WebGL hardware-accelerated
        on Mali (Panfrost) and VideoCore (V3D). `vulkan` is worth benchmarking
        on RK3588 once PanVK is trusted. `swiftshader` is CPU rendering — only
        appropriate where there is no GPU at all, which in practice means the
        emulator.

        A separate option rather than something to override through
        extraChromiumFlags, because relying on a later duplicate `--use-angle`
        beating an earlier one is an undocumented Chromium behaviour to build
        on.
      '';
    };

    clientStartDelaySeconds = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = ''
        How long to wait after the compositor starts before launching the
        browser.

        Not a cosmetic delay. Chromium launched at the instant cage starts
        wedges — spinning, with no renderer and no surface — while the same
        command run against an already-running cage works every time. See
        services.cage.program below.
      '';
    };

    displayTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 180;
      description = ''
        How long to wait for a connected display before starting the kiosk
        anyway.

        Very generous on purpose. DisplayPort over USB-C appears after PD
        negotiation and alt-mode entry at around 15-20 seconds, but a usable
        link takes longer: the AUX channel times out repeatedly on a cold boot
        and has been seen to settle only near the 100 second mark. Waiting
        costs nothing on HDMI, which is ready on the first attempt.
      '';
    };

    extraChromiumFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--enable-unsafe-swiftshader" ];
      description = "Flags appended after the defaults, so they win on conflict.";
    };

    diagnosticTabs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "file:///run/tabletop/status.html" ];
      description = ''
        Extra tabs opened behind the launcher, in order.

        The launcher is the active tab; these sit underneath it. Closing the
        launcher with Ctrl+W reveals them rather than exiting immediately, so
        anyone debugging by closing windows walks out through the diagnostics
        before the kiosk restarts.

        `chrome://gpu` is deliberately *not* here. Chromium silently discards
        `chrome://` URLs passed as command-line arguments — verified: passing
        it alongside two other URLs opens two tabs, not three, with no error.
        Since kiosk mode also has no address bar to navigate with, that page is
        simply unreachable on this device.

        The status page asks the same question a different way: it creates a
        WebGL context and reports the unmasked renderer, which is the number
        that actually matters. See modules/status.nix.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isNormalUser = true;
      description = "Tabletop kiosk";
      # video: DRM/KMS access. input: evdev for the touchscreen.
      # seat: logind seat assignment, which is how cage acquires the DRM master.
      extraGroups = [
        "video"
        "input"
        "seat"
      ];
    };

    # cage is a wlroots compositor that runs a single application fullscreen.
    # It gives the browser a Wayland surface with a direct-scanout path to KMS,
    # which is the shortest route from Chromium's compositor to the panel.
    services.cage = {
      enable = true;
      user = cfg.user;
      # -m last: drive one output, never span.
      #
      # cage's default is "-m extend", which joins every connected output into a
      # single logical surface. With HDMI and DisplayPort both plugged in that
      # put half the launcher on each panel, offset — the "it was displaying,
      # but offset as though the two outputs were one big monitor" report.
      #
      # With a single cable attached this changes nothing at all, since there is
      # only one output to choose. It matters only for the both-connected case,
      # which is explicitly a nice-to-have here.
      #
      # NB "-d" is NOT debug; it means "don't draw client side decorations".
      # Debug logging is "-D".
      extraArguments = [
        "-m"
        "last"
      ];
      # The launcher is listed first so it is the active tab; diagnosticTabs sit
      # behind it and are revealed one Ctrl+W at a time.
      # Chromium is started through a short delay rather than directly.
      #
      # cage spawns its client immediately on startup, and a Chromium that
      # starts into a compositor still bringing its output up wedges: the
      # browser process spins, then sits with only its three zygotes — no GPU
      # process, no renderer, no surface — while cage waits forever for a
      # client that will never map. The panel stays black and every service
      # reports active.
      #
      # This was isolated by elimination. Launched by hand against an
      # *already running* cage, the very same binary with the very same
      # arguments, profile and URLs starts correctly every time. Flags,
      # profile corruption and the launcher URL were each ruled out that way;
      # the only remaining variable is when the client connects relative to
      # the compositor finishing setup.
      program = "${pkgs.writeShellScript "tabletop-kiosk-start" ''
        # Give cage time to finish binding its output before connecting.
        sleep ${toString cfg.clientStartDelaySeconds}
        exec ${pkgs.chromium}/bin/chromium ${lib.concatStringsSep " " chromiumFlags} ${
          lib.concatMapStringsSep " " lib.escapeShellArg ([ cfg.url ] ++ cfg.diagnosticTabs)
        }
      ''}";
      environment = {
        # NOTE: WLR_DRM_NO_ATOMIC was tried here and made things strictly
        # worse. Every cold boot before it was set came up at 3840x2160 @ 60;
        # every boot after it failed. The legacy KMS path appears to stall
        # cage's event loop on this driver, and a compositor that stops reading
        # its Wayland socket is exactly what wedges the browser — see below.
        # Do not re-add it without testing several cold boots.

        # Chromium checks this before deciding it can use Wayland at all.
        XDG_SESSION_TYPE = "wayland";
        # Ozone/Wayland occasionally probes for a GTK theme; a missing one
        # produces a slow start and a console full of warnings.
        GTK_THEME = "Adwaita:dark";
      };
    };

    # Nothing to look at while the browser starts is better than a wall of
    # kernel messages on a device with no keyboard.
    boot.plymouth.enable = lib.mkDefault true;
    boot.kernelParams = [
      "quiet"
      "loglevel=3"
    ];

    # Wait for a display to exist before starting the compositor.
    #
    # The two supported cables appear at very different times. HDMI is present
    # from early boot. DisplayPort over USB-C is not: the port must complete USB
    # PD negotiation and enter DP Alt Mode first, which lands around 15-20s on
    # this board — comfortably after the compositor would otherwise have
    # started. A compositor that starts with no outputs has nothing to bind and
    # leaves the boot console on the panel.
    systemd.services.tabletop-wait-display = {
      description = "Wait for a connected display before starting the kiosk";
      before = [ "cage-tty1.service" ];
      wantedBy = [ "graphical.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Exits 0 on timeout rather than failing: a deliberately headless boot
        # should still reach a usable, SSH-able system.
        ExecStart = lib.getExe (
          pkgs.writeShellApplication {
            name = "tabletop-wait-display";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              # "connected" is not the same as "usable", and the difference is
              # the whole bug.
              #
              # DisplayPort reads EDID and trains the link over AUX, which on
              # the USB-C SBU pins of this board fails often on a cold boot:
              #
              #   dw-dp fde50000.dp: timeout waiting for AUX reply
              #
              # When that happens the connector still reports "connected" while
              # having no EDID at all and offering only the kernel's fallback
              # mode list — 640x480, 1024x768, 800x600, with no 3840x2160
              # anywhere. Releasing the compositor on "connected" alone starts
              # it against that junk, every modeset is refused with ENOTSUPP,
              # and the browser then waits forever for a surface that is never
              # configured. Black panel, everything reporting healthy.
              #
              # A non-empty EDID is the honest readiness signal: it can only be
              # read if AUX is working. HDMI reads EDID over I2C DDC and passes
              # this on the first attempt, so it costs nothing there.
              usable_display() {
                for s in /sys/class/drm/card*-*/status; do
                  d=$(dirname "$s")
                  [ "$(cat "$s" 2>/dev/null)" = "connected" ] || continue
                  if [ "$(wc -c < "$d/edid" 2>/dev/null || echo 0)" -gt 0 ]; then
                    basename "$d"
                    return 0
                  fi
                done
                return 1
              }

              deadline=$(( $(date +%s) + ${toString cfg.displayTimeoutSeconds} ))
              poked=0
              while [ "$(date +%s)" -lt "$deadline" ]; do
                if out=$(usable_display); then
                  echo "display ready: $out (EDID readable, $poked re-probes)"
                  exit 0
                fi

                # The kernel does not retry a failed EDID read on its own — it
                # gives up and keeps serving the fallback modes indefinitely.
                # Forcing a re-probe does retry it, and does recover: observed
                # going 0 bytes -> 256 bytes with 3840x2160 appearing, though
                # not on every attempt, so this keeps asking.
                for s in /sys/class/drm/card*-*/status; do
                  if [ "$(cat "$s" 2>/dev/null)" = "connected" ]; then
                    echo detect > "$s" 2>/dev/null || true
                  fi
                done
                poked=$((poked + 1))
                sleep 3
              done

              echo "no usable display after ${toString cfg.displayTimeoutSeconds}s; starting anyway" >&2
            '';
          }
        );
      };
    };

    # Recover from a compositor that starts without ever acquiring an output.
    #
    # Roughly two cold boots in three, cage comes up and never binds a scanout
    # buffer: the service is active, it holds DRM fds, it spins at ~33% CPU
    # indefinitely, and [fbcon] keeps the framebuffer while Chromium sits at
    # four processes waiting for a surface that never maps. Every service-level
    # check calls this healthy. The panel is black.
    #
    # It is not a timing race, which is what makes a longer pre-start delay the
    # wrong fix: across three cold boots the compositor started at 18.1s, 18.5s
    # and 18.6s, and the *successful* one was the middle. Waiting longer just
    # moves all three.
    #
    # Restarting cage fixes it every time, so this restarts it. That is a
    # supervisor, not a diagnosis — the underlying wlroots/DRM race is still
    # unexplained, and WLR_DRM_NO_ATOMIC is the next thing to try. But a kiosk
    # that recovers itself in 25 seconds beats a correct explanation nobody is
    # present to act on.
    systemd.services.tabletop-kiosk-watchdog = {
      description = "Restart the kiosk if the compositor came up with no output";
      # Deliberately NOT ordered After cage-tty1. A unit ordered after the
      # service it restarts deadlocks against its own ordering: the restart job
      # cannot run while the dependent unit is still active, so `systemctl
      # restart` blocks. Measured — the first two attempts landed 115s apart
      # rather than the 25s this loop sleeps, and neither took effect. The
      # sleep below is what sequences this after cage, not an ordering edge.
      #
      # It IS ordered after the display gate, which is a different unit and so
      # creates no cycle. Without that it ran before DisplayPort finished
      # alt-mode negotiation, found no connected output, and exited with
      # "nothing to supervise" on every single boot.
      after = [ "tabletop-wait-display.service" ];
      wantedBy = [ "graphical.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe (
          pkgs.writeShellApplication {
            name = "tabletop-kiosk-watchdog";
            runtimeInputs = with pkgs; [
              coreutils
              gnugrep
              procps
              systemd
            ];
            text = ''
              # The wedge signature is precise: the browser process spins, then
              # sits with only its three zygotes — four processes, no renderer
              # and no GPU process — so it never maps a surface and the
              # compositor has nothing to scan out. A healthy tree has renderers.
              #
              # Deliberately not the DRM framebuffer via debugfs, which was the
              # first attempt: /sys/kernel/debug is not reliably readable this
              # early in boot, and the check silently degraded to "not
              # supervising" on every boot while appearing to work. A watchdog
              # whose detection can fail open is worse than none, because it
              # reports success either way.
              kiosk_is_rendering() {
                # Anchored on chromium: a bare "--type=renderer" pattern also
                # matches any shell whose own command line mentions it, which
                # is an easy way to get a watchdog that always sees health.
                pgrep -f -- "chromium.*--type=renderer" >/dev/null 2>&1
              }

              display_connected() {
                for s in /sys/class/drm/card*-*/status; do
                  if [ "$(cat "$s" 2>/dev/null)" = "connected" ]; then
                    return 0
                  fi
                done
                return 1
              }

              # A deliberately headless boot is not a fault.
              if ! display_connected; then
                echo "no display attached; nothing to supervise"
                exit 0
              fi

              # Twelve attempts at 15s, about three minutes.
              #
              # Tuned from measurement, not taste. A healthy cold boot reaches
              # renderers within roughly 15-20 seconds, so a 15s check risks
              # very little; and a wedged instance never recovers on its own,
              # so every second spent waiting on one is wasted. More attempts
              # therefore beat longer ones: across cold boots the successes
              # needed 0 and 5 restarts respectively, and the one failure had
              # exhausted 8.
              for attempt in $(seq 1 12); do
                sleep 15
                if kiosk_is_rendering; then
                  echo "kiosk is rendering (after $((attempt - 1)) restarts)"
                  exit 0
                fi
                echo "kiosk has no renderer; restarting cage (attempt $attempt/12)" >&2

                # Deliberately does NOT force a re-probe here. Poking a
                # connector whose AUX is dead makes things worse, not better:
                # eight forced re-probes in a row took DP-1 from "connected
                # with no EDID" to "disconnected" outright. The gate before
                # startup pokes a bounded number of times to recover a link
                # that is merely slow; once the compositor is running, a link
                # that will not train is a hardware problem and hammering it
                # only removes the output entirely.
                sleep 2
                # --no-block: do not wait on the job. Waiting is what made the
                # earlier version take 90s per attempt and recover nothing.
                systemctl restart --no-block cage-tty1 || true
              done

              echo "still no renderer after 12 restarts; leaving it alone" >&2
            '';
          }
        );
      };
    };

    # The kiosk is useless without a network, so do not present a login prompt
    # until one exists — otherwise the browser races DHCP and shows an error
    # page that nobody is present to dismiss.
    systemd.services.cage-tty1 = {
      after = [
        "network-online.target"
        "tabletop-wait-display.service"
      ];
      wants = [
        "network-online.target"
        "tabletop-wait-display.service"
      ];
      serviceConfig = {
        Restart = "always";
        # mkDefault so modules/status.nix can stretch the gap: that pause is
        # when the on-console status notice is readable.
        RestartSec = lib.mkDefault 5;

        # cage does not exit on SIGTERM. Without this it sits out systemd's
        # default 90s stop timeout before being killed, which makes every
        # restart effectively a no-op on any shorter timescale: the watchdog's
        # three restart attempts, 25s apart, all queued behind a single stop
        # that had not finished, and `journalctl` recorded exactly one
        # "Started cage-tty1" for the whole boot. It is also why
        # `nixos-rebuild switch` leaves this unit failed with exit 4.
        #
        # Five seconds of grace, then SIGKILL. There is nothing to flush: the
        # compositor holds no state worth saving, and the browser is launched
        # with crash-restore suppressed.
        TimeoutStopSec = 5;

        # cage's own output would otherwise go to tty1, invisible over SSH.
        # Worth keeping: this is where wlroots reports modeset failures, and
        # journald files those lines under "cage[PID]" rather than under this
        # unit, so look for them with `journalctl -b | grep "cage\["` — not
        # `journalctl -u cage-tty1`, which shows nothing.
        StandardOutput = "journal";
        StandardError = "journal";

        # Clear Chromium's process singleton before every start.
        #
        # This is the wedge. Chromium writes SingletonLock, SingletonSocket and
        # SingletonCookie into its profile, and removes them only on a clean
        # exit. The socket they point at lives under /tmp, which is tmpfs and is
        # wiped on every boot; the profile is on disk and is not. So after any
        # unclean stop — a power cycle, which is how a tabletop is switched off
        # — the next boot starts a browser that finds a lock naming a dead PID,
        # tries to hand off to a singleton whose socket no longer exists, and
        # spins. Observed exactly: the browser process burning ~70% CPU with
        # only its three zygotes, no GPU process, no renderer, and therefore no
        # surface for the compositor to scan out. The panel stays black while
        # every service reports active.
        #
        # That also explains why it was intermittent rather than constant: it
        # depends entirely on how the previous session ended.
        ExecStartPre = [
          "-${pkgs.writeShellScript "clear-chromium-singleton" ''
            rm -f "/home/${cfg.user}/.config/chromium/SingletonLock" \
                  "/home/${cfg.user}/.config/chromium/SingletonSocket" \
                  "/home/${cfg.user}/.config/chromium/SingletonCookie"
          ''}"
        ];
      };
    };

    hardware.graphics.enable = true;

    # grim captures the compositor's framebuffer, which is the only way to tell
    # "the kiosk is broken" apart from "the panel is not showing what the kiosk
    # drew". Part of the system closure rather than fetched on demand,
    # because the moment it is needed is exactly the moment the device's
    # network and display are both in question. See scripts/screenshot.sh.
    environment.systemPackages = [ pkgs.grim ];

    nixpkgs.config.allowUnfree = true;
  };
}
