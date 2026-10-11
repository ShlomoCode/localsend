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
log("completed")
settings.terminate(); app.terminate()
