# Touch input.
#
# What actually makes touch work is spread across three places, which is worth
# stating because it is easy to assume this file is the whole story:
#
#   1. wlroots links libinput directly, so cage consumes evdev without any X
#      input driver. Nothing here enables that; it is simply how cage works.
#   2. modules/kiosk.nix puts the kiosk user in the `input` group.
#   3. This file supplies libinput's udev quirks database (via
#      services.libinput, whose X11 half is inert under Wayland but whose
#      `services.udev.packages` half is not), the permissions rules below, and
#      output rotation.
#
# The panel on the large table is a RAPT digitizer that presents no HID
# interface at all — an external box runs a vendor binary and re-presents it as
# a normal USB HID device. From this module's point of view that is just an
# ordinary touchscreen. The portable Raspberry Pi table has a real USB HID
# panel, so it needs no such translation.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.tabletop.touchscreen;
in
{
  options.tabletop.touchscreen = {
    enable = lib.mkEnableOption "touchscreen tuning" // {
      default = true;
    };

    rotation = lib.mkOption {
      type = lib.types.enum [
        "normal"
        "90"
        "180"
        "270"
      ];
      default = "normal";
      description = ''
        Panel rotation. A tabletop is often mounted in whatever orientation the
        cabinet allows, and the touch matrix has to be rotated with the output
        or taps land in the wrong place.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    services.libinput = {
      enable = true;
      touchpad.naturalScrolling = false;
    };

    # cage rotates its single output; the touch matrix follows the output
    # transform automatically under wlroots, which is why this is one setting
    # rather than a display transform plus a separate input calibration.
    services.cage.extraArguments = lib.mkIf (cfg.rotation != "normal") [
      "-r"
      cfg.rotation
    ];

    # Multi-touch devices need to be readable by the kiosk user. The `input`
    # group grants that; this makes sure hotplugged panels land in it too.
    services.udev.extraRules = ''
      SUBSYSTEM=="input", KERNEL=="event*", GROUP="input", MODE="0660"
      SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHSCREEN}=="1", GROUP="input", MODE="0660", TAG+="uaccess"
    '';
  };
}
