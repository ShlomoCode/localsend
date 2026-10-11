import subprocess, time, pathlib, xml.etree.ElementTree as ET, re, json, urllib.request
ROOT = pathlib.Path("evidence")
S, R = "emulator-5556", "emulator-5554"

def adb(serial, *args, binary=False):
    return subprocess.check_output(["adb", "-s", serial, *args], text=not binary)

sessions = {}

def request(method, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request("http://127.0.0.1:4723" + path, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as response:
        return json.load(response)["value"]

def snapshot(serial, name):
    (ROOT / (name + ".png")).write_bytes(adb(serial, "exec-out", "screencap", "-p", binary=True))
    if serial not in sessions:
        value = request("POST", "/session", {"capabilities": {"alwaysMatch": {"platformName": "Android", "appium:automationName": "UiAutomator2", "appium:udid": serial, "appium:noReset": True, "appium:autoLaunch": False, "appium:systemPort": 8200 if serial == R else 8201, "appium:newCommandTimeout": 600, "appium:settings[waitForIdleTimeout]": 0}}})
        sessions[serial] = value["sessionId"]
        request("POST", "/session/" + sessions[serial] + "/appium/settings", {"settings": {"waitForIdleTimeout": 0}})
    xml = request("GET", "/session/" + sessions[serial] + "/source")
    (ROOT / (name + ".xml")).write_text(xml)
    (ROOT / (name + ".png")).write_bytes(adb(serial, "exec-out", "screencap", "-p", binary=True))
    print(name, [(n.get("text"), n.get("content-desc"), n.get("bounds")) for n in ET.fromstring(xml).iter() if n.get("text") or n.get("content-desc")], flush=True)
    return xml

def click(serial, label, name):
    xml = snapshot(serial, name)
    tree = ET.fromstring(xml)
    parents = {child: parent for parent in tree.iter() for child in parent}
    for n in tree.iter():
        values = [n.get("text", ""), n.get("content-desc", "")]
        if any(v == label or v.startswith(label + "\n") for v in values):
            target = n
            while target.get("clickable") != "true" and target.get("is-collection-item") != "true" and target in parents:
                target = parents[target]
            if target.get("clickable") != "true" and target.get("is-collection-item") != "true":
                target = n
            a,b,c,d = map(int, re.findall(r"\d+", target.get("bounds")))
            print("INPUT", serial, label, target.get("class"), target.get("bounds"), flush=True)
            adb(serial, "shell", "input", "tap", str((a+c)//2), str((b+d)//2))
            time.sleep(2)
            return
    raise RuntimeError("Missing UI label " + label + " at " + name)

time.sleep(8)
try:
    receiver_xml = snapshot(R, "receiver-start")
    receiver_alias = next(n.get("content-desc") for n in ET.fromstring(receiver_xml).iter() if n.get("content-desc"))
    snapshot(S, "sender-start")
    adb(R, "forward", "tcp:53317", "tcp:53317")
    adb(R, "logcat", "-c")
    local = ROOT / "a.txt"
    local.write_text("ISSUE2051_CONTENT_A\n")
    adb(S, "push", str(local), "/sdcard/Download/a.txt")
    click(S, "Send", "sender-before-send")
    click(S, "File", "sender-before-files")
    snapshot(S, "picker-start")
    # Android DocumentsUI defaults to Recents; choose the Download root explicitly.
    click(S, "Show roots", "picker-before-roots")
    click(S, "Downloads", "picker-before-downloads")
    click(S, "List view", "picker-before-list-view")
    click(S, "a.txt", "picker-before-file")
    picked_xml = snapshot(S, "picker-after-file")
    if "com.google.android.documentsui" in picked_xml:
        tree = ET.fromstring(picked_xml)
        title = next(n for n in tree.iter() if n.get("text") == "a.txt")
        a,b,c,d = map(int, re.findall(r"\d+", title.get("bounds")))
        x,y = (a+c)//2,(b+d)//2
        request("POST", "/session/" + sessions[S] + "/actions", {"actions": [{"type": "pointer", "id": "finger", "parameters": {"pointerType": "touch"}, "actions": [{"type": "pointerMove", "duration": 0, "x": x, "y": y}, {"type": "pointerDown", "button": 0}, {"type": "pause", "duration": 100}, {"type": "pointerUp", "button": 0}]}]})
        time.sleep(2)
        picked_xml = snapshot(S, "picker-after-w3c-touch")
    if "com.google.android.documentsui" in picked_xml:
        adb(S, "shell", "input", "swipe", str(x), str(y), str(x), str(y), "1200")
        picked_xml = snapshot(S, "picker-after-longpress")
        labels = [n.get("text", "") for n in ET.fromstring(picked_xml).iter()]
        controls = [label for label in ["Open", "Select", "OPEN", "SELECT"] if label in labels]
        if not controls:
            raise RuntimeError("Picker remained without observed Open/Select after tap, touch, longpress")
        click(S, controls[0], "picker-before-confirm-selection")
    click(S, receiver_alias, "sender-before-target")
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
