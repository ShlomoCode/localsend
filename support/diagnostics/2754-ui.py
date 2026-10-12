import subprocess, time, pathlib, json, csv, io, os, re
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
def saved_frame_crop(name,suffix,left,top,width,height,scale,psm,execute=run):
    source=out/(name+".png")
    with source.open("rb") as saved_frame:
        header=saved_frame.read(24)
    if len(header)!=24 or header[:8]!=b"\x89PNG\r\n\x1a\n" or header[12:16]!=b"IHDR":
        raise RuntimeError("Saved frame has no valid PNG dimensions: "+name)
    image_width=int.from_bytes(header[16:20],"big"); image_height=int.from_bytes(header[20:24],"big")
    if not (left>=0 and top>=0 and width>0 and height>0
            and left+width<=image_width and top+height<=image_height):
        raise RuntimeError("Crop outside saved frame: "+name+suffix)
    crop=out/(name+suffix+".png")
    cropped=execute("ffmpeg","-nostdin","-v","error","-y","-i",str(source),
                "-vf",f"crop={width}:{height}:{left}:{top},scale={width*scale}:{height*scale}:flags=lanczos",
                "-frames:v","1",str(crop))
    crop.with_suffix(".ffmpeg.stderr").write_text(cropped.stderr)
    if cropped.returncode!=0: raise RuntimeError("Saved-frame crop failed: "+name+suffix)
    result=execute("tesseract",str(crop),"stdout","--psm",str(psm),"tsv")
    crop.with_suffix(".tsv").write_text(result.stdout)
    crop.with_suffix(".tesseract.stderr").write_text(result.stderr)
    if result.returncode!=0: raise RuntimeError("Saved-frame OCR failed: "+name+suffix)
    return list(csv.DictReader(io.StringIO(result.stdout),delimiter="\t"))
def native_geometry_calibration():
    phase=out/"native-geometry-calibration"; phase.mkdir(exist_ok=True)
    deadline=time.monotonic()+60
    status=dict(status="started",controls_admitted=False,policy_admitted=False,pixel_mapping_review_required=True,
                app_pid=app.pid,window_id=w[-1],horizontal_requests=0,phase_bound_seconds=60)
    process_start=pathlib.Path(f"/proc/{app.pid}/stat").read_text().rsplit(") ",1)[1].split()[19]
    process_exe=os.readlink(f"/proc/{app.pid}/exe")
    def execute(name,*args,limit=deadline):
        remaining=limit-time.monotonic()
        if remaining<=0: raise RuntimeError("Native geometry calibration deadline reached")
        result=run(*args,timeout=min(15,remaining),env=dict(os.environ,LC_ALL="C"))
        (phase/(name+".stdout")).write_text(result.stdout)
        (phase/(name+".stderr")).write_text(result.stderr)
        (phase/(name+".command.json")).write_text(json.dumps(dict(command=list(args),returncode=result.returncode)))
        if result.returncode!=0: raise RuntimeError("Native calibration command failed: "+name)
        return result.stdout
    def identity():
        if (app.poll() is not None or os.readlink(f"/proc/{app.pid}/exe")!=process_exe or
                pathlib.Path(f"/proc/{app.pid}/stat").read_text().rsplit(") ",1)[1].split()[19]!=process_start):
            raise RuntimeError("Original calibration app identity changed")
    def window(name,identifier,limit):
        raw=execute(name,"xwininfo","-id",str(identifier),"-stats","-tree",limit=limit)
        def number(label):
            hit=re.search(r"^\s*"+re.escape(label)+r":\s*(-?\d+)\s*$",raw,re.M)
            if hit is None: raise RuntimeError("Native window field absent: "+label)
            return int(hit[1])
        def xid(label):
            hit=re.search(re.escape(label)+r":\s*(0x[0-9a-fA-F]+)",raw)
            if hit is None: raise RuntimeError("Native window identity absent: "+label)
            return int(hit[1],16)
        state=re.search(r"^\s*Map State:\s*(\S+)\s*$",raw,re.M)
        if state is None: raise RuntimeError("Native map state absent")
        return dict(id=xid("Window id"),root=xid("Root window id"),parent=xid("Parent window id"),
                    x=number("Absolute upper-left X"),y=number("Absolute upper-left Y"),
                    relative_x=number("Relative upper-left X"),relative_y=number("Relative upper-left Y"),
                    width=number("Width"),height=number("Height"),border=number("Border width"),map_state=state[1])
    def snapshot(name,limit):
        identity()
        if execute(name+"-display","xdotool","getdisplaygeometry",limit=limit).strip()!="1280 800":
            raise RuntimeError("Calibration display changed")
        owner=execute(name+"-owner","xprop","-id",w[-1],"_NET_WM_PID",limit=limit)
        owner_hit=re.search(r"_NET_WM_PID\(CARDINAL\)\s*=\s*(\d+)",owner)
        if owner_hit is None or int(owner_hit[1])!=app.pid: raise RuntimeError("Native client PID differs from original app")
        # Retain the getter's inconsistent point for comparison only; native
        # xwininfo absolute coordinates remain the calibration authority.
        execute(name+"-xdotool-diagnostic","xdotool","getwindowgeometry","--shell",w[-1],limit=limit)
        properties=execute(name+"-client-properties","xprop","-id",w[-1],"_NET_FRAME_EXTENTS","_GTK_FRAME_EXTENTS",
                           "WM_STATE","_NET_WM_STATE","WM_NAME","_NET_WM_NAME",limit=limit)
        extents={}
        for label in ("_NET_FRAME_EXTENTS","_GTK_FRAME_EXTENTS"):
            lines=[line.strip() for line in properties.splitlines()
                   if re.match(r"^"+re.escape(label)+r"(?:\(|:|\s|$)",line.strip())]
            if len(lines)!=1: raise RuntimeError("Native frame property line missing or duplicated: "+label)
            line=lines[0]
            if re.fullmatch(re.escape(label)+r":\s*(?:not found|no such atom on any window)\.?",line):
                extents[label]=dict(status="absent",values=None)
                continue
            match=re.fullmatch(re.escape(label)+r"\(CARDINAL\)\s*=\s*([0-9]+\s*,\s*[0-9]+\s*,\s*[0-9]+\s*,\s*[0-9]+)",line)
            if match is None: raise RuntimeError("Native frame extents type or values malformed: "+label)
            extents[label]=dict(status="present",values=[int(value.strip()) for value in match[1].split(",")])
        chain=[]; identifier=int(w[-1]); seen=set()
        for depth in range(8):
            if identifier in seen: raise RuntimeError("Native parent chain repeats")
            seen.add(identifier)
            node=window(name+"-window-"+str(depth),identifier,limit); chain.append(node)
            if node["id"]!=identifier: raise RuntimeError("Native queried window identity mismatch")
            if node["id"]==node["root"]: break
            identifier=node["parent"]
        else: raise RuntimeError("Native parent chain did not reach root")
        if any(node["root"]!=chain[0]["root"] or node["map_state"]!="IsViewable" for node in chain):
            raise RuntimeError("Native chain root/map state is inconsistent")
        client=chain[0]; frame=chain[-2] if len(chain)>1 else client
        keyboard_state=execute(name+"-keyboard","gsettings","get","org.cinnamon.desktop.a11y.applications",
                               "screen-keyboard-enabled",limit=limit).strip()
        if keyboard_state not in ("true","false"): raise RuntimeError("Supported keyboard state unavailable")
        result=dict(client=client,frame=frame,parent_chain=chain,extents=extents,client_properties=properties,
                    process_start=process_start,process_exe=process_exe,keyboard_state=keyboard_state,
                    keyboard_top=287 if keyboard_state=="true" else 0)
        (phase/(name+".json")).write_text(json.dumps(result,indent=2))
        return result
    def settled(label,limit):
        previous=None; stable=0; attempt=0
        while time.monotonic()<limit:
            name=label+"-"+str(attempt)
            before=snapshot(name+"-A",limit)
            execute(name+"-screenshot","scrot",str(phase/(name+"-original.png")),limit=limit)
            header=(phase/(name+"-original.png")).read_bytes()[:24]
            if (len(header)!=24 or header[:8]!=b"\x89PNG\r\n\x1a\n" or header[12:16]!=b"IHDR"
                    or int.from_bytes(header[16:20],"big")!=1280 or int.from_bytes(header[20:24],"big")!=800):
                raise RuntimeError("Calibration original screenshot dimensions differ from native display")
            after=snapshot(name+"-B",limit)
            matching=(before==after and after["client"]["width"]==1100 and after["client"]["height"]==700)
            stable=stable+1 if matching and previous==after else 1 if matching else 0
            with (phase/"triplets.jsonl").open("a") as records:
                records.write(json.dumps(dict(name=name,wall=time.time(),native_brackets_equal=before==after,
                    stable_native_triplets=stable,original_png=name+"-original.png",pixels_review_required=True))+"\n")
            if stable>=2: return after
            previous=after if matching else None; attempt+=1
            if limit-time.monotonic()>0.25: time.sleep(0.25)
        raise RuntimeError("No two consecutive stable native capture triplets: "+label)
    try:
        if (out.resolve()!=pathlib.Path("/home/mint/evidence") or not (out/"bootstrap-complete").is_file()
                or "ID=linuxmint" not in pathlib.Path("/etc/os-release").read_text().splitlines()
                or any(os.environ.get(flag,"0")!="0" for flag in ("PROBE_CAPTURE_GEOMETRY","PROBE_CAPTURE_INTERACTIONS",
                     "PROBE_CAPTURE_ROOT_NAME_EVIDENCE","PROBE_OBSERVER_POLICY_DISCRIMINATOR"))):
            raise RuntimeError("Calibration requires exclusive staged Mint geometry-only scope")
        execute("tool-versions","dpkg-query","-W","x11-utils","wmctrl","xdotool")
        supported=execute("root-supported","xprop","-root","_NET_SUPPORTED")
        supported_lines=[line.strip() for line in supported.splitlines()
                         if re.match(r"^_NET_SUPPORTED(?:\(|:|\s|$)",line.strip())]
        if len(supported_lines)!=1: raise RuntimeError("Root supported property line missing or duplicated")
        supported_match=re.fullmatch(r"_NET_SUPPORTED\(ATOM\)\s*=\s*(\S.*)",supported_lines[0])
        if supported_match is None: raise RuntimeError("Root supported property is not an explicit ATOM list")
        supported_atoms=[atom.strip() for atom in supported_match[1].split(",")]
        if any(re.fullmatch(r"[^\s,]+",atom) is None for atom in supported_atoms):
            raise RuntimeError("Root supported ATOM list is malformed")
        if "_NET_MOVERESIZE_WINDOW" not in supported_atoms:
            raise RuntimeError("Window manager does not advertise X-only EWMH movement")
        execute("initial-size","xdotool","windowsize",w[-1],"1100","700")
        before=settled("before-move",deadline-15)
        command=["wmctrl","-i","-r",w[-1],"-e","0,60,-1,-1,-1"]
        log("native-geometry-horizontal-input",case="native-geometry-horizontal",command=command,
            stable_native_before=before,controls_admitted=False,policy_admitted=False,pixels_review_required=True)
        move_wall=time.time(); status["horizontal_requests"]=1
        execute("horizontal-request",*command,limit=deadline-12)
        after=settled("after-move",deadline-2)
        # Preserve true native Y and size, including the outer frame. No
        # xdotool getter-derived point, fixed X result or border formula gate.
        if any(before[target][key]!=after[target][key] for target in ("client","frame")
               for key in ("id","root","y","width","height","border")):
            raise RuntimeError("Actual client/frame Y, size or identity changed after X-only request")
        if before["extents"]!=after["extents"] or before["keyboard_top"]!=after["keyboard_top"]:
            raise RuntimeError("Frame extents or keyboard condition changed during calibration")
        status.update(status="stable-native-pixels-review-required",before=before,after=after,
                      horizontal_native_change=before["client"]["x"]!=after["client"]["x"])
    except Exception as error:
        status.update(status="calibration-failed",error=type(error).__name__+": "+str(error))
    finally:
        # Reserve the real post-request tail for the existing ten-second clip.
        if status["horizontal_requests"]:
            remaining_tail=move_wall+9.25-time.time()
            if remaining_tail>0:
                if time.monotonic()+remaining_tail>deadline:
                    status.update(status="calibration-failed",error="Post-request recording tail exceeds fixed phase bound")
                else: time.sleep(remaining_tail)
        (phase/"result.json").write_text(json.dumps(status,indent=2))
        log("native-geometry-calibration-ended",**status)
    return status["status"]=="stable-native-pixels-review-required"
