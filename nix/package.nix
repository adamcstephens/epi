{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "epi";
  version = "0.1.0";

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

  meta.mainProgram = "epi";
}
