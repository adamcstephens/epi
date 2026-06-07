{
  lib,
  rustPlatform,
  stdenv,
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

  nativeCheckInputs = lib.optionals stdenv.isLinux [
    systemdMinimal
  ];

  meta.mainProgram = "epi";
}
