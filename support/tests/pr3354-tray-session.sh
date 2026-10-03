#!/usr/bin/env bash
set -euo pipefail
case_name=$1
bundle=$2
evidence=$3
export XDG_CONFIG_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR
XDG_CONFIG_HOME=$(mktemp -d)
XDG_CACHE_HOME=$(mktemp -d)
XDG_RUNTIME_DIR=$(mktemp -d)
chmod 700 "$XDG_RUNTIME_DIR"
export XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 LIBGL_ALWAYS_SOFTWARE=1
unset SNAP
if [ "$case_name" != control ]; then
  export SNAP=/snap/localsend/current
fi
xfconf-query -c xfce4-panel -p /panels -n -a -t int -s 1
xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids -n -a -t int -s 1
xfconf-query -c xfce4-panel -p /plugins/plugin-1 -n -t string -s statusnotifier
xfconf-query -c xfce4-panel -p /panels/panel-1/position -n -t string -s 'p=6;x=512;y=20'
xfconf-query -c xfce4-panel -p /panels/panel-1/size -n -t int -s 40
xfconf-query -c xfce4-panel -p /panels/panel-1/length -n -t uint -s 100
xfconf-query -c xfce4-panel -p /panels/panel-1/position-locked -n -t bool -s true
openbox > "$evidence/$case_name-wm.log" 2>&1 &
wm_pid=$!
xfce4-panel --disable-wm-check > "$evidence/$case_name-panel.log" 2>&1 &
panel_pid=$!
trap 'kill "${app_pid:-}" "$panel_pid" "$wm_pid" 2>/dev/null || true' EXIT
sleep 3
(cd "$bundle" && exec ./localsend_app) > "$evidence/$case_name-app.log" 2>&1 &
app_pid=$!
python3 - "$case_name" "$evidence" <<'PY'
import dbus, json, os, pathlib, sys, time
case, output = sys.argv[1:]
bus = dbus.SessionBus()
deadline = time.monotonic() + 90
while time.monotonic() < deadline:
    try:
        watcher = bus.get_object('org.kde.StatusNotifierWatcher', '/StatusNotifierWatcher')
        items = dbus.Interface(watcher, 'org.freedesktop.DBus.Properties').Get('org.kde.StatusNotifierWatcher', 'RegisteredStatusNotifierItems')
        if len(items) == 1:
            item = str(items[0])
            service, path = item.split('/', 1)
            props = dbus.Interface(bus.get_object(service, '/' + path), 'org.freedesktop.DBus.Properties')
            data = props.GetAll('org.kde.StatusNotifierItem')
            icon = str(data['IconName'])
            record = {'item': item, 'icon': icon, 'title': str(data.get('Title', '')), 'snap': os.environ.get('SNAP')}
            pathlib.Path(output, case + '-indicator.json').write_text(json.dumps(record, indent=2))
            if case == 'before':
                assert icon.startswith('assets/'), icon
                assert not os.path.isabs(icon), icon
            else:
                assert os.path.isabs(icon) and os.path.isfile(icon), icon
            break
    except dbus.DBusException:
        pass
    time.sleep(1)
else:
    raise RuntimeError('LocalSend did not register exactly one StatusNotifierItem')
PY
sleep 4
import -window root "$evidence/$case_name-full.png"
convert "$evidence/$case_name-full.png" -crop 1024x40+0+0 +repage "$evidence/$case_name-tray.png"
