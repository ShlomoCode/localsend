#!/usr/bin/env python3
"""Proposed guest-only AT-SPI recorder; source review precedes runtime acceptance."""
import argparse
import datetime
import json
import signal
import time
import pyatspi
from gi.repository import Atspi


def emit(record):
    record.setdefault("monotonicNs", time.monotonic_ns())
    record.setdefault("utc", datetime.datetime.now(datetime.timezone.utc).isoformat())
    print(json.dumps(record), flush=True)


class Inconclusive(Exception):
    pass


class Observation:
    def __init__(self, sequence, received_ns):
        self.sequence = sequence
        self.received_ns = received_ns
        self.calls = 0
        self.errors = []

    def query(self, label, operation):
        start = time.monotonic_ns()
        if start - self.received_ns >= args.budget_ms * 1_000_000 or self.calls >= args.max_calls:
            emit({"event": "call-skipped", "sequence": self.sequence, "label": label,
                  "reason": "Cumulative callback budget or call cap reached"})
            raise Inconclusive("Cumulative callback budget or call cap reached")
        self.calls += 1
        emit({"event": "call-start", "sequence": self.sequence, "call": self.calls,
              "label": label, "startMonotonicNs": start})
        value = None
        error = None
        try:
            value = operation()
        except Exception as failure:
            error = str(failure)
            self.errors.append({"label": label, "error": error})
        end = time.monotonic_ns()
        # JSON supports only public returned primitives/containers here. Do not
        # inspect interface/proxy attributes to manufacture an identity or value.
        try:
            json.dumps(value)
            retained_value = {"value": value, "representation": "json-value"}
        except (TypeError, ValueError, OverflowError):
            retained_value = {"value": None, "representation": "nonserializable-public-result",
                              "pythonType": type(value).__name__}
        emit({"event": "call-end", "sequence": self.sequence, "call": self.calls,
              "label": label, "startMonotonicNs": start, "endMonotonicNs": end,
              "durationNs": end - start, "error": error, "returned": retained_value})
        if end - self.received_ns >= args.budget_ms * 1_000_000:
            raise Inconclusive("Callback exceeded cumulative budget; discard geometry interpretation")
        return {"value": value, "error": error}

    def identity(self, node, label, result):
        # A single state query supplies all recorded flags; no repeated remote state calls.
        states = self.query(label + ".state", node.getState)
        state = states["value"]
        result["states"] = {"value": [str(s) for s in state.getStates()] if state is not None else None,
                            "error": states["error"]}
        result["active"] = state.contains(pyatspi.STATE_ACTIVE) if state is not None else None
        result["focused"] = state.contains(pyatspi.STATE_FOCUSED) if state is not None else None
        result["visible"] = state.contains(pyatspi.STATE_VISIBLE) if state is not None else None
        result["showing"] = state.contains(pyatspi.STATE_SHOWING) if state is not None else None
        result["name"] = self.query(label + ".name", lambda: node.name)
        result["role"] = self.query(label + ".role", node.getRoleName)
        result["roleEnum"] = self.query(label + ".roleEnum", node.getRole)
        result["reportedPid"] = self.query(label + ".pid", node.get_process_id)
        return result


def box(value):
    return {"x": value.x, "y": value.y, "width": value.width, "height": value.height}


def text_box(value):
    x, y, width, height = value  # Text returns rectToList, Component returns BoundingBox.
    return {"x": x, "y": y, "width": width, "height": height}


parser = argparse.ArgumentParser()
parser.add_argument("--name", help="Mark exact application-name matches; raw receipts always retained")
parser.add_argument("--budget-ms", type=int, default=1000, choices=range(250, 2001), metavar="250..2000")
parser.add_argument("--max-calls", type=int, default=32, choices=range(1, 49), metavar="1..48")
parser.add_argument("--ancestry-cap", type=int, default=4, choices=range(1, 9), metavar="1..8")
parser.add_argument("--include-screen", action="store_true", help="Optional SCREEN queries after consumer WINDOW data and identity")
args = parser.parse_args()
events = 0
stopping = False
types = ["object:state-changed:focused", "object:state-changed:selected", "object:text-caret-moved"]