def keyboard_top(execute=run):
    state=execute("gsettings","get","org.cinnamon.desktop.a11y.applications","screen-keyboard-enabled").stdout.strip()
    if state not in ("true","false"): raise RuntimeError("Supported keyboard setting unavailable")
    # Retained native keyboard occupies y=0..287 when enabled; panel starts759.
    return 287 if state=="true" else 0
def window_geometry(name,execute=run):
    display=execute("xdotool","getdisplaygeometry").stdout.strip()
    owner=execute("xdotool","getwindowpid",w[-1]).stdout.strip()
    title=execute("xdotool","getwindowname",w[-1]).stdout.strip()
    raw=execute("xdotool","getwindowgeometry","--shell",w[-1]).stdout
    (out/(name+"-window.txt")).write_text(raw+"\nDISPLAY="+display+"\nPID="+owner+"\nTITLE="+title+"\n")
    values=dict(line.split("=",1) for line in raw.splitlines() if "=" in line)
    geometry={key:int(values[key]) for key in ("X","Y","WIDTH","HEIGHT","SCREEN")}
    geometry["KEYBOARD_TOP"]=keyboard_top(execute)
    if display!="1280 800" or owner!=str(app.pid) or title!="LocalSend":
        raise RuntimeError("Viewport gate requires original LocalSend and unchanged 1280x800 display")
    log("window-geometry",case=name,window_id=w[-1],owner_pid=owner,display=display,geometry=geometry)
    return geometry
def normalize_window(name):
    before=window_geometry(name+"-before")
    snap(name+"-original-screen")
    # Correct horizontal clipping only. Relative WM movement preserves actual
    # client Y without assuming a decoration/frame offset or changing size.
    if before["X"]!=60:
        command=("xdotool","windowmove","--sync","--relative",w[-1],str(60-before["X"]),"0")
        result=run(*command)
        log("viewport-wm-input",case=name,command=list(command),returncode=result.returncode)
        if result.returncode!=0: raise RuntimeError("Supported WM normalization failed")
    time.sleep(1)
    after=window_geometry(name+"-after")
    snap(name+"-normalized-screen")
    if not (after["X"]==60 and after["WIDTH"]==1100 and after["HEIGHT"]==700
            and all(after[key]==before[key] for key in ("Y","WIDTH","HEIGHT","SCREEN","KEYBOARD_TOP"))):
        raise RuntimeError("Horizontal WM normalization changed actual Y/size/screen/keyboard condition")
