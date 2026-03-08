{
  lib,
  curl,
  fetchurl,
  makeSetupHook,
  writeText,
  ocamlPackages,
}:

let
  duneLockHook = import ./dune-lock.nix {
    inherit
      lib
      fetchurl
      makeSetupHook
      writeText
      ;
    inherit (ocamlPackages) ocaml;
    lockDir = ../dune.lock;
  };
in

ocamlPackages.buildDunePackage {
  pname = "epi";
  version = "0.1.0";

  env.BUILD_STATIC = "1";

  src =
    with lib.fileset;
    toSource {
      root = ../.;
      fileset = unions [
        ../bin
        ../dune-project
        ../dune-workspace
        ../dune.lock
        ../epi.opam
        ../lib
      ];
    };

  nativeBuildInputs = [
    curl
    duneLockHook
  ];

  buildPhase = ''
    runHook preBuild
    dune build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    dune install --prefix $out
    runHook postInstall
  '';

  meta.mainProgram = "epi";
}
