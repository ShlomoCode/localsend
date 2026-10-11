import subprocess, time, pathlib, xml.etree.ElementTree as ET, re, json
ROOT = pathlib.Path("evidence")
S, R = "emulator-5556", "emulator-5554"

def adb(serial, *args, binary=False):
    return subprocess.check_output(["adb", "-s", serial, *args], text=not binary)

def snapshot(serial, name):
    adb(serial, "shell", "uiautomator", "dump", "/sdcard/ui.xml")
    xml = adb(serial, "shell", "cat", "/sdcard/ui.xml")
    (ROOT / (name + ".xml")).write_text(xml)
    (ROOT / (name + ".png")).write_bytes(adb(serial, "exec-out", "screencap", "-p", binary=True))
    print(name, [(n.get("text"), n.get("content-desc"), n.get("bounds")) for n in ET.fromstring(xml).iter("node") if n.get("text") or n.get("content-desc")], flush=True)
    return xml

def click(serial, label, name):
    xml = snapshot(serial, name)
    for n in ET.fromstring(xml).iter("node"):
        values = [n.get("text", ""), n.get("content-desc", "")]
        if any(v == label or v.startswith(label + "\n") for v in values):
            a,b,c,d = map(int, re.findall(r"\d+", n.get("bounds")))
            adb(serial, "shell", "input", "tap", str((a+c)//2), str((b+d)//2))
            time.sleep(2)
            return
    raise RuntimeError("Missing UI label " + label + " at " + name)

time.sleep(8)
try:
    snapshot(R, "receiver-start")
    snapshot(S, "sender-start")
    adb(R, "forward", "tcp:53317", "tcp:53317")
    adb(R, "logcat", "-c")
    local = ROOT / "a.txt"
    local.write_text("ISSUE2051_CONTENT_A\n")
    adb(S, "push", str(local), "/sdcard/Download/a.txt")
    click(S, "Send", "sender-before-send")
    click(S, "Files", "sender-before-files")
    snapshot(S, "picker-start")
    # Android DocumentsUI defaults to Recents; choose the Download root explicitly.
    click(S, "Show roots", "picker-before-roots")
    click(S, "Downloads", "picker-before-downloads")
    click(S, "a.txt", "picker-before-file")
    click(S, "Manual sending", "sender-before-manual")
    xml = snapshot(S, "address-dialog")
    edits = [n for n in ET.fromstring(xml).iter("node") if n.get("class") == "android.widget.EditText"]
    if not edits:
        raise RuntimeError("No address field")
    a,b,c,d = map(int, re.findall(r"\d+", edits[0].get("bounds")))
    adb(S, "shell", "input", "tap", str((a+c)//2), str((b+d)//2))
    adb(S, "shell", "input", "text", "10.0.2.2")
    adb(S, "shell", "input", "keyevent", "4")
    snapshot(S, "address-entered")
    click(S, "Confirm", "address-before-confirm")
    time.sleep(4)
    snapshot(R, "receiver-request")
    click(R, "Accept", "receiver-before-accept")
    time.sleep(5)
    snapshot(R, "receiver-complete")
    snapshot(S, "sender-complete")
finally:
    for serial,name in [(R,"receiver-final"),(S,"sender-final")]:
        try:
            snapshot(serial,name)
            (ROOT/(name+"-activity.txt")).write_text(adb(serial,"shell","dumpsys","activity","activities"))
            (ROOT/(name+"-logcat.txt")).write_text(adb(serial,"logcat","-d"))
            (ROOT/(name+"-files.txt")).write_text(adb(serial,"shell","find","/sdcard/Download","-type","f"))
        except Exception as e:
            print("Capture failure",str(e),flush=True)
