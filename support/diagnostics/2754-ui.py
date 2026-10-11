import subprocess, time, pathlib, json, csv, io, os
out=pathlib.Path("/home/probe/evidence"); out.mkdir(exist_ok=True)
events=[]
def run(*args,**kw): return subprocess.run(args,text=True,capture_output=True,**kw)
def log(name,**data):
    events.append(dict(t=time.monotonic(),wall=time.time(),name=name,**data))
    (out/"events.json").write_text(json.dumps(events,indent=2))
def snap(name):
    path=out/(name+".png"); run("scrot",str(path))
    res=run("tesseract",str(path),"stdout","tsv")
    (out/(name+".tsv")).write_text(res.stdout)
    return list(csv.DictReader(io.StringIO(res.stdout),delimiter="\t"))
def click_word(word,name):
    rows=snap(name)
    hits=[r for r in rows if r["text"].lower().strip()==word.lower()]
    if not hits: raise RuntimeError("Missing UI label "+word+" in "+name)
    r=hits[0]; x=int(r["left"])+int(r["width"])//2; y=int(r["top"])+int(r["height"])//2
    log("click",label=word,x=x,y=y); run("xdotool","mousemove",str(x),str(y),"click","1")
def text_case(label):
    trace=None
    if label.endswith("repeat"):
        trace=subprocess.Popen(["sudo","strace","-ff","-tt","-T","-s","4096","-e","trace=poll,ppoll,sendmsg,recvmsg,connect","-p",str(app.pid),"-o",str(out/(label+"-strace"))],stdout=open(out/(label+"-trace-launch.txt"),"w"),stderr=subprocess.STDOUT)
        time.sleep(1)
    click_word("Text",label+"-before")
    start=time.monotonic(); log("text-open",case=label)
    run("xdotool","type","--clearmodifiers","--delay","60",label+" typed control")
    for second in [0,1,3,10,20,35,50]:
        time.sleep(max(0,start+second-time.monotonic())); snap(label+"-"+str(second))
        proc=run("ps","-eLo","pid,tid,stat,pcpu,wchan:32,comm").stdout
        focus=run("xdotool","getwindowfocus","getwindowname").stdout
        (out/(label+"-"+str(second)+"-state.txt")).write_text(proc+"\nFOCUS\n"+focus)
    if trace:
        run("sudo","kill","-INT",str(trace.pid))
    run("xdotool","key","Escape"); time.sleep(2)
log("start")
app=subprocess.Popen(["localsend_app"],stdout=open(out/"app.log","w"),stderr=subprocess.STDOUT)
time.sleep(15)
log("app",pid=app.pid)
(out/"initial-keyboard-settings.txt").write_text(run("gsettings","list-recursively","org.cinnamon.desktop.a11y.applications").stdout)
# Maximize the actual app window through the window manager.
w=run("xdotool","search","--onlyvisible","--name","LocalSend").stdout.splitlines()
if not w: raise RuntimeError("LocalSend visible window absent")
run("xdotool","windowactivate","--sync",w[-1]); run("xdotool","windowsize",w[-1],"1100","700")
time.sleep(3); snap("app-ready")
click_word("Send","send"); time.sleep(2)
text_case("keyboard-off")
# Paste is a real application action, with clipboard content set by xclip.
subprocess.run(["xclip","-selection","clipboard"],input=b"Paste control issue2754",check=True)
click_word("Paste","paste-before"); time.sleep(3); snap("paste-result")
# Keep the same application process and graphical login while changing a supported UI setting.
settings=subprocess.Popen(["cinnamon-settings","accessibility"],stdout=open(out/"accessibility.log","w"),stderr=subprocess.STDOUT)
time.sleep(6); snap("accessibility-start")
click_word("Keyboard","accessibility-keyboard-tab"); time.sleep(2)
rows=snap("accessibility-keyboard")
# Cinnamon Accessibility keyboard row has a switch at the right of its label.
hits=[r for r in rows if r["text"].lower()=="on-screen"]
if not hits: raise RuntimeError("Supported virtual keyboard row not located; inspect screenshot")
r=hits[0]; y=int(r["top"])+int(r["height"])//2
wid=run("xdotool","getwindowfocus").stdout.strip(); geo=run("xdotool","getwindowgeometry","--shell",wid).stdout
vals=dict(line.split("=",1) for line in geo.splitlines() if "=" in line)
x=int(vals["X"])+int(vals["WIDTH"])-55
log("keyboard-toggle-ui",x=x,y=y); run("xdotool","mousemove",str(x),str(y),"click","1"); time.sleep(4)
snap("accessibility-after-toggle")
(out/"keyboard-settings.txt").write_text(run("gsettings","list-recursively","org.cinnamon.desktop.a11y.applications").stdout)
state=run("gsettings","get","org.cinnamon.desktop.a11y.applications","screen-keyboard-enabled").stdout.strip()
if state != "true": raise RuntimeError("UI did not enable supported virtual keyboard: "+state)
run("xdotool","windowactivate","--sync",w[-1]); time.sleep(2)
text_case("keyboard-on")
text_case("keyboard-on-repeat")
# Return the supported setting through the same UI, then repeat the original trigger.
run("xdotool","windowactivate","--sync",wid); time.sleep(2)
run("xdotool","mousemove",str(x),str(y),"click","1"); time.sleep(3)
(out/"keyboard-disabled-again.txt").write_text(run("gsettings","get","org.cinnamon.desktop.a11y.applications","screen-keyboard-enabled").stdout)
if run("gsettings","get","org.cinnamon.desktop.a11y.applications","screen-keyboard-enabled").stdout.strip() != "false":
    raise RuntimeError("UI failed to restore virtual keyboard setting")
run("xdotool","windowactivate","--sync",w[-1]); time.sleep(2)
text_case("keyboard-off-again")
log("completed")
