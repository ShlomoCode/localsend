import subprocess, time, pathlib, json, csv, io, os
out=pathlib.Path("/home/probe/evidence"); out.mkdir(exist_ok=True)
events=[]
def run(*args,**kw):
    kw.setdefault("timeout",15)
    return subprocess.run(args,text=True,capture_output=True,**kw)
def log(name,**data):
    events.append(dict(t=time.monotonic(),wall=time.time(),name=name,**data))
    (out/"events.json").write_text(json.dumps(events,indent=2))
def snap(name):
    path=out/(name+".png"); run("scrot",str(path))
    log("screenshot",file=path.name)
    # Sparse UI labels can be dropped by automatic page-layout segmentation.
    res=run("tesseract",str(path),"stdout","--psm","11","tsv")
    (out/(name+".tsv")).write_text(res.stdout)
    return list(csv.DictReader(io.StringIO(res.stdout),delimiter="\t"))
def keyboard_switch(name):
    full_rows=snap(name)
    # Anchor to rendered text: GTK geometry differs from the visible client origin.
    enables=[r for r in full_rows if r["text"].lower()=="enable"]
    if not enables: raise RuntimeError("Supported settings Enable label not located")
    anchor=min(enables,key=lambda r:int(r["top"]))
    left=int(anchor["left"])-29; top=int(anchor["top"])-8
    crop=out/(name+"-rows.png")
    run("scrot","--autoselect",f"{left},{top},628,65",str(crop))
    result=run("tesseract",str(crop),"stdout","--psm","11","tsv")
    (out/(name+"-rows.tsv")).write_text(result.stdout)
    rows=list(csv.DictReader(io.StringIO(result.stdout),delimiter="\t"))
    hits=[r for r in rows if r["text"].lower()=="on-screen"]
    if not hits: raise RuntimeError("Supported virtual keyboard row not located in settings crop")
    r=hits[0]; y=top+int(r["top"])+int(r["height"])//2
    x=left+574
    log("keyboard-toggle-ui",x=x,y=y,crop_left=left,crop_top=top)
    run("xdotool","mousemove",str(x),str(y),"click","1"); time.sleep(4)
def click_word(word,name):
    rows=snap(name)
    hits=[r for r in rows if r["text"].lower().strip()==word.lower()]
    if not hits and word.lower()=="text":
        selections=[r for r in rows if r["text"].lower().strip()=="selection"]
        if not selections: raise RuntimeError("Missing original Selection heading in "+name)
        selection=selections[0]
        left=int(selection["left"])-8; top=int(selection["top"])+24
        crop=out/(name+"-picker.png")
        run("scrot","--autoselect",f"{left},{top},460,80",str(crop))
        result=run("tesseract",str(crop),"stdout","--psm","11","tsv")
        (out/(name+"-picker.tsv")).write_text(result.stdout)
        picker_rows=list(csv.DictReader(io.StringIO(result.stdout),delimiter="\t"))
        hits=[r for r in picker_rows if r["text"].lower().strip()==word.lower()]
        for hit in hits:
            hit["left"]=str(left+int(hit["left"])); hit["top"]=str(top+int(hit["top"]))
        log("picker-ocr-fallback",file=crop.name,x=left,y=top,text_found=bool(hits))
    if not hits: raise RuntimeError("Missing UI label "+word+" in "+name)
    r=hits[0]; x=int(r["left"])+int(r["width"])//2; y=int(r["top"])+int(r["height"])//2
    if word.lower()=="text":
        # The rendered picker shifts with the app when the top keyboard appears.
        crop_x=x-273; crop_y=y+109
        crop=out/(name+"-modal-gate.png")
        run("scrot","--autoselect",f"{crop_x},{crop_y},310,220",str(crop))
        result=run("tesseract",str(crop),"stdout","--psm","6","tsv")
        (out/(name+"-modal-gate.tsv")).write_text(result.stdout)
        modal_rows=list(csv.DictReader(io.StringIO(result.stdout),delimiter="\t"))
        labels={r["text"].lower().strip() for r in modal_rows}
        log("fresh-text-gate",file=crop.name,x=crop_x,y=crop_y,previous_modal={"type","message"}.issubset(labels))
        if {"type","message"}.issubset(labels):
            raise RuntimeError("Previous Text dialog still visible before fresh trigger: "+name)
    log("click",label=word,x=x,y=y); run("xdotool","mousemove",str(x),str(y),"click","1")