def on_event(event):
    global events
    received_ns = time.monotonic_ns()
    events += 1
    # Event metadata is local. No accessible source queries precede this flushed receipt.
    emit({"event": "observation-start", "sequence": events, "type": event.type,
          "detail1": event.detail1, "detail2": event.detail2,
          "receivedMonotonicNs": received_ns,
          "emissionTimestamp": {"value": None, "error": "Not provided by this collector"}})
    obs = Observation(events, received_ns)
    record = {"event": "observation", "sequence": events, "type": event.type,
              "detail1": event.detail1, "detail2": event.detail2,
              "receivedMonotonicNs": received_ns,
              "accessibleBusObjectIdentity": {"value": None,
                  "error": "No supported public bus/object identity API verified; name/PID/ancestry are not durable identity"}}
    optional_screen = None
    reasons = []
    caret_event = event.type == "object:text-caret-moved"
    focus_event = event.type in ("object:state-changed:focused", "object:state-changed:selected")
    consumer_event_eligible = caret_event or (focus_event and event.detail1 == 1)
    record["consumerEventEligibility"] = {
        "eligibleByTypeAndDetail": consumer_event_eligible,
        "path": "caret" if caret_event else "focus" if focus_event else "unsupported",
        "reason": "Caret event type passes event gate; geometry and state prerequisites remain separate"
            if caret_event else "Focus/selection addition passes detail1 == 1 event gate"
            if consumer_event_eligible else "Shell does not process this event as a focus update; detail1 must equal 1"}
    if not consumer_event_eligible:
        reasons.append("Event is not eligible for Shell consumer focus update")
    try:
        source = event.source
        # Observe the consumer's WINDOW path first, before application, states, or SCREEN.
        if event.type == "object:text-caret-moved":
            interface = obs.query("text.interface", source.queryText)
            if interface["value"] is not None:
                text = interface["value"]
                offset = obs.query("text.currentCaretOffset", lambda: text.caretOffset)
                record["currentCaretOffset"] = offset
                if offset["value"] is not None:
                    pos = offset["value"]
                    record["consumerWindow"] = obs.query("text.currentCaret.WINDOW",
                        lambda: text_box(text.getCharacterExtents(pos, pyatspi.WINDOW_COORDS)))
                    optional_screen = lambda: text_box(text.getCharacterExtents(pos, pyatspi.DESKTOP_COORDS))
                record["eventOffsetWindow"] = obs.query("text.eventOffset.WINDOW",
                    lambda: text_box(text.getCharacterExtents(event.detail1, pyatspi.WINDOW_COORDS)))
        else:
            interface = obs.query("component.interface", source.queryComponent)
            if interface["value"] is not None:
                component = interface["value"]
                record["consumerWindow"] = obs.query("component.WINDOW",
                    lambda: box(component.getExtents(pyatspi.WINDOW_COORDS)))
                optional_screen = lambda: box(component.getExtents(pyatspi.DESKTOP_COORDS))
        record["source"] = {}
        source_identity = obs.identity(source, "source", record["source"])
        application = obs.query("source.application", source.getApplication)
        if application["value"] is not None:
            app = application["value"]
            record["application"] = {}
            record["application"]["name"] = obs.query("application.name", lambda: app.name)
            record["application"]["reportedPid"] = obs.query("application.pid", app.get_process_id)
        else:
            reasons.append("Application identity unresolved")
            record["application"] = {"error": application["error"] or "No application"}
        if args.name is not None:
            app_name = record.get("application", {}).get("name", {}).get("value")
            record["applicationNameMatches"] = app_name == args.name if app_name is not None else None
            if app_name is None:
                reasons.append("Application-name filter unresolved")
        ancestry = {"nodes": [source_identity], "complete": False, "error": None}
        record["ancestry"] = ancestry
        node = source
        item = source_identity
        for depth in range(args.ancestry_cap):
            if item["roleEnum"]["value"] == pyatspi.ROLE_APPLICATION:
                ancestry["complete"] = True
                break
            if depth + 1 >= args.ancestry_cap:
                break
            parent = obs.query("ancestor.parent." + str(depth), lambda: node.parent)
            if parent["value"] is None:
                ancestry["error"] = parent["error"] or "No parent"
                break
            node = parent["value"]
            item = {"depth": depth + 1}
            ancestry["nodes"].append(item)
            obs.identity(node, "ancestor." + str(depth + 1), item)
        if not ancestry["complete"]:
            reasons.append("Ancestry unresolved or capped")
        parent_window = None
        for ancestor in ancestry["nodes"]:
            if ancestor["roleEnum"]["value"] in (pyatspi.ROLE_FRAME, pyatspi.ROLE_DIALOG, pyatspi.ROLE_WINDOW):
                parent_window = ancestor
        record["consumerStatePrerequisites"] = {
            "ancestryComplete": ancestry["complete"],
            "retainedLastWindowAncestor": parent_window,
            "sourceFocused": source_identity["focused"],
            "parentWindowActive": parent_window["active"] if parent_window else None}
        if not ancestry["complete"] or parent_window is None:
            reasons.append("Shell retained-window ancestor unresolved")
        elif source_identity["focused"] is not True or parent_window["active"] is not True:
            reasons.append("Shell source-focused/ancestor-active prerequisites unmet")
        if args.include_screen and optional_screen is not None:
            record["optionalScreen"] = obs.query("optional.SCREEN", optional_screen)
        else:
            record["optionalScreen"] = {"value": None, "error": "Not requested or interface unavailable"}
    except Inconclusive as error:
        reasons.append(str(error))
    except Exception as error:
        reasons.append("Callback failure: " + str(error))
    finally:
        end = time.monotonic_ns()
        if end - received_ns >= args.budget_ms * 1_000_000:
            reasons.append("Slow event rejected for geometry interpretation")
        if obs.errors:
            reasons.append("One or more source queries failed")
        if record.get("consumerWindow", {}).get("value") is None:
            reasons.append("Consumer WINDOW geometry unresolved")
        # Even a completed query sequence is observational, not verified geometry correctness.
        record.update({"queryStatus": "inconclusive" if reasons else "completed",
                       "interpretationStatus": "inconclusive",
                       "identityLimit": "Durable bus/object identity unverified; compositor/event-time and rendered-control correlation still required",
                       "reasons": reasons, "errors": obs.errors, "calls": obs.calls,
                       "endMonotonicNs": end, "callbackDurationNs": end - received_ns})
        emit(record)


def stop(signum, frame):
    global stopping
    stopping = True
    emit({"event": "stop-request", "signal": signum})
    pyatspi.Registry.stop()


emit({"event": "start", "applicationNameMarker": args.name})
try:
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    Atspi.set_timeout(250, 250)
    pyatspi.Registry.registerEventListener(on_event, *types)
    emit({"event": "configured", "timeoutMs": 250, "startupTimeoutMs": 250,
          "callbackBudgetMs": args.budget_ms, "maxCalls": args.max_calls,
          "ancestryCap": args.ancestry_cap, "includeScreen": args.include_screen, "types": types})
    pyatspi.Registry.start()
except Exception as error:
    emit({"event": "recorder-error", "error": str(error)})
    raise
finally:
    try:
        pyatspi.Registry.deregisterEventListener(on_event, *types)
    except Exception as error:
        emit({"event": "cleanup-error", "error": str(error)})
    emit({"event": "end", "observations": events, "stopRequested": stopping})
