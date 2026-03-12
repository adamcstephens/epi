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
          { pkgs, ... }:
          let
            ocamlPackages = pkgs.ocaml-ng.ocamlPackages_latest;
          in
          {
            devShells.default = pkgs.mkShell {
              packages = [
                pkgs.xorriso
                pkgs.cloud-hypervisor
                pkgs.gptfdisk
                pkgs.jq
                pkgs.just
                pkgs.nixfmt
                pkgs.qemu-utils
                pkgs.passt
                pkgs.virtiofsd
                pkgs.openssh

                pkgs.cargo
                pkgs.rustc
              ]
              ++ (with ocamlPackages; [
                dune_3
                ocaml
                ocamlformat
                ocaml-lsp
                odig
                utop
              ]);
            };

            packages = rec {
              default = epi;

              epi = pkgs.callPackage ./nix/wrapper.nix {
                inherit epi-unwrapped;
              };

              epi-unwrapped = pkgs.pkgsMusl.callPackage ./nix/package.nix {
                ocamlPackages = pkgs.pkgsMusl.ocaml-ng.ocamlPackages_latest;
                inherit (pkgs)
                  curl
                  fetchurl
                  makeSetupHook
                  writeText
                  ;
              };
            };
          };
      }
    );
}
