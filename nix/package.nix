{
  lib,
  rustPlatform,
  systemdMinimal,
}:

rustPlatform.buildRustPackage {
  pname = "epi";
  version = (lib.importTOML ../Cargo.toml).package.version;

  src =
    with lib.fileset;
    toSource {
      root = ../.;
      fileset = unions [
        ../Cargo.toml
        ../Cargo.lock
        ../src
      ];
    };

  cargoLock.lockFile = ../Cargo.lock;

  nativeCheckInputs = [
    systemdMinimal
  ];

  meta.mainProgram = "epi";
}