def saved_client_crop(name,suffix,geometry):
    # A 700px client can extend below the screenshot after keyboard activation.
    # Clip only this broad sampling region; required targets still need full bounds.
    header=(out/(name+".png")).read_bytes()[:24]
    if len(header)!=24 or header[:8]!=b"\x89PNG\r\n\x1a\n" or header[12:16]!=b"IHDR":
        raise RuntimeError("Saved client frame has no valid PNG dimensions")
    image_width=int.from_bytes(header[16:20],"big"); image_height=int.from_bytes(header[20:24],"big")
    left=max(0,geometry["X"]); top=max(0,geometry["Y"])
    right=min(image_width,geometry["X"]+geometry["WIDTH"])
    bottom=min(image_height,geometry["Y"]+geometry["HEIGHT"])
    log("saved-client-sampling-bounds",case=name,crop=dict(left=left,top=top,right=right,bottom=bottom),geometry=geometry)
    return saved_frame_crop(name,suffix,left,top,right-left,bottom-top,2,11)
def original_focus(name,execute=run):
    focused=execute("xdotool","getwindowfocus").stdout.strip()
    owner=execute("xdotool","getwindowpid",focused).stdout.strip()
    title=execute("xdotool","getwindowname",focused).stdout.strip()
    log("original-focus",case=name,window_id=focused,owner_pid=owner,title=title)
    if focused!=w[-1] or owner!=str(app.pid) or title!="LocalSend" or app.poll() is not None:
        raise RuntimeError("Actual input requires focused original LocalSend window")
def target_visible(name,label,row,geometry):
    left=int(row["left"]); top=int(row["top"])
    right=left+int(row["width"]); bottom=top+int(row["height"])
    visible=(geometry["X"]<=left<right<=geometry["X"]+geometry["WIDTH"] and
             geometry["Y"]<=top<bottom<=geometry["Y"]+geometry["HEIGHT"] and
             0<=left<right<=1280 and geometry["KEYBOARD_TOP"]<=top<bottom<=759)
    log("rendered-target-bounds",case=name,label=label,bounds=dict(left=left,top=top,right=right,bottom=bottom),
        geometry=geometry,visible=visible)
    if not visible: raise RuntimeError("Required rendered target is occluded/outside original client: "+label)
def exact_visible_label(name,label,rows,geometry):
    hits=[r for r in rows if r["text"].lower().strip()==label.lower() and float(r["conf"])>=90]
    unique=[]
    for hit in hits:
        center=(int(hit["left"])+int(hit["width"])/2,int(hit["top"])+int(hit["height"])/2)
        if not any(abs(center[0]-(int(r["left"])+int(r["width"])/2))<=4 and
                   abs(center[1]-(int(r["top"])+int(r["height"])/2))<=4 for r in unique): unique.append(hit)
    if len(unique)!=1: raise RuntimeError("Required exact confident rendered label is absent/ambiguous: "+label)
    target_visible(name,label,unique[0],geometry)
    return unique[0]
def baseline_modal(name,rows):
    geometry=window_geometry(name+"-modal")
    title=exact_visible_label(name,"Type",rows,geometry)
    exact_visible_label(name,"message",rows,geometry)
    # Retained keyboard-on-stack-65 expands the dialog to ~338px for its
    # typed control; a 280px sample cuts the actual Confirm label in half.
    header=(out/(name+".png")).read_bytes()[:24]
    if len(header)!=24 or header[:8]!=b"\x89PNG\r\n\x1a\n" or header[12:16]!=b"IHDR":
        raise RuntimeError("Saved baseline modal frame has no valid PNG dimensions")
    image_width=int.from_bytes(header[16:20],"big"); image_height=int.from_bytes(header[20:24],"big")
    requested_left=int(title["left"])-24; requested_top=int(title["top"])-32
    left=max(0,requested_left); top=max(0,requested_top)
    right=min(image_width,requested_left+360); bottom=min(image_height,requested_top+190)
    log("baseline-modal-sampling-bounds",case=name,requested=dict(left=requested_left,top=requested_top,width=360,height=190),
        crop=dict(left=left,top=top,right=right,bottom=bottom))
    cropped=saved_frame_crop(name,"-modal-controls",left,top,right-left,bottom-top,2,6)
    converted=[]
    for row in cropped:
        hit=dict(row)
        for key,origin in (("left",left),("top",top),("width",0),("height",0)):
            hit[key]=str(round(origin+int(hit[key])/2))
        converted.append(hit)
    for label in ("Type","message","typed","Cancel","Confirm"):
        exact_visible_label(name,label,rows+converted,geometry)
    original_focus(name+"-modal")
def picker_text(name,rows):
    selections=[r for r in rows if r["text"].lower().strip()=="selection"]
    if len(selections)!=1 or float(selections[0]["conf"])<90:
        raise RuntimeError("Picker requires unique confident Selection heading: "+name)
    hits=[r for r in rows if r["text"].lower().strip()=="text"]
    if len(hits)==1 and float(hits[0]["conf"])>=90: return hits[0]
    if hits: raise RuntimeError("Picker Text label is ambiguous or unconfident: "+name)
    left=int(selections[0]["left"])-8; top=int(selections[0]["top"])+24
    cropped=saved_frame_crop(name,"-exact-text-picker",left,top,460,80,3,11)
    hits=[r for r in cropped if r["text"].lower().strip()=="text"]
    if len(hits)!=1 or float(hits[0]["conf"])<90:
        raise RuntimeError("Saved picker requires unique exact confident Text label: "+name)
    hit=dict(hits[0])
    for key,origin in (("left",left),("top",top),("width",0),("height",0)):
        hit[key]=str(round(origin+int(hit[key])/3))
    log("exact-text-picker",file=name+".png",crop=name+"-exact-text-picker.png",hit=hit)
    return hit
def clear_paste(name):
    normalize_window(name+"-viewport")
    rows=snap(name+"-before")
    geometry=window_geometry(name+"-clear")
    original_focus(name+"-clear")
    selections=[r for r in rows if r["text"].lower().strip()=="selection"]
    if len(selections)!=1 or float(selections[0]["conf"])<90:
        raise RuntimeError("Clear requires unique confident Selection heading")
    selection=selections[0]
    # Original paste-clear-before.png renders a 14x16 close glyph near the
    # right end of this header. Search pixels; never click an anchor offset.
    left=int(selection["left"])+400; top=int(selection["top"])-12
    glyphs=saved_frame_crop(name+"-before","-close-search",left,top,140,40,4,6)
    hits=[r for r in glyphs if r["text"].lower().strip() in ("x","×")]
    if (len(hits)!=1 or float(hits[0]["conf"])<90 or not
            (8<=int(hits[0]["width"])/4<=24 and 8<=int(hits[0]["height"])/4<=24)):
        raise RuntimeError("Rendered close glyph is absent, ambiguous, or unconfident; no click")
    hit=hits[0]
    glyph_left=left+int(hit["left"])/4; glyph_top=top+int(hit["top"])/4
    glyph_right=glyph_left+int(hit["width"])/4; glyph_bottom=glyph_top+int(hit["height"])/4
    x=round(left+(int(hit["left"])+int(hit["width"])/2)/4)
    y=round(top+(int(hit["top"])+int(hit["height"])/2)/4)
    if not (geometry["X"]<=glyph_left<glyph_right<=geometry["X"]+geometry["WIDTH"] and
            geometry["Y"]<=glyph_top<glyph_bottom<=geometry["Y"]+geometry["HEIGHT"]
            and 0<=glyph_left<glyph_right<=1280 and geometry["KEYBOARD_TOP"]<=glyph_top<glyph_bottom<=759):
        raise RuntimeError("Rendered close glyph outside original visible client")
    original_focus(name+"-clear-input")
    if window_geometry(name+"-clear-input")!=geometry:
        raise RuntimeError("Original window moved after saved close-glyph evidence; no click")
    log("clear-paste-ui",case=name,x=x,y=y,glyph=hit,source=name+"-before.png",crop=name+"-before-close-search.png")
    run("xdotool","mousemove",str(x),str(y),"click","1"); time.sleep(2)
    cleared=snap(name+"-cleared")
    geometry=window_geometry(name+"-cleared")
    target_visible(name+"-cleared","Text",picker_text(name+"-cleared",cleared),geometry)
