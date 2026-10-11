import os, subprocess, time, pathlib, xml.etree.ElementTree as ET, re, json, urllib.request, hashlib, shlex, signal
ROOT = pathlib.Path("evidence")
S, R = "emulator-5556", "emulator-5554"
SAF = os.environ.get("ISSUE2051_SCENARIO", "saf") == "saf"
sessions = {}

def adb(serial, *args, binary=False):
    return subprocess.check_output(["adb", "-s", serial, *args], text=not binary)

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

def touch(serial, x, y):
    request("POST", "/session/" + sessions[serial] + "/actions", {"actions": [{"type": "pointer", "id": "finger", "parameters": {"pointerType": "touch"}, "actions": [{"type": "pointerMove", "duration": 0, "x": x, "y": y}, {"type": "pointerDown", "button": 0}, {"type": "pause", "duration": 100}, {"type": "pointerUp", "button": 0}]}]})
    time.sleep(2)

def labels(xml):
    return [n.get(a, "") for n in ET.fromstring(xml).iter() for a in ["text", "content-desc"]]

def click(serial, label, name):
    xml = snapshot(serial, name)
    tree = ET.fromstring(xml)
    parents = {child: parent for parent in tree.iter() for child in parent}
    for n in tree.iter():
        if any(v == label or v.startswith(label + "\n") for v in [n.get("text", ""), n.get("content-desc", "")]):
            target = n
            while target.get("clickable") != "true" and target.get("is-collection-item") != "true" and target in parents:
                target = parents[target]
            if target.get("clickable") != "true" and target.get("is-collection-item") != "true":
                target = n
            a,b,c,d = map(int, re.findall(r"\d+", target.get("bounds")))
            print("INPUT", serial, label, target.get("class"), target.get("bounds"), flush=True)
            touch(serial, (a+c)//2, (b+d)//2)
            return
    raise RuntimeError("Missing UI label " + label + " at " + name)

def choose_saf_destination():
    adb(R, "shell", "mkdir", "-p", "/sdcard/Download/Issue2051")
    click(R, "Settings", "saf-before-settings")
    for index in range(8):
        xml = snapshot(R, "saf-settings-" + str(index))
        if "(Downloads)" in labels(xml):
            break
        request("POST", "/session/" + sessions[R] + "/actions", {"actions": [{"type": "pointer", "id": "scrollfinger", "parameters": {"pointerType": "touch"}, "actions": [{"type": "pointerMove", "duration": 0, "x": 160, "y": 500}, {"type": "pointerDown", "button": 0}, {"type": "pointerMove", "duration": 600, "x": 160, "y": 200}, {"type": "pointerUp", "button": 0}]}]})
        time.sleep(2)
    click(R, "(Downloads)", "saf-before-destination")
    xml = snapshot(R, "saf-directory-picker")
    for attempt in range(8):
        if "Issue2051" in labels(xml) or "Download" in labels(xml) or "Show roots" in labels(xml):
            break
        time.sleep(1)
        xml = snapshot(R, "saf-directory-loaded-" + str(attempt))
    if "Issue2051" not in labels(xml):
        if "Download" in labels(xml):
            if "List view" in labels(xml):
                click(R, "List view", "saf-before-list")
            for attempt in range(6):
                visible = snapshot(R, "saf-download-visible-" + str(attempt))
                if "Download" in labels(visible):
                    break
                request("POST", "/session/" + sessions[R] + "/actions", {"actions": [{"type": "pointer", "id": "folderscroll", "parameters": {"pointerType": "touch"}, "actions": [{"type": "pointerMove", "duration": 0, "x": 160, "y": 500}, {"type": "pointerDown", "button": 0}, {"type": "pointerMove", "duration": 600, "x": 160, "y": 350}, {"type": "pointerUp", "button": 0}]}]})
                time.sleep(1)
            click(R, "Download", "saf-before-download-folder")
        else:
            click(R, "Show roots", "saf-before-roots")
            click(R, "Downloads", "saf-before-downloads")
    click(R, "Issue2051", "saf-before-subdirectory")
    xml = snapshot(R, "saf-before-grant")
    label = next(v for v in labels(xml) if v.lower() == "use this folder")
    click(R, label, "saf-before-use-folder")
    xml = snapshot(R, "saf-grant-dialog")
    if "ALLOW" in labels(xml):
        click(R, "ALLOW", "saf-before-allow")
    elif "Allow" in labels(xml):
        click(R, "Allow", "saf-before-allow")
    xml = snapshot(R, "saf-destination-set")
    if "content://" not in xml:
        raise RuntimeError("SAF destination not shown in settings")
    (ROOT / "saf-uri-permissions.txt").write_text(adb(R, "shell", "dumpsys", "activity", "permissions"))
    click(R, "Receive", "saf-return-receive")

def transfer(content, phase):
    local = ROOT / (phase + "-sent-a.txt")
    local.write_text(content)
    adb(S, "push", str(local), "/sdcard/Download/a.txt")
    click(S, "File", phase + "-sender-before-files")
    initial_picker = snapshot(S, phase + "-picker-initial")
    if "a.txt" not in labels(initial_picker):
        click(S, "Show roots", phase + "-picker-before-roots")
        click(S, "Downloads", phase + "-picker-before-downloads")
    xml = snapshot(S, phase + "-picker-layout")
    if "List view" in labels(xml):
        click(S, "List view", phase + "-picker-before-list")
    click(S, "a.txt", phase + "-picker-before-file")
    xml = snapshot(S, phase + "-picker-after-file")
    if "com.google.android.documentsui" in xml:
        raise RuntimeError("Picker did not return after verified touch input")
    click(S, receiver_alias, phase + "-sender-before-target")
    time.sleep(4)
    click(R, "Accept", phase + "-receiver-before-accept")
    time.sleep(5)
    xml = snapshot(R, phase + "-receiver-complete")
    snapshot(S, phase + "-sender-complete")
    if "100%, Finished" not in xml:
        raise RuntimeError("Receiver did not finish")
    files = adb(R, "shell", "find", "/sdcard/Download", "-type", "f").strip().splitlines()
    saved = []
    for path in files:
        path = path.strip()
        if path.endswith(".txt"):
            pulled = ROOT / (phase + "-saved-" + pathlib.Path(path).name)
            adb(R, "pull", path, str(pulled))
            data = pulled.read_bytes()
            saved.append({"path": path, "sha256": hashlib.sha256(data).hexdigest(), "content": data.decode()})
    (ROOT / (phase + "-saved.json")).write_text(json.dumps(saved, indent=2))
    print("SAVED", phase, saved, flush=True)
    expected = content.encode()
    if not any(item["sha256"] == hashlib.sha256(expected).hexdigest() for item in saved):
        raise RuntimeError("Sent content absent from saved files")
    return xml, saved

def open_actual(filename, phase, viewer="Markor"):
    recording = subprocess.Popen(["adb", "-s", R, "shell", "screenrecord", "/sdcard/" + phase + ".mp4"])
    try:
        click(R, filename, phase + "-before-file-row")
        xml = snapshot(R, phase + "-after-file-row")
        if "Open" in labels(xml):
            click(R, "Open", phase + "-before-open")
        time.sleep(3)
        xml = snapshot(R, phase + "-viewer")
        if viewer in labels(xml):
            click(R, viewer, phase + "-before-viewer-choice")
            xml = snapshot(R, phase + "-chooser")
        if "Just once" in labels(xml):
            click(R, "Just once", phase + "-before-just-once")
            time.sleep(3)
            xml = snapshot(R, phase + "-viewer-selected")
        (ROOT / (phase + "-intent.txt")).write_text(adb(R, "shell", "dumpsys", "activity", "activities"))
        print("VIEWER", phase, labels(xml), flush=True)
        return xml
    finally:
        adb(R, "shell", "pkill", "-2", "screenrecord")
        recording.wait(timeout=10)
        adb(R, "pull", "/sdcard/" + phase + ".mp4", str(ROOT / (phase + ".mp4")))

time.sleep(8)
try:
    receiver_xml = snapshot(R, "receiver-start")
    receiver_alias = next(n.get("content-desc") for n in ET.fromstring(receiver_xml).iter() if n.get("content-desc"))
    snapshot(S, "sender-start")
    adb(R, "logcat", "-c")
    if SAF:
        choose_saf_destination()
    click(S, "Send", "sender-before-send")
    _, saved = transfer("ISSUE2051_CONTENT_A\n", "A")
    a_viewer = open_actual("a.txt", "A-open")
    if "ISSUE2051_CONTENT_A" not in a_viewer:
        raise RuntimeError("A viewer control did not expose original content")
    adb(R, "shell", "input", "keyevent", "4")
    time.sleep(2)
    click(R, "Done", "A-receiver-before-done")
    click(S, "Done", "A-sender-before-done")
    b_complete, saved = transfer("ISSUE2051_CONTENT_B\n", "B")
    numbered = next(pathlib.Path(item["path"]).name for item in saved if item["content"] == "ISSUE2051_CONTENT_B\n")
    displayed = next(value.split("\n")[0] for value in labels(b_complete) if "(20 B)" in value)
    print("B_FILE_IDENTITY", {"saved": numbered, "displayed": displayed}, flush=True)
    b_viewer = open_actual(displayed, "B-open")
    result = {"saved_B_filename": numbered, "displayed_B_filename": displayed, "viewer_has_A": "ISSUE2051_CONTENT_A" in b_viewer, "viewer_has_B": "ISSUE2051_CONTENT_B" in b_viewer}
    (ROOT / "result.json").write_text(json.dumps(result, indent=2))
    print("RESULT", result, flush=True)
    if not result["viewer_has_A"] and not result["viewer_has_B"]:
        raise RuntimeError("Viewer observation incomplete")
    if result["viewer_has_B"] and not SAF:
        adb(R, "shell", "input", "keyevent", "4")
        time.sleep(2)
        click(R, "Done", "B-before-history-done")
        home = snapshot(R, "B-before-history")
        buttons = [n for n in ET.fromstring(home).iter() if n.get("class") == "android.widget.Button"]
        if not buttons:
            raise RuntimeError("Home history icon missing")
        a,b,c,d = map(int, re.findall(r"\d+", buttons[0].get("bounds")))
        print("INPUT_HISTORY_ICON", buttons[0].get("bounds"), flush=True)
        touch(R, (a+c)//2, (b+d)//2)
        history = snapshot(R, "B-history")
        history = snapshot(R, "B-history-before-menu")
        entry = next(n for n in ET.fromstring(history).iter() if n.get("content-desc", "").startswith("a.txt\n"))
        a,b,c,d = map(int, re.findall(r"\d+", entry.get("bounds")))
        # Screenshot confirms overflow icon at x281 inside the first entry; anchor to its captured right bound.
        print("INPUT_HISTORY_MENU", {"entry": entry.get("bounds"), "x": c-24, "y": (b+d)//2}, flush=True)
        touch(R, c-24, (b+d)//2)
        snapshot(R, "B-history-menu")
        historical = open_actual("Open file", "B-history-open")
        (ROOT / "history-result.json").write_text(json.dumps({"has_A": "ISSUE2051_CONTENT_A" in historical, "has_B": "ISSUE2051_CONTENT_B" in historical}, indent=2))
finally:
    for serial,name in [(R,"receiver-final"),(S,"sender-final")]:
        try:
            snapshot(serial,name)
            (ROOT/(name+"-activity.txt")).write_text(adb(serial,"shell","dumpsys","activity","activities"))
            (ROOT/(name+"-logcat.txt")).write_text(adb(serial,"logcat","-d"))
            (ROOT/(name+"-files.txt")).write_text(adb(serial,"shell","find","/sdcard/Download","-type","f"))
        except Exception as e:
            print("Capture failure",str(e),flush=True)
