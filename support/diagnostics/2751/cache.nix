{ revision }:
let
  nixpkgs = builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${revision}.tar.gz";
  pkgs = import nixpkgs { system = "x86_64-linux"; };
in map toString [ pkgs.localsend pkgs.mate.mate-panel pkgs.mate.mate-settings-daemon ]