def click_word(word,name):
    if word.lower() in ("text","file","folder","paste"): normalize_window(name+"-viewport")
    rows=snap(name)
    hits=[r for r in rows if r["text"].lower().strip()==word.lower()]
    if word.lower() in ("folder","paste"):
        control=word.lower()
        focused=run("xdotool","getwindowfocus").stdout.strip()
        title=run("xdotool","getwindowname",focused).stdout.strip()
        owner=run("xdotool","getwindowpid",focused).stdout.strip()
        if title!="LocalSend" or owner!=str(app.pid):
            raise RuntimeError(word+" opener requires focused original LocalSend: "+name)
        selections=[r for r in rows if r["text"].lower().strip()=="selection"]
        if len(selections)!=1 or float(selections[0]["conf"])<90:
            raise RuntimeError(word+" opener requires unique confident Selection heading: "+name)
        selection=selections[0]
        # A dimmed picker remains readable behind MessageInputDialog. Read the
        # saved visible client and retain every original positive modal label.
        geometry=window_geometry(name+"-modal-gate")
        modal_rows=saved_client_crop(name,"-"+control+"-modal-gate",geometry)
        modal_labels={r["text"].lower().strip() for r in rows+modal_rows}
        previous_modal={"type","message"}.issubset(modal_labels)
        log(control+"-modal-gate",previous_modal=previous_modal,window_id=focused,owner_pid=owner)
        if previous_modal: raise RuntimeError("Previous Text dialog visible before "+word+" trigger: "+name)
        if not hits:
            left=int(selection["left"])-8; top=int(selection["top"])+24
            picker_rows=saved_frame_crop(name,"-"+control+"-picker",left,top,460,80,3,11)
            hits=[r for r in picker_rows if r["text"].lower().strip()==control]
            if len(hits)!=1 or float(hits[0]["conf"])<90:
                raise RuntimeError(word+" fallback requires unique exact confident label: "+name)
            hit=hits[0]
            x=round(left+(int(hit["left"])+int(hit["width"])/2)/3)
            y=round(top+(int(hit["top"])+int(hit["height"])/2)/3)
            log(control+"-picker-ocr-fallback",x=x,y=y,confidence=hit["conf"],crop_x=left,crop_y=top,scale=3)
            hits=[dict(left=str(round(left+int(hit["left"])/3)),top=str(round(top+int(hit["top"])/3)),
                       width=str(round(int(hit["width"])/3)),height=str(round(int(hit["height"])/3)),text=word,conf=hit["conf"])]
        elif len(hits)!=1 or float(hits[0]["conf"])<90:
            raise RuntimeError(word+" opener requires unique exact confident label: "+name)
    if word.lower()=="text": hits=[picker_text(name,rows)]
    if not hits: raise RuntimeError("Missing UI label "+word+" in "+name)
    r=hits[0]; x=int(r["left"])+int(r["width"])//2; y=int(r["top"])+int(r["height"])//2
    if word.lower()=="text":
        geometry=window_geometry(name+"-modal-gate")
        modal_rows=saved_client_crop(name,"-modal-gate",geometry)
        labels={r["text"].lower().strip() for r in rows+modal_rows}
        log("fresh-text-gate",file=name+"-modal-gate.png",previous_modal={"type","message"}.issubset(labels))
        if {"type","message"}.issubset(labels):
            raise RuntimeError("Previous Text dialog still visible before fresh trigger: "+name)
    if word.lower() in ("send","text","file","folder","paste"):
        original_focus(name)
        target_visible(name,word,r,window_geometry(name+"-target"))
    log("click",label=word,x=x,y=y); run("xdotool","mousemove",str(x),str(y),"click","1")
def text_case(label):
    trace=None
    if label.endswith("repeat"):
        trace=subprocess.Popen(["sudo","strace","-ff","-tt","-T","-s","4096","-e","trace=poll,ppoll,sendmsg,recvmsg,connect","-p",str(app.pid),"-o",str(out/(label+"-strace"))],stdout=open(out/(label+"-trace-launch.txt"),"w"),stderr=subprocess.STDOUT)
        time.sleep(1)
    click_word("Text",label+"-before")
    start=time.monotonic(); log("text-open",case=label)
    log("text-input",case=label,text=label+" typed control",delay_ms=60)
    run("xdotool","type","--clearmodifiers","--delay","60",label+" typed control")
    for second in [0,1,3,10,20,35,50,65]:
        time.sleep(max(0,start+second-time.monotonic())); rows=snap(label+"-"+str(second))
        proc=run("ps","-eLo","pid,tid,stat,pcpu,wchan:32,comm").stdout
        focus=run("xdotool","getwindowfocus","getwindowname").stdout
        (out/(label+"-"+str(second)+"-state.txt")).write_text(proc+"\nFOCUS\n"+focus)
        if label.endswith("stack") and second==10:
            stack=run("sudo","gdb","-q","-batch","-p",str(app.pid),"-ex","thread apply all bt 20")
            (out/(label+"-gdb.txt")).write_text(stack.stdout+stack.stderr)
    if trace:
        run("sudo","kill","-INT",str(trace.pid))
    # Validate saved final native controls after the original timing samples,
    # before dismissal and before permitting the policy experiment to start.
    baseline_modal(label+"-65",rows)
    log("text-dismiss-input",case=label,key="Escape")
    run("xdotool","key","Escape"); time.sleep(2)
