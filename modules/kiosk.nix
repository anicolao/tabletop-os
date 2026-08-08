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

    # Native GLES through ANGLE. This is the path that makes WebGL
    # hardware-accelerated on Mali and VideoCore alike. (The older
    # `--use-gl=egl` spelling is deprecated and now ignored.)
    "--use-angle=gles-egl"

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

    extraChromiumFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--use-angle=vulkan" ];
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

    # The kiosk is useless without a network, so do not present a login prompt
    # until one exists — otherwise the browser races DHCP and shows an error
    # page that nobody is present to dismiss.
    systemd.services.cage-tty1 = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;
      };
    };

    hardware.graphics.enable = true;

    nixpkgs.config.allowUnfree = true;
  };
}
