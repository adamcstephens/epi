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
      --bash <($out/bin/epi completions bash) \
      --fish <($out/bin/epi completions fish) \
      --zsh <($out/bin/epi completions zsh)
  ''
