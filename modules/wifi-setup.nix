# A local WiFi setup portal for a device with no keyboard and no network.
#
# The bootstrap problem this solves is real and was hit the first time a fresh
# card was flashed: burning an image wipes wifi.conf, so the board comes up with
# no network, and the kiosk cannot load its launcher because the launcher lives
# on the internet. The screen sits there looking broken, and the only recoveries
# are a serial console or moving the card back to a laptop — neither of which is
# reasonable for an appliance somebody else switches on.
#
# So when there is no connectivity the kiosk shows a local page instead: pick a
# network, tap in the password on an on-screen keyboard, and it writes the same
# wifi.conf the rest of this repo already reads.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.tabletop.wifi;
  portal = cfg.setupPortal;
in
{
  options.tabletop.wifi.setupPortal = {
    enable = lib.mkEnableOption ''
      a local WiFi setup page, shown on the kiosk when there is no network.

      Defaults on wherever tabletop.wifi is enabled, because the situation it
      exists for — a freshly flashed card with no credentials — is the normal
      state of a new device rather than an edge case
    '';

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = ''
        Loopback port for the setup portal. Not reachable off the device: the
        server binds 127.0.0.1 explicitly, and the firewall is not involved
        because nothing is ever exposed.
      '';
    };
  };

  config = lib.mkMerge [
    { tabletop.wifi.setupPortal.enable = lib.mkDefault cfg.enable; }

    (lib.mkIf (cfg.enable && portal.enable) {
      # Shown only when there is no connectivity — see modules/kiosk.nix, which
      # picks this over the launcher when there is no default route.
      tabletop.kiosk.fallbackUrl = "http://127.0.0.1:${toString portal.port}/";

      systemd.services.tabletop-wifi-portal = {
        description = "Local WiFi setup portal for the kiosk";
        after = [ "NetworkManager.service" ];
        wants = [ "NetworkManager.service" ];
        wantedBy = [ "multi-user.target" ];

        environment = {
          TABLETOP_WIFI_FILE = cfg.credentialsFile;
          TABLETOP_PORTAL_HTML = ../web/wifi-setup.html;
          TABLETOP_PORTAL_PORT = toString portal.port;
          TABLETOP_LAUNCHER_URL = config.tabletop.kiosk.url;
        };

        # Runs as root, and that is the uncomfortable part of this design, so it
        # is worth being explicit about why and what bounds it.
        #
        # It has to write cfg.credentialsFile on the boot partition and restart
        # two units. The alternatives — a setuid helper, or polkit rules for
        # systemctl and a file write — are more moving parts for the same
        # authority on a single-purpose appliance.
        #
        # What actually bounds it: the socket is bound to 127.0.0.1 so nothing
        # off-device can reach it; every subprocess call passes an argument list
        # rather than a shell string; and ssid/psk are length- and
        # character-validated before they reach a file or a command line. The
        # hardening below removes everything it does not need.
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.python3Minimal}/bin/python3 ${../scripts/wifi-portal.py}";
          Restart = "on-failure";
          RestartSec = 5;

          # It needs to write one file on /boot/firmware and talk to systemd and
          # NetworkManager. It needs nothing else.
          ProtectSystem = "strict";
          ReadWritePaths = [ (builtins.dirOf cfg.credentialsFile) ];
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
          ];
          RestrictNamespaces = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
        };

        path = with pkgs; [
          networkmanager
          systemd
        ];
      };
    })
  ];
}
