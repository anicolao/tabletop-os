{
  description = "tabletop-os — a browser kiosk OS for large touchscreen tabletop gaming";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Raspberry Pi 5 support. Not optional: nixpkgs has no linuxPackages_rpi5
    # (only rpi0-rpi4), and nixos-hardware's raspberry-pi/5 is a stub with no
    # display module. This provides the vendor kernel, matched firmware and
    # device trees, and full-KMS display configuration.
    # Pinned to our nixpkgs. Their binary cache does not have this kernel
    # either way (checked — the cache is healthy, it just lacks this build), so
    # the choice is purely about closure sharing. Measured: following our
    # nixpkgs needs 171 derivations and 4.8 GB, letting it use its own needs
    # 368 and 6.7 GB, because a second nixpkgs shares nothing with what is
    # already in the store from the Orange Pi — including Chromium.
    nixos-raspberrypi = {
      url = "github:nvmd/nixos-raspberrypi/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # The Raspberry Pi vendor kernel is not in cache.nixos.org. Without this
  # substituter, building the rpi5 image compiles a kernel from source.
  # It is the upstream project's own cache — read it as a trust decision, and
  # drop this block if you would rather compile.
  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  outputs =
    { self, nixpkgs, nixos-raspberrypi }:
    let
      # Every target board is 64-bit ARM. The *build* host may be aarch64-darwin
      # (a laptop driving a linux-builder VM) or aarch64-linux (a native builder),
      # which is why the emulator is exposed for both below.
      target = "aarch64-linux";

      lib = nixpkgs.lib;

      # Everything above the DRM device. The boards share this entirely; they
      # share nothing below it, which is why hardware lives in hosts/.
      sharedModules = [
        ./modules/base.nix
        ./modules/kiosk.nix
        ./modules/touchscreen.nix
        ./modules/status.nix
        ./modules/wifi.nix
      ];

      mkSystem =
        extraModules:
        nixpkgs.lib.nixosSystem {
          system = target;
          modules = sharedModules ++ extraModules;
        };

      # The emulator's runner script is built for whichever machine will *run*
      # qemu, not for the guest. `virtualisation.host.pkgs` is what makes a
      # macOS-native runner possible.
      mkVm =
        hostSystem:
        nixpkgs.lib.nixosSystem {
          system = target;
          specialArgs = { hostPkgs = nixpkgs.legacyPackages.${hostSystem}; };
          modules = sharedModules ++ [ ./hosts/vm.nix ];
        };

      # An SD image is a file, not a program, so `nix run .#image` would
      # otherwise die with a bare "No such file or directory". Since `nix run`
      # prefers apps.* over packages.*, this intercepts it and does the useful
      # thing: build the image, then say where it is and how to write it.
      imageApp =
        hostSystem:
        let
          hp = nixpkgs.legacyPackages.${hostSystem};
          script = hp.writeShellScriptBin "tabletop-image" ''
            set -eu
            img=$(echo ${image}/sd-image/*.img)
            echo "SD image for the Orange Pi 5 Plus:"
            echo
            echo "    $img"
            echo "    $(${hp.coreutils}/bin/du -h "$img" | ${hp.coreutils}/bin/cut -f1)"
            echo
            echo "To get a 'result' symlink in the current directory instead:"
            echo "    nix build .#image"
            echo
            echo "To write it to a card (see docs/FLASHING.md for the full procedure):"
            echo "    diskutil list                      # identify the card"
            echo "    diskutil unmountDisk /dev/diskN"
            echo "    sudo dd if=$img of=/dev/rdiskN bs=4m status=progress"
            echo
            echo "Use rdiskN, not diskN — the raw device is far faster."
          '';
        in
        {
          type = "app";
          program = "${script}/bin/tabletop-image";
          meta.description = "Build the SD image and print how to flash it";
        };

      # Wrapped rather than pointed at directly, so display resolution is a
      # runtime flag instead of something you have to rebuild to change.
      vmApp =
        hostSystem:
        let
          hp = nixpkgs.legacyPackages.${hostSystem};
          cfg = mkVm hostSystem;
          runner = "${cfg.config.system.build.vm}/bin/run-${cfg.config.system.name}-vm";
          script = hp.writeShellApplication {
            name = "tabletop-vm";
            runtimeInputs = [ hp.gnugrep ];
            text = ''
              TABLETOP_VM_RUNNER=${lib.escapeShellArg runner}
              TABLETOP_VM_DEFAULT_RES=${
                lib.escapeShellArg "${toString cfg.config.tabletop.vm.width}x${toString cfg.config.tabletop.vm.height}"
              }
            ''
            + builtins.readFile ./scripts/run-vm.sh;
          };
        in
        {
          type = "app";
          program = "${script}/bin/tabletop-vm";
          meta.description = "Boot the tabletop kiosk in QEMU";
        };

      # Capture what the board is rendering. See scripts/screenshot.sh for why
      # this earns its place.
      screenshotApp =
        hostSystem:
        let
          hp = nixpkgs.legacyPackages.${hostSystem};
          script = hp.writeShellApplication {
            name = "tabletop-screenshot";
            runtimeInputs = with hp; [
              openssh
              imagemagick
              gnugrep
              gawk
            ];
            text = ''
              TABLETOP_HOST=admin@tabletop-opi5plus
            ''
            + builtins.readFile ./scripts/screenshot.sh;
          };
        in
        {
          type = "app";
          program = "${script}/bin/tabletop-screenshot";
          meta.description = "Screenshot what the kiosk is actually rendering";
        };

      burnApp =
        hostSystem: boardName: imageDrv:
        let
          hp = nixpkgs.legacyPackages.${hostSystem};
          script = hp.writeShellApplication {
            name = "tabletop-burn-${boardName}";
            runtimeInputs = with hp; [
              coreutils
              gnugrep
              gnused
              gawk
            ];
            text = ''
              TABLETOP_BOARD=${boardName}
              TABLETOP_IMAGE_DIR=${imageDrv}
              # Pinned to store paths rather than left to PATH: dd runs under
              # sudo, and GNU and BSD dd take incompatible arguments.
              TABLETOP_DD=${lib.getBin hp.coreutils}/bin/dd
              TABLETOP_ZSTD=${lib.getBin hp.zstd}/bin/zstd
            ''
            + builtins.readFile ./scripts/burn.sh;
          };
        in
        {
          type = "app";
          program = "${script}/bin/tabletop-burn-${boardName}";
          meta.description = "Write the SD image to a card, with safety checks";
        };

      opi5plus = mkSystem [ ./hosts/opi5plus.nix ];

      # The Pi needs the flake's own nixosSystem wrapper (it layers in the
      # vendor overlays), and its image comes from the sdimage-installer
      # module rather than nixpkgs' sd-image.nix — which their base module
      # explicitly disables. Mirrors nixos-raspberrypi's own installerImages.
      rpi5 = nixos-raspberrypi.lib.nixosInstaller {
        specialArgs = { inherit nixos-raspberrypi; };
        modules = [
          nixos-raspberrypi.inputs.nixos-images.nixosModules.sdimage-installer
          (
            { config, lib, modulesPath, ... }:
            {
              disabledModules = [
                (modulesPath + "/installer/sd-card/sd-image-aarch64-installer.nix")
              ];
              image.baseName = lib.mkOverride 40 "tabletop-os-rpi5";
              networking.wireless.enable = lib.mkForce false;
            }
          )
          {
            # Undo two of nixos-raspberrypi's overlays. It replaces ffmpeg and
            # libcamera with Raspberry Pi forks (ffmpeg-headless-rpi,
            # libcamera-rpi), which a kiosk needs for nothing — there is no
            # camera, and Chromium decodes video through VAAPI rather than
            # ffmpeg. But they propagate up through pipewire and gtk4 into
            # Chromium, changing its derivation hash and forcing a from-source
            # Chromium build measured in hours. Restoring the stock packages
            # makes Chromium identical to the Orange Pi's, which is already
            # built.
            nixpkgs.overlays = [
              (final: prev: {
                inherit (nixpkgs.legacyPackages.${target})
                  ffmpeg
                  ffmpeg-headless
                  libcamera
                  ;
              })
            ];
          }
          ./hosts/rpi5.nix
        ] ++ sharedModules;
      };

      image = opi5plus.config.system.build.sdImage;
      # The kiosk system itself, without the SD card wrapper. Useful for
      # inspecting the closure without building a multi-gigabyte image.
      toplevel = opi5plus.config.system.build.toplevel;

      # `image` and `toplevel` are aarch64-linux derivations, but they are
      # almost always built *from* the laptop, where `nix build .#image`
      # resolves against packages.aarch64-darwin. Exposing them under both
      # systems means the documented command works from either machine; Nix
      # dispatches the actual build to the aarch64-linux builder regardless.
      rpi5Image = rpi5.config.system.build.sdImage;

      commonPackages = {
        inherit image toplevel rpi5Image;
        default = image;
      };
    in
    {
      nixosConfigurations = {
        inherit opi5plus rpi5;
        vm = mkVm target;
      };

      packages.${target} = commonPackages // {
        vm = (mkVm target).config.system.build.vm;
      };

      packages.aarch64-darwin = commonPackages // {
        vm = (mkVm "aarch64-darwin").config.system.build.vm;
      };

      # The runner is named run-${system.name}-vm, so derive the path from the
      # configuration rather than hardcoding it — otherwise renaming the host
      # silently breaks `nix run .#vm`.
      apps.${target} = {
        vm = vmApp target;
        image = imageApp target;
        screenshot = screenshotApp target;
        burn = burnApp target "opi5plus" image;
        burn-rpi5 = burnApp target "rpi5" rpi5Image;
      };
      apps.aarch64-darwin = {
        vm = vmApp "aarch64-darwin";
        image = imageApp "aarch64-darwin";
        screenshot = screenshotApp "aarch64-darwin";
        burn = burnApp "aarch64-darwin" "opi5plus" image;
        burn-rpi5 = burnApp "aarch64-darwin" "rpi5" rpi5Image;
      };

      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-rfc-style;
      formatter.${target} = nixpkgs.legacyPackages.${target}.nixfmt-rfc-style;
    };
}