def text_case(label):
    trace=None
    if label.endswith("repeat"):
        trace=subprocess.Popen(["sudo","strace","-ff","-tt","-T","-s","4096","-e","trace=poll,ppoll,sendmsg,recvmsg,connect","-p",str(app.pid),"-o",str(out/(label+"-strace"))],stdout=open(out/(label+"-trace-launch.txt"),"w"),stderr=subprocess.STDOUT)
        time.sleep(1)
    click_word("Text",label+"-before")
    start=time.monotonic(); log("text-open",case=label)
    run("xdotool","type","--clearmodifiers","--delay","60",label+" typed control")
    for second in [0,1,3,10,20,35,50,65]:
        time.sleep(max(0,start+second-time.monotonic())); snap(label+"-"+str(second))
        proc=run("ps","-eLo","pid,tid,stat,pcpu,wchan:32,comm").stdout
        focus=run("xdotool","getwindowfocus","getwindowname").stdout
        (out/(label+"-"+str(second)+"-state.txt")).write_text(proc+"\nFOCUS\n"+focus)
        if label.endswith("stack") and second==10:
            stack=run("sudo","gdb","-q","-batch","-p",str(app.pid),"-ex","thread apply all bt 20")
            (out/(label+"-gdb.txt")).write_text(stack.stdout+stack.stderr)
    if trace:
        run("sudo","kill","-INT",str(trace.pid))
    run("xdotool","key","Escape"); time.sleep(2)
def picker_control(word,label):
    # Open and cancel the actual chooser in the same process/keyboard setting.
    click_word(word,label+"-before")
    start=time.monotonic(); deadline=start+10
    observed=False; attempt=0
    while time.monotonic()<deadline:
        rows=snap(label+"-chooser-"+str(attempt))
        labels={r["text"].lower().strip() for r in rows}
        if "cancel" in labels and ("open" in labels or "select" in labels):
            observed=True; break
        attempt+=1; time.sleep(1)
    log("picker-control",case=label,app_pid=app.pid,observed=observed,elapsed=time.monotonic()-start)
    if not observed: raise RuntimeError("Rendered chooser controls absent: "+label)
    click_word("Cancel",label+"-cancel")
    time.sleep(2)
    rows=snap(label+"-returned")
    if not any(r["text"].lower().strip()=="selection" for r in rows):
        raise RuntimeError("Chooser cancel did not return to rendered Send page: "+label)
