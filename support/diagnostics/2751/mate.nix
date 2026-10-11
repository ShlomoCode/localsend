{ panelFix ? false }:
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
    environment.systemPackages = with pkgs; [ xorg.xrandr xorg.xwininfo xorg.xprop xdotool imagemagick psmisc ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.resolution = { x = 3840; y = 2160; };
    virtualisation.qemu.options = [ "-device virtio-vga,xres=3840,yres=2160" ];
    nixpkgs.overlays = if panelFix then [ (final: prev: {
      mate = prev.mate.overrideScope (mateFinal: matePrev: {
        mate-panel = matePrev.mate-panel.overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            substituteInPlace applets/notification_area/status-notifier/sn-item-v0.c \
              --replace-fail 'pixbuf, icon_size-2, icon_size-2,' \
                'pixbuf, (icon_size-2)*scale, (icon_size-2)*scale,'
          '';
        });
      });
    }) ] else [];
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
    session_data = machine.succeed("tr '\\0' '\\n' < /proc/$(pgrep -u alice -f mate-session | head -1)/environ | sed -n 's/^XDG_DATA_DIRS=//p'").strip()
    assert session_data, "MATE session XDG_DATA_DIRS was not recovered"
    def user_command(command):
        return machine.succeed("su - alice -c " + shlex.quote("${env} XDG_DATA_DIRS=" + shlex.quote(session_data) + " " + command))
    user_command("dconf write /org/mate/screensaver/lock-enabled false")
    user_command("dconf write /org/mate/session/idle-delay 0")
    user_command("gsettings set org.mate.interface window-scaling-factor 1")
    user_command("gsettings set org.mate.interface gtk-theme BlackMATE")
    machine.sleep(8)
    machine.wait_until_succeeds("pgrep nm-applet")
    machine.succeed("install -d -o alice -g users /tmp/evidence")
    machine.succeed("nixos-version > /tmp/evidence/environment.txt")
    machine.succeed("readlink -f $(command -v localsend_app) >> /tmp/evidence/environment.txt")
    machine.succeed("sha256sum $(readlink -f $(command -v localsend_app)) >> /tmp/evidence/environment.txt")
    machine.succeed("printf '%s\\n' '${pkgs.localsend}' '${pkgs.mate.mate-panel}' '${pkgs.mate.mate-desktop}' '${pkgs.mate.mate-settings-daemon}' >> /tmp/evidence/environment.txt")
    machine.screenshot("desktop-ready")
    user_command("xrandr --verbose > /tmp/evidence/xrandr.txt")
    assert "3840x2160" in user_command("xrandr | grep 'current 3840 x 2160\\|3840x2160.*\\*'"), "The display is not running at 4K"
    user_command("dconf dump /org/mate/ > /tmp/evidence/mate-initial.dconf")
    user_command("sh -c 'localsend_app > /tmp/evidence/localsend.log 2>&1 &' ")
    machine.wait_for_window("LocalSend", 60)
    machine.wait_for_open_port(53317)
    for label, scale, restart in [
        ("100-live-first", 1, False), ("200-live", 2, False),
        ("100-live-return", 1, False), ("200-fresh", 2, True),
        ("100-fresh", 1, True), ("200-live-repeat", 2, False),
        ("200-fresh-repeat", 2, True), ("100-fresh-final", 1, True)]:
        user_command("gsettings set org.mate.interface window-scaling-factor " + str(scale))
        machine.sleep(8)
        machine.wait_until_succeeds("pgrep mate-panel")
        if restart:
            machine.succeed("pkill -u alice -f '[l]ocalsend_app'")
            machine.sleep(3)
            user_command("sh -c 'localsend_app >> /tmp/evidence/localsend.log 2>&1 &' ")
            machine.wait_for_window("LocalSend", 60)
            machine.wait_for_open_port(53317)
        machine.sleep(8)
        user_command("xwininfo -root -tree > /tmp/evidence/" + label + "-windows.txt")
        user_command("dconf dump /org/mate/ > /tmp/evidence/" + label + ".dconf")
        user_command("busctl --user list > /tmp/evidence/" + label + "-bus.txt")
        user_command("busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems > /tmp/evidence/" + label + "-items.txt")
        items = shlex.split(user_command("busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems"))
        for item in items[2:]:
            service, path = item.split("/", 1)
            user_command("busctl --user introspect " + shlex.quote(service) + " " + shlex.quote("/" + path) + " org.kde.StatusNotifierItem >> /tmp/evidence/" + label + "-properties.txt")
        machine.screenshot(label)
        machine.succeed("ps -eo pid,lstart,args > /tmp/evidence/" + label + "-processes.txt")
        machine.copy_from_vm("/tmp/evidence", "guest-evidence-" + label)
    machine.copy_from_vm("/tmp/evidence", "guest-evidence")
  '';
})
