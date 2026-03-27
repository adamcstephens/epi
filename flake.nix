{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable-small";

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { ... }:
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ];

        flake.nixosConfigurations = {
          manual-test = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              ./nix/nixos/epi.nix
              (
                { pkgs, ... }:
                {
                  system.stateVersion = "25.11";

                  epi.enable = true;
                  epi.hooks.guest-init."00-hello.sh" = pkgs.writeShellScript "hello" ''
                    echo "epi-hook: guest-init hello from nix config"
                  '';
                  epi.hooks.post-launch."00-marker.sh" = pkgs.writeShellScript "post-launch-marker" ''
                    touch "$EPI_STATE_DIR/$EPI_INSTANCE/nix-post-launch-ran"
                  '';
                  epi.hooks.pre-stop."00-marker.sh" = pkgs.writeShellScript "pre-stop-marker" ''
                    touch "$EPI_STATE_DIR/$EPI_INSTANCE/nix-pre-stop-ran"
                  '';
                  nix.settings = {
                    extra-experimental-features = "nix-command flakes";
                  };
                }
              )
            ];
          };

        };

        flake.nixosModules.epi = ./nix/nixos/epi.nix;

        perSystem =
          { pkgs, self', ... }:
          {
            devShells.default = pkgs.mkShell {
              packages = [
                pkgs.beans
                pkgs.just

                self'.packages.cloud-hypervisor
                pkgs.jq
                pkgs.nixfmt
                pkgs.openssh
                pkgs.passt
                pkgs.qemu-utils
                pkgs.rsync
                pkgs.virtiofsd
                pkgs.xorriso

                pkgs.cargo
                pkgs.clippy
                pkgs.rustc
                pkgs.rust-analyzer
                pkgs.rustfmt
              ];
            };

            packages = rec {
              default = epi;

              epi = pkgs.callPackage ./nix/wrapper.nix {
                inherit cloud-hypervisor epi-unwrapped;
              };

              epi-unwrapped = pkgs.callPackage ./nix/package.nix { };

              cloud-hypervisor = pkgs.cloud-hypervisor.overrideAttrs (old: {
                patches = (old.patches or [ ]) ++ [
                  (pkgs.fetchpatch {
                    url = "https://github.com/cloud-hypervisor/cloud-hypervisor/commit/57e766bdbbfcdf1f36f696fc735fbebbea97f5ca.patch";
                    hash = "sha256-hmLE/QT7LfPuaxqspbK7EvO/4VYNHx0SMt6PnAZ2L6I=";
                  })
                ];
              });
            };
          };
      }
    );
}
