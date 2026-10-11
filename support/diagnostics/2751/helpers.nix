{ revision ? "6132ff3ee5a9509d0aeb66a01a7d662c6384289b" }:
let
  nixpkgs = builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${revision}.tar.gz";
  pkgs = import nixpkgs { system = "x86_64-linux"; };
in pkgs.runCommand "localsend-2751-helper-preflight" {} ''
  set -euo pipefail
  ${pkgs.procps}/bin/pgrep -u "$(${pkgs.coreutils}/bin/id -u)" -f . > pids
  ${pkgs.procps}/bin/pkill -0 -u "$(${pkgs.coreutils}/bin/id -u)" -f '[b]ash'
  ${pkgs.procps}/bin/ps -eo pid,lstart,args > processes
  ${pkgs.coreutils}/bin/install -d -o "$(${pkgs.coreutils}/bin/id -u)" -g "$(${pkgs.coreutils}/bin/id -g)" scratch
  printf 'PATH=expected\0XDG_DATA_DIRS=expected\0' > scratch/environ
  ${pkgs.coreutils}/bin/tr '\0' '\n' < scratch/environ | ${pkgs.gnused}/bin/sed -n 's/^PATH=//p' | ${pkgs.gnugrep}/bin/grep '^expected$'
  ${pkgs.coreutils}/bin/head -1 processes > scratch/first
  ${pkgs.coreutils}/bin/readlink -f scratch/first > resolved
  ${pkgs.coreutils}/bin/sha256sum scratch/first > checksum
  ${pkgs.findutils}/bin/find scratch -type f -exec ${pkgs.coreutils}/bin/sha256sum {} \; > inventory
  ${pkgs.coreutils}/bin/cat inventory > copied
  ${pkgs.coreutils}/bin/env PREFLIGHT=passed ${pkgs.bash}/bin/bash -c 'test "$PREFLIGHT" = passed'
  ${pkgs.util-linux}/bin/script -q -e -c '${pkgs.shadow.su}/bin/su --help' su-options
  mkdir "$out"
  cp pids processes resolved checksum inventory copied su-options "$out/"
''
