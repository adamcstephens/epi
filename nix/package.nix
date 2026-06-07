{
  lib,
  rcodesign,
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

  nativeBuildInputs = lib.optionals stdenv.isDarwin [
    rcodesign
  ];

  nativeCheckInputs = lib.optionals stdenv.isLinux [
    systemdMinimal
  ];

  # Virtualization.framework refuses to start a VM unless the calling binary
  # carries the com.apple.security.virtualization entitlement, so re-sign on
  # top of stdenv's plain ad-hoc signature. Apple's codesign is unavailable in
  # the build sandbox; rcodesign produces an equivalent ad-hoc signature with
  # entitlements embedded. Ad-hoc is sufficient for local use — Developer ID
  # signing for distribution is intentionally out of scope.
  postFixup = lib.optionalString stdenv.isDarwin ''
    rcodesign sign --entitlements-xml-path ${./epi.entitlements} $out/bin/epi
  '';

  meta.mainProgram = "epi";
}