def picker_control(word,label):
    # Open and cancel the actual chooser in the same process/keyboard setting.
    click_word(word,label+"-before")
    start=time.monotonic(); deadline=start+10
    observed=False; attempt=0; cancel_point=None
    while time.monotonic()<deadline:
        frame=label+"-chooser-"+str(attempt)
        rows=snap(frame)
        focused=run("xdotool","getwindowfocus").stdout.strip()
        title=run("xdotool","getwindowname",focused).stdout.strip()
        owner=run("xdotool","getwindowpid",focused).stdout.strip()
        # Pinned file_selector_linux 0.9.4 uses Open for both native actions;
        # getDirectoryPath() without an override titles Folder Choose Directory.
        action="open"
        titles=("open file",) if word=="File" else ("choose directory",)
        # The retained Mint cohort uses an in-process GTK chooser. A portal
        # owned by another process would need a separate provenance gate.
        if owner.isdigit() and int(owner)==app.pid and title.lower() in titles:
            geometry=run("xdotool","getwindowgeometry","--shell",focused).stdout
            (out/(frame+"-window.txt")).write_text(title+"\n"+geometry)
            values=dict(line.split("=",1) for line in geometry.splitlines() if "=" in line)
            wx=int(values["X"]); wy=int(values["Y"])
            ww=int(values["WIDTH"]); wh=int(values["HEIGHT"])
            anchors=[r for r in rows if r["text"].lower().strip()==action
                     and wx+ww/2 <= int(r["left"]) < wx+ww
                     and wy+wh/2 <= int(r["top"]) < wy+wh]
            if len(anchors)==1:
                anchor=anchors[0]
                # Native Y+HEIGHT included the panel in run 38167982047.
                # Use the rendered action baseline in the SAME saved frame.
                # These paddings passed all nine retained positive frames and
                # six adjacent/non-dialog negatives; Folder still needs cloud UI validation.
                left=int(anchor["left"])-111; top=int(anchor["top"])-5
                width=int(anchor["width"])+129; height=int(anchor["height"])+11
                with (out/(frame+".png")).open("rb") as saved_frame:
                    header=saved_frame.read(24)
                if len(header)!=24 or header[:8]!=b"\x89PNG\r\n\x1a\n" or header[12:16]!=b"IHDR":
                    raise RuntimeError("Saved chooser frame has no valid PNG dimensions: "+frame)
                image_width=int.from_bytes(header[16:20],"big"); image_height=int.from_bytes(header[20:24],"big")
                # FFmpeg can clamp an out-of-frame crop and shift its origin.
                # Reject it instead of mapping clicks from the requested origin.
                if not (left>=0 and top>=0 and width>0 and height>0
                        and left+width<=image_width and top+height<=image_height):
                    log("chooser-button-crop-out-of-bounds",case=label,x=left,y=top,width=width,height=height,
                        image_width=image_width,image_height=image_height)
                    attempt+=1; time.sleep(1); continue
                crop=out/(frame+"-buttons.png")
                cropped=run("ffmpeg","-nostdin","-v","error","-y","-i",str(out/(frame+".png")),
                            "-vf",f"crop={width}:{height}:{left}:{top},scale={width*3}:{height*3}:flags=lanczos",
                            "-frames:v","1",str(crop))
                (out/(frame+"-buttons-ffmpeg.stderr")).write_text(cropped.stderr)
                result=run("tesseract",str(crop),"stdout","--psm","7","tsv") if cropped.returncode==0 else None
                if result is not None:
                    crop.with_suffix(".tsv").write_text(result.stdout)
                    (out/(frame+"-buttons-tesseract.stderr")).write_text(result.stderr)
                    button_rows=list(csv.DictReader(io.StringIO(result.stdout),delimiter="\t"))
                    cancels=[r for r in button_rows if r["text"].lower().strip()=="cancel"]
                    actions=[r for r in button_rows if r["text"].lower().strip()==action]
                    log("chooser-button-ocr",case=label,window_id=focused,window_title=title,owner_pid=owner,
                        file=crop.name,anchor=anchor,crop=dict(x=left,y=top,width=width,height=height,scale=3),
                        crop_returncode=cropped.returncode,ocr_returncode=result.returncode,words=button_rows)
                    if (result.returncode==0 and len(cancels)==1 and len(actions)==1
                            and float(cancels[0]["conf"])>=90 and float(actions[0]["conf"])>=90):
                        cancel=cancels[0]
                        for button_label,button in (("Cancel",cancel),("Open",actions[0])):
                            rendered=dict(button)
                            for key,origin in (("left",left),("top",top),("width",0),("height",0)):
                                rendered[key]=str(round(origin+int(button[key])/3))
                            target_visible(frame,button_label,rendered,dict(X=wx,Y=wy,WIDTH=ww,HEIGHT=wh,KEYBOARD_TOP=keyboard_top()))
                        cancel_point=(round(left+(int(cancel["left"])+int(cancel["width"])/2)/3),
                                      round(top+(int(cancel["top"])+int(cancel["height"])/2)/3))
                        observed=True; break
                else:
                    log("chooser-button-crop-failed",case=label,returncode=cropped.returncode,file=crop.name)
        attempt+=1; time.sleep(1)
    log("picker-control",case=label,app_pid=app.pid,observed=observed,elapsed=time.monotonic()-start)
    if not observed: raise RuntimeError("Rendered chooser controls absent: "+label)
    if (run("xdotool","getwindowfocus").stdout.strip()!=focused or
            run("xdotool","getwindowpid",focused).stdout.strip()!=str(app.pid)):
        raise RuntimeError("Actual chooser Cancel requires original app-owned focused chooser")
    x,y=cancel_point
    log("click",label="Cancel",case=label,x=x,y=y)
    run("xdotool","mousemove",str(x),str(y),"click","1")
    time.sleep(2)
    rows=snap(label+"-returned")
    returned_window=run("xdotool","getwindowfocus").stdout.strip()
    returned_pid=run("xdotool","getwindowpid",returned_window).stdout.strip()
    returned_title=run("xdotool","getwindowname",returned_window).stdout.strip()
    visible_choosers=run("xdotool","search","--onlyvisible","--name","^"+title+"$").stdout.splitlines()
    log("picker-control-return",case=label,chooser_window=focused,visible_chooser_windows=visible_choosers,
        returned_window=returned_window,returned_pid=returned_pid,returned_title=returned_title)
    if (focused in visible_choosers or returned_pid!=str(app.pid) or returned_title!="LocalSend"
            or not any(r["text"].lower().strip()=="selection" for r in rows)):
        raise RuntimeError("Chooser cancel did not return to rendered Send page: "+label)
