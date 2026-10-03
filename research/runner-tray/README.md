# Isolated tray identity research harness

Run remotely on Ubuntu 24.04 with Flutter **3.41.9**. The harness pins
**tray_manager 0.5.3** and **path 1.9.1**. No LocalSend files are used or modified.

The controller provides a minimal StatusNotifierWatcher, launches two fresh
processes using the public setIcon API, then two processes using the existing
native MethodChannel with a stable ID. It obtains the actual StatusNotifierItem
Id and actual dbusmenu layout, sends Open and Quit clicked events, and requires
both Dart callbacks and a clean Quit exit.

Required remote tools/libraries: Flutter Linux build prerequisites, GTK3,
libayatana-appindicator3-dev, Xvfb, dbus-run-session, Python3, python3-dbus,
python3-gi and GLib introspection. Use the system Python at /usr/bin/python3
because virtual environments may omit Ubuntu's dbus/GI modules.

## Remote setup/build

Copy this directory to a runner scratch directory. Install prerequisites only
on the remote runner if missing:

```sh
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libstdc++-12-dev libayatana-appindicator3-dev xvfb dbus-x11 python3-dbus python3-gi gir1.2-glib-2.0
flutter --version
```

Require the version output to show Flutter 3.41.9. From the copied harness directory:

```sh
cp pubspec.yaml research-pubspec.yaml
cp lib/main.dart research-main.dart
flutter create --no-pub --platforms=linux --project-name=tray_identity_research .
cp research-pubspec.yaml pubspec.yaml
cp research-main.dart lib/main.dart
mkdir -p assets
/usr/bin/python3 prepare_icon.py
flutter pub get
flutter build linux --release
dbus-run-session -- xvfb-run -a /usr/bin/python3 run.py build/linux/x64/release/bundle/tray_identity_research --output observations
```

flutter create generates the stock GTK runner. Restoring the research pubspec
and main afterward prevents its generated example from replacing the harness.
The controller expects a real X11 display; run the whole controller and child
apps inside the same Xvfb and D-Bus session.

Upload observations/result.json and all four .log files. A pass requires
different random baseline IDs, two identical patched IDs, and Open/Quit callbacks
for all four app processes.

## Path fidelity and limits

The patched iconPath uses the exact installed sandbox helper and the same
executable-relative data/flutter_assets location as tray_manager 0.5.3. This is
the candidate's precise method-channel seam, including its private API risk.
In container/sandbox environments the existing helper intentionally leaves the
icon name/path alone in both modes; the tiny PNG may not be visibly resolvable
there, but the actual exported ID and menu are still the observations.

Open increments a visible Flutter counter; Quit destroys the indicator and
exits. This confirms native dbusmenu-to-Dart callback delivery. It does not
exercise LocalSend showFromTray or prove KDE popup preferences persist. The
watcher is a minimal research host, not a full KDE/GNOME shell.

Source anchors:
- https://github.com/leanflutter/tray_manager/blob/v0.5.3/packages/tray_manager/lib/src/tray_manager.dart#L106
- https://github.com/leanflutter/tray_manager/blob/v0.5.3/packages/tray_manager/linux/tray_manager_plugin.cc#L109
- https://github.com/leanflutter/tray_manager/blob/v0.5.3/packages/tray_manager/lib/src/helpers/sandbox.dart
