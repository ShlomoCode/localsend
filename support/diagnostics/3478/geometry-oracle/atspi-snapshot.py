#!/usr/bin/env python3
"""Guest-only AT-SPI observation; no clicks, edits, or guessed coordinates."""
import argparse
import json
import time
import pyatspi


def observe(operation):
    try:
        return {"value": operation(), "error": None}
    except Exception as error:
        return {"value": None, "error": str(error)}


def geometry(component, space):
    extent = component.getExtents(space)
    position = component.getPosition(space)
    size = component.getSize()
    return {"extents": {"x": extent.x, "y": extent.y,
                        "width": extent.width, "height": extent.height},
            "position": list(position), "size": list(size)}


parser = argparse.ArgumentParser()
parser.add_argument("--name", help="Exact desktop application accessible name")
parser.add_argument("--pid", type=int, help="Exact AT-SPI-reported PID; do not assume host namespace")
parser.add_argument("--max-nodes", type=int, default=1000)
parser.add_argument("--max-depth", type=int, default=30)
parser.add_argument("--action-path", help="JSON ancestry index array from an earlier snapshot")
parser.add_argument("--action-index", type=int, default=0)
parser.add_argument("--edit-path", help="JSON ancestry index array from an earlier snapshot")
parser.add_argument("--text", default="", help="Text for the optional EditableText call")
parser.add_argument("--settle-seconds", type=float, default=1)
args = parser.parse_args()
started = time.monotonic_ns()
records = []
print(json.dumps({"event": "start", "monotonicNs": started}), flush=True)


def visit(node, path, depth):
    if len(records) >= args.max_nodes or depth > args.max_depth:
        print(json.dumps({"event": "truncated", "path": path}), flush=True)
        return
    print(json.dumps({"event": "node-start", "path": path,
                      "monotonicNs": time.monotonic_ns()}), flush=True)
    record = {"event": "node", "path": path, "depth": depth,
              "name": observe(lambda: node.name),
              "role": observe(node.getRoleName),
              "description": observe(lambda: node.description),
              "pid": observe(node.get_process_id),
              "interfaces": observe(node.get_interfaces),
              "states": observe(lambda: [str(s) for s in node.getState().getStates()])}
    component = observe(node.queryComponent)
    if component["error"] is None:
        record["screen"] = observe(lambda: geometry(component["value"], pyatspi.DESKTOP_COORDS))
        record["window"] = observe(lambda: geometry(component["value"], pyatspi.WINDOW_COORDS))
    else:
        record["componentError"] = component["error"]
    action = observe(node.queryAction)
    if action["error"] is None:
        a = action["value"]
        record["actions"] = observe(lambda: [{"index": i, "name": a.getName(i),
                                               "description": a.getDescription(i),
                                               "keyBinding": a.getKeyBinding(i)}
                                              for i in range(a.nActions)])
    text = observe(node.queryText)
    if text["error"] is None:
        t = text["value"]
        record["text"] = observe(lambda: {"characters": t.characterCount,
                                          "caretOffset": t.caretOffset,
                                          "value": t.getText(0, min(t.characterCount, 4096))})
    records.append(record)
    print(json.dumps(record), flush=True)
    children = observe(lambda: node.childCount)
    if children["error"] is not None:
        print(json.dumps({"event": "children-error", "path": path, **children}), flush=True)
        return
    for i in range(children["value"]):
        child = observe(lambda: node.getChildAtIndex(i))
        if child["error"] is None and child["value"] is not None:
            visit(child["value"], path + [i], depth + 1)
        else:
            print(json.dumps({"event": "child-error", "path": path + [i],
                              "error": child["error"]}), flush=True)


desktop = pyatspi.Registry.getDesktop(0)
matched = 0
for index in range(desktop.childCount):
    app = desktop.getChildAtIndex(index)
    name = observe(lambda: app.name)
    pid = observe(app.get_process_id)
    print(json.dumps({"event": "application", "path": [index], "name": name, "pid": pid}), flush=True)
    if args.name is not None and name["value"] != args.name:
        continue
    if args.pid is not None and pid["value"] != args.pid:
        continue
    matched += 1
    visit(app, [index], 0)
print(json.dumps({"event": "complete", "applicationsMatched": matched,
                  "nodes": len(records), "monotonicNs": time.monotonic_ns()}), flush=True)


def resolve(path):
    node = desktop
    for index in json.loads(path):
        node = node.getChildAtIndex(index)
    return node


for operation, path in [("action", args.action_path), ("edit", args.edit_path)]:
    if path is None:
        continue
    print(json.dumps({"event": "operation-start", "operation": operation,
                      "path": path, "monotonicNs": time.monotonic_ns()}), flush=True)
    node = resolve(path)
    if operation == "action":
        result = observe(lambda: node.queryAction().doAction(args.action_index))
    else:
        result = observe(lambda: node.queryEditableText().setTextContents(args.text))
    print(json.dumps({"event": "operation-return", "operation": operation,
                      "result": result, "monotonicNs": time.monotonic_ns()}), flush=True)
    time.sleep(args.settle_seconds)
    # Capture the semantic result, not merely the action's boolean return value.
    records.clear()
    print(json.dumps({"event": "after-operation-start", "operation": operation}), flush=True)
    visit(node.getApplication(), json.loads(path)[:1], 0)
    print(json.dumps({"event": "after-operation-complete", "operation": operation,
                      "monotonicNs": time.monotonic_ns()}), flush=True)