def capture_geometry_phase():
    # Optional accessibility queries occur only after every original timing case.
    # Capture completion is process evidence, not a geometry or speech pass.
    phase=out/"geometry-post-timing"; phase.mkdir(exist_ok=True)
    status=dict(phase="post-timing-text",status="started",app_pid=app.pid,window_id=w[-1],rendered_modal_observed=False,screen_reader_speech_tested=False,editing_actions_tested=False)
    cloud_ready=False
    log("geometry-phase-start",pid=app.pid,window_id=w[-1])
    try:
        if (os.uname().sysname != "Linux" or not pathlib.Path("/proc").is_dir()
                or out.resolve() != pathlib.Path("/home/mint/evidence")
                or pathlib.Path(__file__).resolve().parent != pathlib.Path("/home/mint/support/diagnostics")
                or not (out/"bootstrap-complete").is_file()
                or "ID=linuxmint" not in pathlib.Path("/etc/os-release").read_text().splitlines()):
            raise RuntimeError("Geometry phase requires the staged cloud Mint UI driver")
        fixture=pathlib.Path(__file__).resolve().parent/"2754-accessibility"/"capture-geometry.sh"
        if not fixture.is_file(): raise RuntimeError("Cloud geometry fixture was not staged")
        cloud_ready=True
        click_word("Text","geometry-fresh-text-before")
        deadline=time.monotonic()+60
        attempt=0
        while True:
            rows=snap("geometry-modal-wait-"+str(attempt))
            labels={r["text"].lower().strip() for r in rows}
            if {"type","message"}.issubset(labels):
                status["rendered_modal_observed"]=True
                log("geometry-modal-rendered",attempt=attempt)
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("Fresh Text dialog did not render Type message before geometry deadline")
            attempt+=1; time.sleep(2)
        env=os.environ.copy(); env["PROBE_CLOUD_GEOMETRY"]="1"
        label=os.environ.get("PROBE_BRIDGE_VARIANT","system")+"-post-timing-text"
        command=["timeout","--kill-after=5s","450s","bash",str(fixture),str(app.pid),label,str(phase),w[-1]]
        status["capture_command"]=command
        with (phase/"capture.stdout").open("w") as stdout, (phase/"capture.stderr").open("w") as stderr:
            captured=subprocess.run(command,env=env,stdout=stdout,stderr=stderr,text=True,timeout=465)
        status.update(status="capture-finished",returncode=captured.returncode,deadline_hit=captured.returncode in (124,137))
        log("geometry-capture-finished",returncode=captured.returncode,deadline_hit=status["deadline_hit"])
    except Exception as error:
        status.update(status="capture-failed",error=type(error).__name__+": "+str(error),deadline_hit=isinstance(error,subprocess.TimeoutExpired))
        log("geometry-phase-failed",error=status["error"],deadline_hit=status["deadline_hit"])
    finally:
        (phase/"phase-status.json").write_text(json.dumps(status,indent=2))
        if cloud_ready:
            try:
                escaped=run("xdotool","key","Escape")
                log("geometry-phase-escape",returncode=escaped.returncode)
            except Exception as error:
                log("geometry-phase-escape-failed",error=type(error).__name__+": "+str(error))
        log("geometry-phase-ended",status=status["status"])
