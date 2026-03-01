{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable-small";

    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { config, ... }:
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ];

        flake.nixosConfigurations.manual-test = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./nix/nixos/manual-test.nix
          ];
        };
        flake.manual-test = config.flake.nixosConfigurations.manual-test;

        perSystem =
          { pkgs, ... }:
          let
            ocamlPackages = pkgs.ocamlPackages_latest;
          in
          {
            devShells.default = pkgs.mkShell {
              packages = [
                pkgs.cloud-hypervisor
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

            packages = {
              default = pkgs.pkgsMusl.callPackage ./package.nix {
                inherit ocamlPackages;
              };
            };
          };
      }
    );
}