def capture_observer_policy_phase():
    phase=out/"observer-policy"; phase.mkdir(exist_ok=True)
    status=dict(status="started",app_pid=app.pid,window_id=w[-1],native_baseline_during_wait=False)
    capture=None
    # All WM setup and baseline controls are complete. Never move or resize
    # either arm, including while the baseline observer is unresolved.
    frozen_geometry=window_geometry("policy-geometry-freeze")
    snap("policy-geometry-freeze")
    if not (frozen_geometry["WIDTH"]==1100 and frozen_geometry["HEIGHT"]==700 and
            frozen_geometry["X"]==60 and frozen_geometry["KEYBOARD_TOP"]==287):
        raise RuntimeError("Policy freeze requires original 1100x700 with horizontal correction and enabled keyboard")
    log("policy-geometry-frozen",geometry=frozen_geometry,window_id=w[-1],app_pid=app.pid)
    original_start=pathlib.Path(f"/proc/{app.pid}/stat").read_text().rsplit(") ",1)[1].split()[19]
    original_exe=os.readlink(f"/proc/{app.pid}/exe")
    def app_detached():
        if app.poll() is not None: raise RuntimeError("Original app exited during policy observation")
        current_start=pathlib.Path(f"/proc/{app.pid}/stat").read_text().rsplit(") ",1)[1].split()[19]
        if current_start!=original_start or os.readlink(f"/proc/{app.pid}/exe")!=original_exe:
            raise RuntimeError("Original app identity changed during policy observation")
        tasks=list(pathlib.Path(f"/proc/{app.pid}/task").glob("*/status"))
        if not tasks: raise RuntimeError("Original app threads absent")
        for task in tasks:
            values=dict(line.split(":",1) for line in task.read_text().splitlines() if ":" in line)
            if values.get("TracerPid","").strip()!="0" or values.get("State","").strip().split()[0] in ("T","t","Z"):
                raise RuntimeError("Original app must be detached and running for native observation")
    def bounded_run(deadline,*args):
        remaining=deadline-time.monotonic()
        if remaining<=0: raise RuntimeError("Native policy observation deadline reached")
        result=run(*args,timeout=min(3,remaining))
        if result.returncode!=0: raise RuntimeError("Native policy command failed: "+args[0])
        return result
    def frame(name,deadline):
        app_detached()
        before=window_geometry(name+"-before-frame",execute=lambda *args: bounded_run(deadline,*args))
        if before!=frozen_geometry: raise RuntimeError("Policy client geometry changed after freeze")
        path=out/(name+".png")
        bounded_run(deadline,"scrot",str(path))
        result=bounded_run(deadline,"tesseract",str(path),"stdout","--psm","11","tsv")
        path.with_suffix(".tsv").write_text(result.stdout)
        rows=list(csv.DictReader(io.StringIO(result.stdout),delimiter="\t"))
        selections=[r for r in rows if r["text"].lower().strip()=="selection" and float(r["conf"])>=90]
        text_hits=[r for r in rows if r["text"].lower().strip()=="text" and float(r["conf"])>=90]
        modal_present=any(r["text"].lower().strip() in ("type","message","cancel","confirm","precheck","probecheck") for r in rows)
        if len(selections)==1 and not text_hits and not modal_present:
            # Full-frame OCR can truncate visible Text/Paste after the native
            # chooser shifts the window. Read the same saved picker region.
            left=int(selections[0]["left"])-8; top=int(selections[0]["top"])+24; scale=3
            picker_rows=saved_frame_crop(name,"-policy-picker",left,top,460,80,scale,11,
                                        execute=lambda *args: bounded_run(deadline,*args))
            hits=[r for r in picker_rows if r["text"].lower().strip()=="text" and float(r["conf"])>=90]
            if len(hits)!=1: raise RuntimeError("Policy picker requires unique exact confident Text label")
            hit=hits[0]
            hit["left"]=str(round(left+int(hit["left"])/scale)); hit["top"]=str(round(top+int(hit["top"])/scale))
            hit["width"]=str(round(int(hit["width"])/scale)); hit["height"]=str(round(int(hit["height"])/scale))
            rows=[r for r in rows if r["text"].lower().strip()!="text"]+[hit]
            log("policy-native-saved-picker-crop",file=path.name,x=left,y=top,width=460,height=80,scale=scale)
        titles=[r for r in rows if r["text"].lower().strip()=="type" and float(r["conf"])>=90]
        messages=[r for r in rows if r["text"].lower().strip()=="message" and float(r["conf"])>=90]
        if len(titles)==1 and len(messages)==1:
            title=titles[0]; message=messages[0]
            if all(title[key]==message[key] for key in ("block_num","par_num","line_num")):
                # Full-frame PSM11 omits the visible buttons beside the Mint
                # taskbar. Read the same saved modal, anchored to its title.
                left=int(title["left"])-24; top=int(title["top"])-32
                width=280; height=190; scale=2
                header=path.read_bytes()[:24]
                image_width=int.from_bytes(header[16:20],"big"); image_height=int.from_bytes(header[20:24],"big")
                if (header[:8]!=b"\x89PNG\r\n\x1a\n" or header[12:16]!=b"IHDR" or left<0 or top<0
                        or left+width>image_width or top+height>image_height):
                    raise RuntimeError("Native policy modal crop outside original saved frame")
                crop=out/(name+"-modal.png")
                bounded_run(deadline,"ffmpeg","-nostdin","-v","error","-y","-i",str(path),
                            "-vf",f"crop={width}:{height}:{left}:{top},scale={width*scale}:{height*scale}:flags=lanczos",
                            "-frames:v","1",str(crop))
                cropped=bounded_run(deadline,"tesseract",str(crop),"stdout","--psm","6","tsv")
                crop.with_suffix(".tsv").write_text(cropped.stdout)
                crop_rows=list(csv.DictReader(io.StringIO(cropped.stdout),delimiter="\t"))
                # Keep original positive title evidence so cropped OCR cannot
                # turn a still-visible modal into a dismissal. Use crop rows
                # for buttons/marker and root coordinates for real Cancel.
                # Preserve every positive original label; exact label gates
                # merge duplicate boxes from the two OCR views of one frame.
                for row in crop_rows:
                    row["left"]=str(round(left+int(row["left"])/scale))
                    row["top"]=str(round(top+int(row["top"])/scale))
                    row["width"]=str(round(int(row["width"])/scale))
                    row["height"]=str(round(int(row["height"])/scale))
                    rows.append(row)
                log("policy-native-saved-modal-crop",file=path.name,crop_file=crop.name,x=left,y=top,width=width,height=height,scale=scale)
        focus=bounded_run(deadline,"xdotool","getwindowfocus").stdout.strip()
        owner=bounded_run(deadline,"xdotool","getwindowpid",focus).stdout.strip()
        if owner!=str(app.pid) or focus!=w[-1]:
            raise RuntimeError("Native policy frame lost original LocalSend focus")
        after=window_geometry(name+"-after-frame",execute=lambda *args: bounded_run(deadline,*args))
        if after!=frozen_geometry: raise RuntimeError("Policy client geometry changed during saved frame")
        log("policy-native-frame",file=path.name,window_id=focus,owner_pid=owner)
        return rows
    def modal(rows,marker=None):
        labels={r["text"].lower().strip() for r in rows}
        if not {"type","message","cancel","confirm"}.issubset(labels):
            raise RuntimeError("Full native Text dialog and Cancel/Confirm must be visible")
        if marker and marker not in labels: raise RuntimeError("Native marker absent from saved pixels: "+marker)
        required=["type","message","cancel","confirm"]+([marker] if marker else [])
        controls={label:exact_visible_label("policy-modal",label,rows,frozen_geometry) for label in required}
        return controls["cancel"]
    def wait_modal(name,deadline,marker=None):
        attempt=0
        while True:
            rows=frame(name+"-"+str(attempt),deadline)
            try:
                modal(rows,marker)
                return rows
            except RuntimeError:
                if deadline-time.monotonic()<=0.1: raise
                time.sleep(0.1); attempt+=1
    def baseline_unresolved(call):
        records=[]
        for line in (phase/"none.jsonl").read_text().splitlines():
            try: records.append(json.loads(line))
            except json.JSONDecodeError: pass
        if ((phase/"arm-finished-none").exists() or any(r.get("kind")=="process_exit" for r in records)
                or any(r.get("kind")=="query" and r.get("call_id")==call for r in records)):
            raise RuntimeError("Baseline observer completed during native observation; result is inconclusive")
        identities=json.loads((phase/"root-name-evidence-none"/"process-identities.json").read_text())
        client=identities["client_pid"]
        current_start=pathlib.Path(f"/proc/{client}/stat").read_text().rsplit(") ",1)[1].split()[19]
        if current_start!=identities["client_starttime"] or os.readlink(f"/proc/{client}/exe")!=identities["client_exe"]:
            raise RuntimeError("Baseline observer identity changed during native observation")
        log("policy-baseline-unresolved-check",call_id=call,client_pid=client,client_starttime=current_start)
    def prepare(arm):
        deadline=time.monotonic()+18
        rows=frame("policy-"+arm+"-before-open",deadline)
        labels={r["text"].lower().strip() for r in rows}
        if {"type","message"}.issubset(labels): raise RuntimeError("Old modal remains before policy arm")
        hits=[r for r in rows if r["text"].lower().strip()=="text"]
        if len(hits)!=1 or float(hits[0]["conf"])<90 or "selection" not in labels:
            raise RuntimeError("Policy arm requires rendered confident Send/Text control")
        hit=hits[0]; x=int(hit["left"])+int(hit["width"])//2; y=int(hit["top"])+int(hit["height"])//2
        target_visible("policy-"+arm+"-before-open","Text",hit,frozen_geometry)
        exact_visible_label("policy-"+arm+"-before-open","Selection",rows,frozen_geometry)
        log("policy-native-text-click",arm=arm,x=x,y=y)
        bounded_run(deadline,"xdotool","mousemove",str(x),str(y),"click","1")
        wait_modal("policy-"+arm+"-opened",deadline)
        log("policy-native-marker-input",arm=arm,marker="precheck",delay_ms=30)
        bounded_run(deadline,"xdotool","type","--clearmodifiers","--delay","30","precheck")
        wait_modal("policy-"+arm+"-preobserver-marker",deadline,"precheck")
        log("policy-native-preobserver-pass",arm=arm,marker="precheck")
    def native_during_wait(arm,call):
        deadline=time.monotonic()+18
        rows=frame("policy-"+arm+"-during-wait-before",deadline); modal(rows,"precheck")
        baseline_unresolved(call)
        log("policy-native-marker-input",arm=arm,marker="probecheck")
        log("policy-native-select-input",arm=arm,key="ctrl+a")
        bounded_run(deadline,"xdotool","key","--clearmodifiers","ctrl+a")
        bounded_run(deadline,"xdotool","type","--clearmodifiers","--delay","30","probecheck")
        rows=wait_modal("policy-"+arm+"-during-wait-marker",deadline,"probecheck"); cancel=modal(rows,"probecheck")
        baseline_unresolved(call)
        x=int(cancel["left"])+int(cancel["width"])//2; y=int(cancel["top"])+int(cancel["height"])//2
        log("policy-native-cancel-click",arm=arm,x=x,y=y)
        bounded_run(deadline,"xdotool","mousemove",str(x),str(y),"click","1")
        attempt=0
        while True:
            rows=frame("policy-"+arm+"-during-wait-dismissed-"+str(attempt),deadline)
            labels={r["text"].lower().strip() for r in rows}
            send_labels=[r for r in rows if r["text"].lower().strip() in ("selection","text")]
            unique_send=(len(send_labels)==2 and {r["text"].lower().strip() for r in send_labels}=={"selection","text"}
                         and all(float(r["conf"])>=90 for r in send_labels))
            if not {"type","message","cancel","confirm","probecheck"}.intersection(labels) and unique_send:
                for label in ("Selection","Text"):
                    exact_visible_label("policy-"+arm+"-dismissed",label,rows,frozen_geometry)
                break
            if deadline-time.monotonic()<=0.1:
                raise RuntimeError("Native Cancel did not visibly dismiss Text and return to Send")
            time.sleep(0.1); attempt+=1
        baseline_unresolved(call)
        log("policy-native-during-wait-pass",arm=arm,marker="probecheck",cancel_dismissed=True)
    try:
        if (out.resolve()!=pathlib.Path("/home/mint/evidence") or not (out/"bootstrap-complete").is_file()
                or "ID=linuxmint" not in pathlib.Path("/etc/os-release").read_text().splitlines()):
            raise RuntimeError("Observer policy capture requires staged cloud Mint session")
        prepare("none")
        fixture=pathlib.Path(__file__).resolve().parent/"2754-accessibility"/"capture-geometry.sh"
        env=os.environ.copy(); env["PROBE_CLOUD_GEOMETRY"]="1"
        command=["timeout","--kill-after=5s","450s","bash",str(fixture),str(app.pid),"observer-policy",str(phase),w[-1]]
        with (phase/"capture.stdout").open("w") as stdout, (phase/"capture.stderr").open("w") as stderr:
            capture=subprocess.Popen(command,env=env,stdout=stdout,stderr=stderr,text=True,stdin=subprocess.DEVNULL)
            deadline=time.monotonic()+460
            ready=set(); root_enter_time=None
            geometry_sample=0
            while capture.poll() is None:
                if time.monotonic()>=deadline: raise RuntimeError("Observer policy capture exceeded original bound")
                # Detect WM movement between arms and during the unresolved
                # observer, as well as around each saved native frame.
                raw=bounded_run(deadline,"xdotool","getwindowgeometry","--shell",w[-1]).stdout
                values=dict(line.split("=",1) for line in raw.splitlines() if "=" in line)
                current={key:int(values[key]) for key in ("X","Y","WIDTH","HEIGHT","SCREEN")}
                current["KEYBOARD_TOP"]=keyboard_top(execute=lambda *args: bounded_run(deadline,*args))
                with (phase/"native-geometry-samples.jsonl").open("a") as samples:
                    samples.write(json.dumps(dict(t=time.monotonic(),wall=time.time(),sample=geometry_sample,geometry=current))+"\n")
                geometry_sample+=1
                if current!=frozen_geometry: raise RuntimeError("WM changed policy geometry after freeze")
                for arm in ("none","states"):
                    request=phase/("arm-request-"+arm)
                    if request.is_file() and arm not in ready:
                        requested=json.loads(request.read_text())
                        if requested.get("arm")!=arm: raise RuntimeError("Policy arm request mismatch")
                        if arm=="states":
                            if not status["native_baseline_during_wait"]:
                                raise RuntimeError("Baseline native responsiveness gate was not reached")
                            prepare(arm)
                        temporary=phase/("arm-ready-"+arm+".tmp")
                        temporary.write_text(json.dumps(dict(arm=arm,status="ready")))
                        temporary.replace(phase/("arm-ready-"+arm)); ready.add(arm)
                if "none" in ready and not status["native_baseline_during_wait"]:
                    records=[]; path=phase/"none.jsonl"
                    if path.is_file():
                        for line in path.read_text().splitlines():
                            try: records.append(json.loads(line))
                            except json.JSONDecodeError: pass
                    entries=[r for r in records if r.get("kind")=="query_enter" and r.get("op")=="GetName"
                             and r.get("identity",{}).get("path")=="/org/a11y/atspi/accessible/root"]
                    if entries:
                        entry=entries[-1]; call=entry["call_id"]
                        if any(r.get("kind")=="query" and r.get("call_id")==call for r in records):
                            raise RuntimeError("Baseline Name completed; required unresolved observer condition absent")
                        if root_enter_time is None: root_enter_time=time.monotonic()
                        watcher_result=phase/"root-name-evidence-none"/"result.json"
                        watcher_finished=False
                        if watcher_result.is_file():
                            try: watcher_finished=json.loads(watcher_result.read_text()).get("status")=="collected-only"
                            except json.JSONDecodeError: pass
                        if time.monotonic()-root_enter_time>=3 and watcher_finished:
                            log("policy-baseline-name-unresolved",call_id=call,elapsed_seconds=time.monotonic()-root_enter_time)
                            native_during_wait("none",call); status["native_baseline_during_wait"]=True
                time.sleep(0.1)
            status.update(status="capture-finished",returncode=capture.returncode)
            if capture.returncode!=0 or not status["native_baseline_during_wait"]:
                raise RuntimeError("Policy process/native responsiveness gates incomplete")
    except Exception as error:
        status.update(status="capture-failed",error=type(error).__name__+": "+str(error))
        log("policy-capture-failed",**status)
    finally:
        if capture is not None and capture.poll() is None:
            capture.terminate()
            try: capture.wait(timeout=25)
            except subprocess.TimeoutExpired:
                capture.kill(); capture.wait(timeout=5)
        (phase/"native-policy-status.json").write_text(json.dumps(status,indent=2))
    return status["status"]=="capture-finished" and status.get("returncode")==0

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
def capture_interaction_phase():
    phase=out/"interactions-post-geometry"; phase.mkdir(exist_ok=True)
    status=dict(phase="post-geometry",status="started",app_pid=app.pid,window_id=w[-1],speech_status="unknown")
    try:
        if (os.uname().sysname != "Linux" or out.resolve() != pathlib.Path("/home/mint/evidence")
                or not (out/"bootstrap-complete").is_file()
                or "ID=linuxmint" not in pathlib.Path("/etc/os-release").read_text().splitlines()):
            raise RuntimeError("Interaction phase requires the staged cloud Mint session")
        here=pathlib.Path(__file__).resolve().parent
        fixture=here/"2754-accessibility"/"capture-interactions.sh"
        launcher=here/"2754-bridge-app"
        click_word("Text","interactions-fresh-text-before")
        deadline=time.monotonic()+60
        attempt=0
        while True:
            rows=snap("interactions-modal-wait-"+str(attempt))
            labels={r["text"].lower().strip() for r in rows}
            if {"type","message"}.issubset(labels): break
            if time.monotonic() >= deadline: raise RuntimeError("Fresh Text dialog did not render before interaction phase")
            attempt+=1; time.sleep(2)
        log("interactions-phase-start",pid=app.pid,window_id=w[-1])
        env=os.environ.copy(); env["PROBE_CLOUD_INTERACTIONS"]="1"
        command=["timeout","--kill-after=60s","1200s","bash",str(fixture),str(app.pid),w[-1],str(phase),str(launcher)]
        status["capture_command"]=command
        with (phase/"capture.stdout").open("w") as stdout, (phase/"capture.stderr").open("w") as stderr:
            result=subprocess.run(command,env=env,stdout=stdout,stderr=stderr,text=True,timeout=1275)
        status.update(status="capture-finished",returncode=result.returncode,deadline_hit=result.returncode in (124,137))
    except Exception as error:
        status.update(status="capture-failed",error=type(error).__name__+": "+str(error),deadline_hit=isinstance(error,subprocess.TimeoutExpired))
    finally:
        (phase/"phase-status.json").write_text(json.dumps(status,indent=2))
        snap("interactions-phase-final")
        # The harness may restart the app. Preserve its lifecycle evidence and
        # stop only the newly verified executable, even if a later gate failed.
        pidfile=phase/"restarted-app-pid.txt"
        startfile=phase/"restarted-app-starttime.txt"
        cmdfile=phase/"restarted-app-cmdline.bin"
        if pidfile.is_file() and startfile.is_file() and cmdfile.is_file():
            restarted_pid=int(pidfile.read_text().strip())
            expected=(out/"app-real-executable.txt").read_text().strip()
            proc=pathlib.Path(f"/proc/{restarted_pid}")
            if (proc.joinpath("exe").exists() and os.readlink(proc/"exe")==expected
                    and proc.joinpath("stat").read_text().split()[21]==startfile.read_text().strip()
                    and proc.joinpath("cmdline").read_bytes()==cmdfile.read_bytes()):
                log("interactions-restarted-app-cleanup",pid=restarted_pid,executable=expected)
                run("kill","-TERM",str(restarted_pid))
        log("interactions-phase-ended",**status)
    return status["status"]=="capture-finished" and status.get("returncode")==0
