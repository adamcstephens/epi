{
  lib,
  rustPlatform,
  systemdMinimal,
}:

rustPlatform.buildRustPackage {
  pname = "epi";
  version = (lib.importTOML ../Cargo.toml).workspace.package.version;

  src =
    with lib.fileset;
    toSource {
      root = ../.;
      fileset = unions [
        ../Cargo.toml
        ../Cargo.lock
        ../cmd
        ../core
        ../backends
      ];
    };

  cargoLock.lockFile = ../Cargo.lock;

  nativeCheckInputs = [
    systemdMinimal
  ];

  meta.mainProgram = "epi";
}
