# Touch input and display-power behaviour.
#
# The screen is the only input device. Everything here exists so that a person
# walking up to a table finds it awake and responding to fingers.
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

    # Never blank. DPMS on a table full of game pieces is a support call.
    services.cage.environment = {
      WLR_DRM_NO_ATOMIC = lib.mkDefault "0";
    };

    # A visible mouse pointer on a touch-only device looks broken.
    environment.etc."xdg/tabletop-cursor".text = "hidden";

    # Multi-touch devices need to be readable by the kiosk user. The `input`
    # group grants that; this makes sure hotplugged panels land in it too.
    services.udev.extraRules = ''
      SUBSYSTEM=="input", KERNEL=="event*", GROUP="input", MODE="0660"
      SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHSCREEN}=="1", GROUP="input", MODE="0660", TAG+="uaccess"
    '';
  };
}
