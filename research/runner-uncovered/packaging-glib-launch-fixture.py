import json
import os
import pathlib
import sys
import time
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio

root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
results = []
for row in manifest:
    receipt = pathlib.Path(row["record"])
    receipt.unlink(missing_ok=True)
    os.environ["PACKAGING_RECORD"] = str(receipt)
    error = None
    try:
        app = Gio.DesktopAppInfo.new_from_filename(row["desktop"])
        if app is None:
            error = "Desktop entry rejected by GLib"
        else:
            app.launch([], None)
    except Exception as exc:
        error = str(exc)
    limit = time.monotonic() + (2 if row["version"] == "after" else .25)
    while time.monotonic() < limit and not receipt.exists():
        time.sleep(.02)
    actual = json.loads(receipt.read_text()) if receipt.exists() else None
    success = actual == row["expected_argv"]
    result = dict(row, success=success, actual_argv=actual, launch_error=error, desktop_contents=pathlib.Path(row["desktop"]).read_text())
    results.append(result)
    if row["version"] == "after" and not success:
        print("CASE_FAILURE " + json.dumps({key: result[key] for key in ["name", "hidden", "use_appimage", "launch_error", "actual_argv", "expected_argv", "desktop_contents"]}), flush=True)
(root / "glib-results.json").write_text(json.dumps(results, indent=2))
after = [r for r in results if r["version"] == "after"]
before_appimage = [r for r in results if r["version"] == "before" and r["use_appimage"]]
print(json.dumps({"after_success": sum(r["success"] for r in after), "after_total": len(after), "before_appimage_success": sum(r["success"] for r in before_appimage), "before_appimage_total": len(before_appimage)}, indent=2))
assert all(r["success"] for r in after), "patched desktop launch failed"
assert not any(r["success"] for r in before_appimage), "baseline unexpectedly launched after mount deletion"
