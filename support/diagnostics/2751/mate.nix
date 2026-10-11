{ panelFix ? false, panelSize ? 24, minIconSize ? 24, appRoute ? "nix", killallPackage ? "psmisc", runtimeOnly ? false, revision ? "6132ff3ee5a9509d0aeb66a01a7d662c6384289b" }:
let
  nixpkgs = builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${revision}.tar.gz";
in
import (nixpkgs + "/nixos/tests/make-test-python.nix") ({ pkgs, ... }: let
  officialArchive = pkgs.fetchurl {
    url = "https://github.com/localsend/localsend/releases/download/v1.17.0/LocalSend-1.17.0-linux-x86-64.tar.gz";
    sha256 = "6f05e851b72dbeaac764d3446b5a61c34db22f6278baa92607d5b080997f8c81";
  };
  officialBundle = pkgs.runCommand "localsend-official-1.17.0" {} ''
    mkdir -p "$out"
    tar -xzf ${officialArchive} -C "$out"
  '';
  officialLauncher = pkgs.buildFHSEnv {
    name = "localsend_app";
    includeClosures = true;
    targetPkgs = p: [ p.gtk3 p.libayatana-appindicator p.libGL p.openssl p.stdenv.cc.cc.lib ];
    runScript = pkgs.writeShellScript "localsend-official-launch" ''
      ${pkgs.glibc.bin}/bin/ldd ${officialBundle}/localsend_app > /tmp/evidence/official-ldd.txt
      exec ${officialBundle}/localsend_app "$@"
    '';
  };
  payloadRoot = if appRoute == "official" then officialBundle else pkgs.localsend;
in {
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
    programs.localsend.enable = appRoute == "nix";
    environment.systemPackages = (with pkgs; [ xorg.xrandr xorg.xwininfo xorg.xprop xdotool imagemagick ])
      ++ [ (if killallPackage == "busybox" then pkgs.lib.lowPrio pkgs.busybox else pkgs.psmisc) ]
      ++ pkgs.lib.optional (appRoute == "official") officialLauncher;
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
    machine.wait_until_succeeds("${pkgs.procps}/bin/pgrep mate-panel && ${pkgs.procps}/bin/pgrep -f mate-settings-daemon", timeout=120)
    session_data = machine.succeed("${pkgs.coreutils}/bin/tr '\\0' '\\n' < /proc/$(${pkgs.procps}/bin/pgrep -u alice -f mate-session | ${pkgs.coreutils}/bin/head -1)/environ | ${pkgs.gnused}/bin/sed -n 's/^XDG_DATA_DIRS=//p'").strip()
    assert session_data, "MATE session XDG_DATA_DIRS was not recovered"
    def user_command(command):
        return machine.succeed("${pkgs.shadow}/bin/su - alice -c " + shlex.quote("${env} XDG_DATA_DIRS=" + shlex.quote(session_data) + " " + command))
    user_command("dconf write /org/mate/screensaver/lock-enabled false")
    user_command("dconf write /org/mate/session/idle-delay 0")
    user_command("gsettings set org.mate.interface window-scaling-factor 1")
    user_command("gsettings set org.mate.interface gtk-theme BlackMATE")
    user_command("dconf write /org/mate/panel/objects/notification-area/prefs/min-icon-size ${toString minIconSize}")
    assert user_command("dconf read /org/mate/panel/objects/notification-area/prefs/min-icon-size").strip() == "${toString minIconSize}"
    user_command("dconf write /org/mate/panel/toplevels/top/size ${toString panelSize}")
    user_command("dconf write /org/mate/panel/toplevels/bottom/size ${toString panelSize}")
    machine.sleep(8)
    machine.wait_until_succeeds("${pkgs.procps}/bin/pgrep nm-applet")
    machine.succeed("${pkgs.coreutils}/bin/install -d -o alice -g users /tmp/evidence")
    machine.succeed("nixos-version > /tmp/evidence/environment.txt")
    machine.succeed("${pkgs.coreutils}/bin/readlink -f $(command -v localsend_app) >> /tmp/evidence/environment.txt")
    machine.succeed("${pkgs.coreutils}/bin/sha256sum $(${pkgs.coreutils}/bin/readlink -f $(command -v localsend_app)) >> /tmp/evidence/environment.txt")
    machine.succeed("${pkgs.findutils}/bin/find ${payloadRoot} -type f -exec ${pkgs.coreutils}/bin/sha256sum {} \\; > /tmp/evidence/localsend-package-sha256.txt")
    machine.succeed("printf '%s\\n' '${appRoute}' '${payloadRoot}' '${pkgs.mate.mate-desktop}' '${pkgs.mate.mate-settings-daemon}' >> /tmp/evidence/environment.txt")
    machine.succeed("${pkgs.coreutils}/bin/readlink -f $(command -v mate-panel) >> /tmp/evidence/environment.txt")
    machine.succeed("${pkgs.coreutils}/bin/sha256sum $(${pkgs.coreutils}/bin/readlink -f $(command -v mate-panel)) >> /tmp/evidence/environment.txt")
    machine.screenshot("desktop-ready")
    user_command("xrandr --verbose > /tmp/evidence/xrandr.txt")
    assert "3840x2160" in user_command("xrandr | ${pkgs.gnugrep}/bin/grep 'current 3840 x 2160\\|3840x2160.*\\*'"), "The display is not running at 4K"
    user_command("dconf dump /org/mate/ > /tmp/evidence/mate-initial.dconf")
    daemon_pid = machine.succeed("${pkgs.procps}/bin/pgrep -u alice -f 'libexec/mate-settings-daemon$' | ${pkgs.coreutils}/bin/head -1").strip()
    assert daemon_pid, "The actual settings daemon process was not found"
    machine.succeed("${pkgs.coreutils}/bin/readlink /proc/" + daemon_pid + "/exe > /tmp/evidence/daemon-executable.txt")
    machine.succeed("${pkgs.coreutils}/bin/tr '\\0' '\\n' < /proc/" + daemon_pid + "/environ | ${pkgs.gnused}/bin/sed -n '/^PATH=/p;/^XDG_DATA_DIRS=/p' > /tmp/evidence/daemon-environment.txt")
    machine.succeed("${pkgs.coreutils}/bin/cat ${pkgs.mate.mate-settings-daemon}/libexec/mate-settings-daemon > /tmp/evidence/daemon-wrapper.txt")
    daemon_path = machine.succeed("${pkgs.coreutils}/bin/tr '\\0' '\\n' < /proc/" + daemon_pid + "/environ | ${pkgs.gnused}/bin/sed -n 's/^PATH=//p'").strip()
    assert daemon_path, "The actual daemon PATH was not recovered"
    user_command("${pkgs.coreutils}/bin/env PATH=" + shlex.quote(daemon_path) + " ${pkgs.bash}/bin/bash -c 'command -v killall > /tmp/evidence/daemon-resolved-killall.txt; ${pkgs.coreutils}/bin/readlink -f $(command -v killall) >> /tmp/evidence/daemon-resolved-killall.txt; killall --help >> /tmp/evidence/daemon-resolved-killall.txt 2>&1 || true'")
    resolved_killall = user_command("${pkgs.coreutils}/bin/env PATH=" + shlex.quote(daemon_path) + " ${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/readlink -f $(command -v killall)'").strip()
    assert resolved_killall.startswith("${if killallPackage == "busybox" then pkgs.busybox else pkgs.psmisc}/"), resolved_killall
    machine.copy_from_vm("/tmp/evidence", "guest-runtime-evidence")
    if not ${if runtimeOnly then "True" else "False"}:
        user_command("${pkgs.bash}/bin/bash -c 'localsend_app > /tmp/evidence/localsend.log 2>&1 &' ")
        try:
            machine.wait_for_window("LocalSend", 60)
            machine.wait_for_open_port(53317)
        except Exception:
            machine.succeed("${pkgs.coreutils}/bin/cat /tmp/evidence/localsend.log")
            machine.succeed("${pkgs.procps}/bin/ps -eo pid,lstart,args > /tmp/evidence/startup-processes.txt")
            raise
        finally:
            machine.copy_from_vm("/tmp/evidence", "guest-startup-evidence")
        for label, scale, restart in [
            ("100-live-first", 1, False), ("200-gui", 2, False), ("100-gui", 1, False),
            ("200-live", 2, False),
            ("100-live-return", 1, False), ("200-fresh", 2, True),
            ("100-fresh", 1, True), ("200-live-repeat", 2, False),
            ("200-fresh-repeat", 2, True), ("100-fresh-final", 1, True),
            ("200-panel-replace", 2, False), ("100-panel-replace", 1, False)]:
            if label == "200-gui":
                user_command("${pkgs.bash}/bin/bash -c 'mate-display-properties > /tmp/evidence/display-ui.log 2>&1 &' ")
                machine.wait_for_window("Monitor Preferences", 60)
                machine.screenshot("100-gui-before")
                display_window = user_command("xdotool search --onlyvisible --name '^Monitor Preferences$' | ${pkgs.coreutils}/bin/head -1").strip()
                geometry_text = user_command("xdotool getwindowgeometry --shell " + display_window)
                user_command("xdotool getwindowgeometry --shell " + display_window + " > /tmp/evidence/display-ui-geometry.txt")
                geometry = dict(line.split("=", 1) for line in geometry_text.splitlines())
                # The current 3840x2160 screenshot from run38135333888 shows the
                # 200% radio label at (1938,1166), with client origin (1682,862).
                # Use that observed client offset and require the same layout size.
                assert int(geometry["WIDTH"]) == 565 and int(geometry["HEIGHT"]) == 435, geometry
            if label.endswith("gui"):
                try:
                    if scale == 2:
                        user_command("xdotool mousemove --window " + display_window + " 256 304 click 1")
                        user_command("printf '%s\\n' 'Mouse click on observed 200% radio label at client256,304' >> /tmp/evidence/display-ui-actions.log")
                    else:
                        # The clicked 200% radio retains focus; Left selects its
                        # preceding 100% member through GTK's normal keyboard UI.
                        user_command("xdotool windowactivate --sync " + display_window + " key Left")
                        user_command("printf '%s\\n' 'Left key from focused 200% radio to100%' >> /tmp/evidence/display-ui-actions.log")
                finally:
                    machine.copy_from_vm("/tmp/evidence", "guest-gui-attempt-" + label)
                machine.sleep(3)
                assert user_command("gsettings get org.mate.interface window-scaling-factor").strip() == str(scale)
            else:
                user_command("gsettings set org.mate.interface window-scaling-factor " + str(scale))
            machine.sleep(8)
            if label.endswith("panel-replace"):
                user_command("${pkgs.bash}/bin/bash -c 'mate-panel --replace > /tmp/evidence/" + label + "-panel.log 2>&1 &' ")
                machine.sleep(10)
                machine.wait_until_succeeds("${pkgs.procps}/bin/pgrep mate-panel")
            machine.wait_until_succeeds("${pkgs.procps}/bin/pgrep mate-panel")
            if restart:
                machine.succeed("${pkgs.procps}/bin/pkill -u alice -f '[l]ocalsend_app'")
                machine.sleep(3)
                user_command("${pkgs.bash}/bin/bash -c 'localsend_app >> /tmp/evidence/localsend.log 2>&1 &' ")
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
            machine.succeed("${pkgs.procps}/bin/ps -eo pid,lstart,args > /tmp/evidence/" + label + "-processes.txt")
            machine.succeed("for pid in $(${pkgs.procps}/bin/pgrep -f 'mate-panel|localsend_app'); do echo $pid; ${pkgs.coreutils}/bin/readlink /proc/$pid/exe || true; ${pkgs.coreutils}/bin/cat /proc/$pid/comm || true; ${pkgs.coreutils}/bin/tr '\\0' '\\n' < /proc/$pid/cmdline || true; done > /tmp/evidence/" + label + "-executables.txt")
            machine.copy_from_vm("/tmp/evidence", "guest-evidence-" + label)
    machine.copy_from_vm("/tmp/evidence", "guest-evidence")
  '';
}) {}
