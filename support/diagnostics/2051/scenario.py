import subprocess, time, pathlib, xml.etree.ElementTree as ET, json
ROOT = pathlib.Path("evidence")

def adb(serial, *args, binary=False):
    return subprocess.check_output(["adb", "-s", serial, *args], text=not binary)

def snapshot(serial, name):
    adb(serial, "shell", "uiautomator", "dump", "/sdcard/ui.xml")
    xml = adb(serial, "shell", "cat", "/sdcard/ui.xml")
    (ROOT / (name + ".xml")).write_text(xml)
    (ROOT / (name + ".png")).write_bytes(adb(serial, "exec-out", "screencap", "-p", binary=True))
    print(name, [(n.get("text"), n.get("content-desc"), n.get("bounds")) for n in ET.fromstring(xml).iter("node") if n.get("text") or n.get("content-desc")], flush=True)
    return xml

time.sleep(8)
for serial, name in [("emulator-5554", "receiver-start"), ("emulator-5556", "sender-start")]:
    snapshot(serial, name)
    (ROOT / (name + "-activity.txt")).write_text(adb(serial, "shell", "dumpsys", "activity", "activities"))
