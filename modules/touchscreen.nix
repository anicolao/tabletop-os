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
    #
    # The third rule is about the mouse cursor rather than touch, and lives here
    # because this is where input policy is: a tabletop with nothing plugged in
    # was drawing a pointer in the middle of the screen.
    #
    # The cause is not the touchscreen, which libinput classifies correctly as
    # `touch`. It is the SoC's remote-control receivers — HDMI CEC on each
    # connector, the HDMI receiver, and the IR receiver. Each registers an
    # rc-core input device carrying button codes, and udev's input_id builtin
    # tags them ID_INPUT_POINTINGSTICK=1. libinput then reports `pointer`
    # capability, the seat gains a pointer, and cage draws a cursor. Measured on
    # the Orange Pi: four such devices, all `keyboard pointer`, with no mouse
    # attached.
    #
    # Matched on the rc-core device path rather than on board-specific names
    # like fde80000.hdmi, because every one of them lives under .../rc/rcN/ and
    # the Raspberry Pi has CEC too.
    #
    # LIBINPUT_IGNORE_DEVICE rather than clearing ID_INPUT_POINTINGSTICK, which
    # was tried first and is not enough: libinput classifies from the evdev bits
    # as well as the udev hints, and these devices really do advertise EV_REL
    # (EV=100017). Clearing the tag left all four still reporting `pointer`.
    # Ignoring them outright is safe here — they are CEC and IR receivers, and
    # nothing in the kiosk listens to a TV remote.
    #
    # The fourth rule covers the other half of "a pointer only when a mouse is
    # plugged in". Many keyboards expose a second HID interface carrying media
    # keys, and it advertises relative axes, which libinput reads as pointer
    # capability. Measured on the keyboard attached to this board: the typing
    # interface has capabilities/rel = 0, while the second has 1040 — REL_HWHEEL
    # and its hi-res twin, and no REL_X or REL_Y at all. It cannot move a
    # cursor; it only scrolls. Yet its presence alone put a pointer on a
    # tabletop that has none.
    #
    # The discriminator is therefore: a keyboard, carrying relative axes, that
    # udev did not tag as a mouse. udev's input_id only sets ID_INPUT_MOUSE for
    # devices with REL_X and REL_Y plus buttons, so a real mouse never matches
    # this and still gets its cursor. The typing interface has no relative axes
    # and is untouched.
    services.udev.extraRules = ''
      SUBSYSTEM=="input", KERNEL=="event*", GROUP="input", MODE="0660"
      SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHSCREEN}=="1", GROUP="input", MODE="0660", TAG+="uaccess"
      SUBSYSTEM=="input", KERNEL=="event*", DEVPATH=="*/rc/rc[0-9]*", ENV{LIBINPUT_IGNORE_DEVICE}="1"
      SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEYBOARD}=="1", ENV{ID_INPUT_MOUSE}!="1", ATTRS{capabilities/rel}!="0", ENV{LIBINPUT_IGNORE_DEVICE}="1"
    '';
  };
}