log("start")
calibration_flag=os.environ.get("PROBE_NATIVE_GEOMETRY_CALIBRATION","0")
if calibration_flag not in ("0","1"): raise RuntimeError("Invalid native calibration opt-in")
executable=os.environ.get("APP_EXECUTABLE","localsend_app")
app=subprocess.Popen([executable],stdin=subprocess.DEVNULL,stdout=open(out/"app.log","w"),stderr=subprocess.STDOUT)
time.sleep(15)
log("app",pid=app.pid,executable=executable,proc_exe=os.readlink(f"/proc/{app.pid}/exe"))
(out/"initial-keyboard-settings.txt").write_text(run("gsettings","list-recursively","org.cinnamon.desktop.a11y.applications").stdout)
# Locate the original process's actual app window before supported WM setup.
w=run("xdotool","search","--onlyvisible","--name","LocalSend").stdout.splitlines()
if not w: raise RuntimeError("LocalSend visible window absent")
owned=[window for window in w if run("xdotool","getwindowpid",window).stdout.strip()==str(app.pid)
       and run("xdotool","getwindowname",window).stdout.strip()=="LocalSend"]
if len(owned)!=1: raise RuntimeError("Original LocalSend native window is ambiguous")
w=owned
run("xdotool","windowactivate","--sync",w[-1])
if calibration_flag=="1":
    try:
        calibration_completed=native_geometry_calibration()
    finally:
        log("native-geometry-app-cleanup",app_pid=app.pid)
        app.terminate()
        try: app.wait(timeout=5)
        except subprocess.TimeoutExpired:
            app.kill(); app.wait(timeout=5)
    raise SystemExit(0 if calibration_completed else 1)
