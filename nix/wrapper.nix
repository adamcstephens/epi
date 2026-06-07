{
  cloud-hypervisor,
  installShellFiles,
  lib,
  epi-unwrapped,
  makeWrapper,
  passt,
  qemu-utils,
  rsync,
  runCommand,
  stdenv,
  virtiofsd,
  xorriso,
}:
runCommand "epi"
  {
    nativeBuildInputs = [
      installShellFiles
      makeWrapper
    ];
    meta.mainProgram = "epi";
  }
  ''
    mkdir -vp $out/bin/
    makeWrapper ${lib.getExe epi-unwrapped} $out/bin/epi --prefix PATH : ${
      lib.makeBinPath (
        [
          qemu-utils
          rsync
          xorriso
        ]
        ++ lib.optionals stdenv.isLinux [
          cloud-hypervisor
          passt
          virtiofsd
        ]
      )
    }

    installShellCompletion --cmd epi \
      --bash <(COMPLETE=bash $out/bin/epi) \
      --fish <(COMPLETE=fish $out/bin/epi) \
      --zsh <(COMPLETE=zsh $out/bin/epi)
  ''