log("start")
executable=os.environ.get("APP_EXECUTABLE","localsend_app")
app=subprocess.Popen([executable],stdin=subprocess.DEVNULL,stdout=open(out/"app.log","w"),stderr=subprocess.STDOUT)
time.sleep(15)
log("app",pid=app.pid,executable=executable,proc_exe=os.readlink(f"/proc/{app.pid}/exe"))
(out/"initial-keyboard-settings.txt").write_text(run("gsettings","list-recursively","org.cinnamon.desktop.a11y.applications").stdout)
# Maximize the actual app window through the window manager.
w=run("xdotool","search","--onlyvisible","--name","LocalSend").stdout.splitlines()
if not w: raise RuntimeError("LocalSend visible window absent")
run("xdotool","windowactivate","--sync",w[-1]); run("xdotool","windowsize",w[-1],"1100","700")
time.sleep(3); snap("app-ready")
click_word("Send","send"); time.sleep(2)
text_case("keyboard-off")
# Paste is a real application action, with clipboard content set by xclip.
# The clipboard owner can outlive the driver; do not let it retain SSH output streams.
subprocess.run(["xclip","-selection","clipboard"],input=b"Paste control issue2754",stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
click_word("Paste","paste-before"); time.sleep(3); snap("paste-result")
# Clear the selection through its rendered close control before the next original Text trigger.
rows=snap("paste-clear-before")
selection=next(r for r in rows if r["text"].lower()=="selection")
clear_x=int(selection["left"])+510
clear_y=int(selection["top"])+int(selection["height"])//2
log("clear-paste-ui",x=clear_x,y=clear_y)
run("xdotool","mousemove",str(clear_x),str(clear_y),"click","1"); time.sleep(2)
cleared=snap("paste-cleared")
if not any(r["text"].lower()=="text" for r in cleared): raise RuntimeError("Paste selection was not cleared through UI")
# Keep the same application process and graphical login while changing a supported UI setting.
settings=subprocess.Popen(["cinnamon-settings","accessibility"],stdin=subprocess.DEVNULL,stdout=open(out/"accessibility.log","w"),stderr=subprocess.STDOUT)
time.sleep(6); snap("accessibility-start")
click_word("Keyboard","accessibility-keyboard-tab"); time.sleep(2)
rows=snap("accessibility-keyboard")
wid=run("xdotool","getwindowfocus").stdout.strip()
keyboard_switch("keyboard-enable")
snap("accessibility-after-toggle")
(out/"keyboard-settings.txt").write_text(run("gsettings","list-recursively","org.cinnamon.desktop.a11y.applications").stdout)
state=run("gsettings","get","org.cinnamon.desktop.a11y.applications","screen-keyboard-enabled").stdout.strip()
if state != "true": raise RuntimeError("UI did not enable supported virtual keyboard: "+state)
(out/"activation-mode.txt").write_text(run("gsettings","get","org.cinnamon.keyboard","activation-mode").stdout)
run("xdotool","windowactivate","--sync",w[-1]); time.sleep(2)
text_case("keyboard-on")
picker_control("File","keyboard-on-file-control")
picker_control("Folder","keyboard-on-folder-control")
# Repeat Paste under the enabled keyboard, then remove its real selection.
subprocess.run(["xclip","-selection","clipboard"],input=b"Paste enabled keyboard control",stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
click_word("Paste","keyboard-on-paste-before"); time.sleep(3); snap("keyboard-on-paste-result")
rows=snap("keyboard-on-paste-clear-before")
selection=next(r for r in rows if r["text"].lower()=="selection")
clear_x=int(selection["left"])+510
clear_y=int(selection["top"])+int(selection["height"])//2
log("clear-paste-ui",case="keyboard-on",x=clear_x,y=clear_y)
run("xdotool","mousemove",str(clear_x),str(clear_y),"click","1"); time.sleep(2)
cleared=snap("keyboard-on-paste-cleared")
if not any(r["text"].lower()=="text" for r in cleared): raise RuntimeError("Keyboard-on Paste selection was not cleared")
text_case("keyboard-on-repeat")
# Return the supported setting through the same UI, then repeat the original trigger.
run("xdotool","windowactivate","--sync",wid); time.sleep(2)
keyboard_switch("keyboard-disable-again")
(out/"keyboard-disabled-again.txt").write_text(run("gsettings","get","org.cinnamon.desktop.a11y.applications","screen-keyboard-enabled").stdout)
if run("gsettings","get","org.cinnamon.desktop.a11y.applications","screen-keyboard-enabled").stdout.strip() != "false":
    raise RuntimeError("UI failed to restore virtual keyboard setting")
run("xdotool","windowactivate","--sync",w[-1]); time.sleep(2)
text_case("keyboard-off-again")
# Capture a separate stack only after completing the uninstrumented off/on/off control.
run("xdotool","windowactivate","--sync",wid); time.sleep(2)
keyboard_switch("keyboard-enable-stack")
if run("gsettings","get","org.cinnamon.desktop.a11y.applications","screen-keyboard-enabled").stdout.strip() != "true":
    raise RuntimeError("UI failed to enable virtual keyboard for stack capture")
run("xdotool","windowactivate","--sync",w[-1]); time.sleep(2)
text_case("keyboard-on-stack")
if os.environ.get("PROBE_CAPTURE_GEOMETRY","0") == "1":
    capture_geometry_phase()
log("completed")
settings.terminate(); app.terminate()
