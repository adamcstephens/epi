{
  cloud-hypervisor,
  lib,
  epi-unwrapped,
  makeWrapper,
  passt,
  qemu-utils,
  runCommand,
  virtiofsd,
  xorriso,
}:
runCommand "epi"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta.mainProgram = "epi";
  }
  ''
    mkdir -vp $out/bin/
    makeWrapper ${lib.getExe epi-unwrapped} $out/bin/epi --prefix PATH : ${
      lib.makeBinPath [
        cloud-hypervisor
        passt
        qemu-utils
        virtiofsd
        xorriso
      ]
    }
  ''
