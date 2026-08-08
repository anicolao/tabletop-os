{
  description = "tabletop-os — a browser kiosk OS for large touchscreen tabletop gaming";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Every target board is 64-bit ARM. The *build* host may be aarch64-darwin
      # (a laptop driving a linux-builder VM) or aarch64-linux (a native builder),
      # which is why the emulator is exposed for both below.
      target = "aarch64-linux";

      # Everything above the DRM device. The boards share this entirely; they
      # share nothing below it, which is why hardware lives in hosts/.
      sharedModules = [
        ./modules/base.nix
        ./modules/kiosk.nix
        ./modules/touchscreen.nix
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

      vmApp =
        hostSystem:
        let
          cfg = mkVm hostSystem;
        in
        {
          type = "app";
          program = "${cfg.config.system.build.vm}/bin/run-${cfg.config.system.name}-vm";
          meta.description = "Boot the tabletop kiosk in QEMU";
        };

      opi5plus = mkSystem [ ./hosts/opi5plus.nix ];

      image = opi5plus.config.system.build.sdImage;
      # The kiosk system itself, without the SD card wrapper. Useful for
      # inspecting the closure without building a multi-gigabyte image.
      toplevel = opi5plus.config.system.build.toplevel;

      # `image` and `toplevel` are aarch64-linux derivations, but they are
      # almost always built *from* the laptop, where `nix build .#image`
      # resolves against packages.aarch64-darwin. Exposing them under both
      # systems means the documented command works from either machine; Nix
      # dispatches the actual build to the aarch64-linux builder regardless.
      commonPackages = {
        inherit image toplevel;
        default = image;
      };
    in
    {
      nixosConfigurations = {
        inherit opi5plus;
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
      };
      apps.aarch64-darwin = {
        vm = vmApp "aarch64-darwin";
        image = imageApp "aarch64-darwin";
      };

      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-rfc-style;
      formatter.${target} = nixpkgs.legacyPackages.${target}.nixfmt-rfc-style;
    };
}
