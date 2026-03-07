{
  lib,
  ocamlPackages,
}:

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
        ../epi.opam
        ../lib
      ];
    };

  # buildInputs = with ocamlPackages; [
  #   ppxlib
  #   ppx_subliner
  # ];
}