initial_resize=run("xdotool","windowsize",w[-1],"1100","700")
log("initial-wm-size-input",command=["xdotool","windowsize",w[-1],"1100","700"],returncode=initial_resize.returncode)
if initial_resize.returncode!=0: raise RuntimeError("Original launch 1100x700 sizing failed")
normalize_window("initial-viewport")
time.sleep(3); snap("app-ready")
click_word("Send","send"); time.sleep(2)
text_case("keyboard-off")
# Paste is a real application action, with clipboard content set by xclip.
# The clipboard owner can outlive the driver; do not let it retain SSH output streams.
subprocess.run(["xclip","-selection","clipboard"],input=b"Paste control issue2754",stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
log("clipboard-input",case="keyboard-off",text="Paste control issue2754")
click_word("Paste","paste-before"); time.sleep(3); snap("paste-result")
# Clear the selection through its rendered close control before the next original Text trigger.
clear_paste("paste-clear")
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
log("clipboard-input",case="keyboard-on",text="Paste enabled keyboard control")
click_word("Paste","keyboard-on-paste-before"); time.sleep(3); snap("keyboard-on-paste-result")
clear_paste("keyboard-on-paste-clear")
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
policy_completed=True
if os.environ.get("PROBE_OBSERVER_POLICY_DISCRIMINATOR","0") == "1":
    policy_completed=capture_observer_policy_phase()
elif os.environ.get("PROBE_CAPTURE_GEOMETRY","0") == "1":
    capture_geometry_phase()
interaction_completed=True
if os.environ.get("PROBE_CAPTURE_INTERACTIONS","0") == "1":
    interaction_completed=capture_interaction_phase()
log("completed")
settings.terminate(); app.terminate()
if not interaction_completed:
    raise RuntimeError("Requested interaction phase did not complete its process/API gates; inspect separate raw verdicts")
if not policy_completed:
    raise RuntimeError("Observer policy/native responsiveness stage did not complete; inspect retained raw evidence")
