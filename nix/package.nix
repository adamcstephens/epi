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
    lockDir = ../dune.lock;
    hashOverrides = {
      re = "sha512=cd2cc39f951ca6b7be631bbb5531ed13bc040e629842671bf6fef3911b20ef1653fa9a1f0aa23b094d252cffc9a9efe7ffca69e50d362ab935bc0cc447548124";
      ocamlfind = "sha512=8967986de2ab4ec5993f437b0a4206742adf37aa7a292a3bba0a04438d78539b84d001191e60b2d5bde98a695b38cba2593b7051f7749adbdb964a0df3c4b661";
    };
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

  passthru = { inherit duneLockHook; };

  meta.mainProgram = "epi";
}
