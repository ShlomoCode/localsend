let
  revision = "6132ff3ee5a9509d0aeb66a01a7d662c6384289b";
  nixpkgs = builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${revision}.tar.gz";
in
import (nixpkgs + "/nixos/tests/make-test-python.nix") ({ pkgs, ... }: {
  name = "localsend-2751-mate-4k";
  nodes.machine = { ... }: {
    imports = [ (nixpkgs + "/nixos/tests/common/user-account.nix") ];
    services.xserver.enable = true;
    services.xserver.displayManager.lightdm.enable = true;
    services.xserver.displayManager.autoLogin = { enable = true; user = "alice"; };
    services.xserver.desktopManager.mate.enable = true;
    services.displayManager.defaultSession = "mate";
    networking.networkmanager.enable = true;
    programs.nm-applet.enable = true;
    programs.localsend.enable = true;
    environment.systemPackages = with pkgs; [ xorg.xrandr xorg.xwininfo xorg.xprop xdotool imagemagick ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.resolution = { x = 3840; y = 2160; };
  };
  testScript = { nodes, ... }: let
    user = nodes.machine.users.users.alice;
    env = "DISPLAY=:0.0 XAUTHORITY=${user.home}/.Xauthority DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString user.uid}/bus";
  in ''
    import shlex
    start_all()
    machine.wait_for_x()
    machine.wait_for_file("${user.home}/.Xauthority")
    machine.succeed("xauth merge ${user.home}/.Xauthority")
    machine.wait_until_succeeds("pgrep mate-panel && pgrep -f mate-settings-daemon", timeout=120)
    def user_command(command):
        return machine.succeed("su - alice -c " + shlex.quote("${env} " + command))
    user_command("gsettings set org.mate.screensaver lock-enabled false")
    user_command("gsettings set org.mate.session idle-delay 0")
    user_command("gsettings set org.mate.interface window-scaling-factor 1")
    machine.sleep(8)
    machine.wait_until_succeeds("pgrep nm-applet")
    machine.succeed("mkdir -p /tmp/evidence")
    machine.succeed("nixos-version > /tmp/evidence/environment.txt; readlink -f $(command -v localsend_app) >> /tmp/evidence/environment.txt; sha256sum $(readlink -f $(command -v localsend_app)) >> /tmp/evidence/environment.txt; mate-panel --version >> /tmp/evidence/environment.txt; mate-settings-daemon --version >> /tmp/evidence/environment.txt 2>&1 || true")
    user_command("xrandr --verbose > /tmp/evidence/xrandr.txt")
    user_command("dconf dump /org/mate/ > /tmp/evidence/mate-initial.dconf")
    user_command("sh -c 'localsend_app > /tmp/evidence/localsend.log 2>&1 &' ")
    machine.wait_for_window("LocalSend", 60)
    machine.wait_for_open_port(53317)
    for label, scale, restart in [
        ("100-live-first", 1, False), ("200-live", 2, False),
        ("100-live-return", 1, False), ("200-fresh", 2, True),
        ("100-fresh", 1, True), ("200-live-repeat", 2, False)]:
        user_command("gsettings set org.mate.interface window-scaling-factor " + str(scale))
        machine.sleep(8)
        machine.wait_until_succeeds("pgrep mate-panel")
        if restart:
            machine.succeed("pkill -x localsend_app")
            machine.sleep(3)
            user_command("sh -c 'localsend_app >> /tmp/evidence/localsend.log 2>&1 &' ")
            machine.wait_for_window("LocalSend", 60)
            machine.wait_for_open_port(53317)
        machine.sleep(8)
        user_command("xwininfo -root -tree > /tmp/evidence/" + label + "-windows.txt")
        user_command("dconf dump /org/mate/ > /tmp/evidence/" + label + ".dconf")
        user_command("busctl --user list > /tmp/evidence/" + label + "-bus.txt")
        user_command("busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems > /tmp/evidence/" + label + "-items.txt")
        machine.screenshot(label)
        machine.succeed("ps -eo pid,lstart,args > /tmp/evidence/" + label + "-processes.txt")
    machine.copy_from_vm("/tmp/evidence", "guest-evidence")
  '';
})
