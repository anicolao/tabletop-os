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
    in
    {
      nixosConfigurations = {
        opi5plus = mkSystem [ ./hosts/opi5plus.nix ];
        vm = mkVm target;
      };

      packages.${target} = {
        default = self.nixosConfigurations.opi5plus.config.system.build.sdImage;
        image = self.nixosConfigurations.opi5plus.config.system.build.sdImage;
        # The kiosk system itself, without the SD card wrapper. Useful for
        # inspecting the closure without building a multi-gigabyte image.
        toplevel = self.nixosConfigurations.opi5plus.config.system.build.toplevel;
        vm = (mkVm target).config.system.build.vm;
      };

      packages.aarch64-darwin.vm = (mkVm "aarch64-darwin").config.system.build.vm;

      apps.${target}.vm = {
        type = "app";
        program = "${(mkVm target).config.system.build.vm}/bin/run-tabletop-vm";
      };

      apps.aarch64-darwin.vm = {
        type = "app";
        program = "${(mkVm "aarch64-darwin").config.system.build.vm}/bin/run-tabletop-vm";
      };

      formatter.aarch64-darwin = nixpkgs.legacyPackages.aarch64-darwin.nixfmt-rfc-style;
      formatter.${target} = nixpkgs.legacyPackages.${target}.nixfmt-rfc-style;
    };
}
