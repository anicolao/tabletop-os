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

    displayTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 45;
      description = ''
        How long to wait for a connected display before starting the kiosk
        anyway.

        Generous on purpose. DisplayPort over USB-C only appears after PD
        negotiation and alt-mode entry, which on this hardware lands somewhere
        around 15-20 seconds. Waiting costs nothing on HDMI, which is present
        from early boot.
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
      # -m last: use one output only.
      #
      # cage's default is "-m extend", which spans every connected output as a
      # single logical surface. With HDMI and DisplayPort both plugged in that
      # produced a picture offset across two panels, and it is also the best
      # candidate for the intermittent startup wedge seen on this board: cage
      # would come up holding no DRM device at all (3 file descriptors, none of
      # them DRM, 216ms of CPU over two and a half minutes, deaf to SIGTERM),
      # while every service-level check reported it healthy. Restarting it
      # always fixed it, which fits outputs still settling during the first
      # start — DisplayPort over USB-C appears late, after PD negotiation.
      #
      # Three consecutive cold boots came up clean with this set, versus the
      # intermittent failure before. Not proof of causation, but the wedge has
      # not recurred.
      #
      # NB "-d" is NOT debug; it means "don't draw client side decorations".
      # Debug logging is "-D".
      extraArguments = [
        "-m"
        "last"
      ];
      # The launcher is listed first so it is the active tab; diagnosticTabs sit
      # behind it and are revealed one Ctrl+W at a time.
      program = "${pkgs.chromium}/bin/chromium ${lib.concatStringsSep " " chromiumFlags} ${
        lib.concatMapStringsSep " " lib.escapeShellArg ([ cfg.url ] ++ cfg.diagnosticTabs)
      }";
      environment = {
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
    # DisplayPort over USB-C appears *late*: the port has to complete USB PD
    # negotiation and enter DP Alt Mode before the connector reports connected.
    # Measured on this board, cage started at 18.6s while that was still in
    # progress, came up with no output, and left the boot console on screen —
    # the kiosk was running and healthy by every service-level check, and the
    # panel showed text. Restarting cage afterwards fixed it every time, which
    # is what identified this as a race rather than a compositor fault.
    #
    # HDMI is present from early boot, so this costs nothing there.
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
              for _ in $(seq 1 ${toString cfg.displayTimeoutSeconds}); do
                for s in /sys/class/drm/card*-*/status; do
                  if [ "$(cat "$s" 2>/dev/null)" = "connected" ]; then
                    echo "display ready: $(basename "$(dirname "$s")")"
                    exit 0
                  fi
                done
                sleep 1
              done
              echo "no display after ${toString cfg.displayTimeoutSeconds}s; starting anyway" >&2
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
      };
    };

    hardware.graphics.enable = true;

    nixpkgs.config.allowUnfree = true;
  };
}
