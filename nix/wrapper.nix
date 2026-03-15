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
      lib.makeBinPath [
        cloud-hypervisor
        passt
        qemu-utils
        rsync
        virtiofsd
        xorriso
      ]
    }

    installShellCompletion --cmd epi \
      --bash <(COMPLETE=bash $out/bin/epi) \
      --fish <(COMPLETE=fish $out/bin/epi) \
      --zsh <(COMPLETE=zsh $out/bin/epi)
  ''
