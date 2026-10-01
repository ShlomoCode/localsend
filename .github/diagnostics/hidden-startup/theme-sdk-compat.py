#!/usr/bin/env python3
"""Normalize only Flutter component-theme types rejected by SDK 3.35/3.38.

Diagnostic-only: preserve every constructor argument and theme value. Resolve
pub-cache files from this checkout's package_config rather than a guessed HOME.
Reapplication after the SDK switch verifies byte-identical patched sources.
"""

import argparse
import difflib
import hashlib
import json
import re
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def package_root(package_config, name, version):
    config = json.loads(package_config.read_text())
    matches = [entry for entry in config["packages"] if entry["name"] == name]
    if len(matches) != 1:
        raise SystemExit(f"package_config: expected one {name}, found {len(matches)}")
    root_uri = matches[0]["rootUri"]
    uri = urljoin(package_config.as_uri(), root_uri)
    parsed = urlparse(uri)
    if parsed.scheme != "file":
        raise SystemExit(f"{name}: unsupported package URI {uri}")
    root = Path(unquote(parsed.path)).resolve()
    if root.name != f"{name}-{version}":
        raise SystemExit(f"{name}: expected version {version}, resolved {root}")
    return root


parser = argparse.ArgumentParser()
parser.add_argument("--phase", choices=("old", "new"), required=True)
parser.add_argument("--evidence-dir", type=Path, required=True)
args = parser.parse_args()

evidence = args.evidence_dir.resolve()
evidence.mkdir(parents=True, exist_ok=True)
config_path = Path("app/.dart_tool/package_config.json").resolve()
if not config_path.is_file():
    raise SystemExit(f"missing {config_path}; run flutter pub get first")

# Each entry corresponds to a compiler error in the 3.35.6 run. The app's
# extension needs a new receiver type; all package edits are type-name swaps.
targets = [
    (Path("app/lib/config/theme.dart"), {"extension InputDecorationThemeExt on InputDecorationTheme {":
                                         "extension InputDecorationThemeExt on InputDecorationThemeData {"}),
    (package_root(config_path, "wechat_assets_picker", "9.5.0") / "lib/src/delegates/asset_picker_delegate.dart",
     {"BottomAppBarTheme": "BottomAppBarThemeData"}),
    (package_root(config_path, "wechat_assets_picker", "9.5.0") / "lib/src/widget/asset_picker_app_bar.dart",
     {"AppBarTheme": "AppBarThemeData"}),
    (package_root(config_path, "yaru", "5.3.2") / "lib/src/themes/common_themes.dart",
     {"TabBarTheme": "TabBarThemeData", "DialogTheme": "DialogThemeData",
      "CardTheme": "CardThemeData", "BottomAppBarTheme": "BottomAppBarThemeData"}),
    (package_root(config_path, "wechat_picker_library", "1.0.5") / "lib/src/themes.dart",
     {"BottomAppBarTheme": "BottomAppBarThemeData"}),
]

old_manifest = evidence / "theme-sdk-compat-old.json"
if args.phase == "new" and not old_manifest.is_file():
    raise SystemExit(f"missing prior compatibility manifest: {old_manifest}")
prior = json.loads(old_manifest.read_text()) if args.phase == "new" else None

records = []
patch = []
for path, swaps in targets:
    if not path.is_file():
        raise SystemExit(f"missing source: {path}")
    original = path.read_text()
    updated = original
    counts = {}
    for old, new in swaps.items():
        pattern = re.escape(old) if old.startswith("extension ") else rf"\b{re.escape(old)}\b"
        updated, count = re.subn(pattern, new, updated)
        counts[old] = count
        if args.phase == "old" and count == 0:
            raise SystemExit(f"{path}: no match for {old!r}")
    before = original.encode()
    after = updated.encode()
    record = {"path": str(path.resolve()), "sha256_before": sha256(before),
              "sha256_after": sha256(after), "replacements": counts}
    if args.phase == "new":
        expected = next((item for item in prior["files"] if item["path"] == record["path"]), None)
        if expected is None or record["sha256_after"] != expected["sha256_after"]:
            raise SystemExit(f"SDK switch changed source or dependency package: {path}")
    records.append(record)
    if updated != original:
        patch.extend(difflib.unified_diff(original.splitlines(True), updated.splitlines(True),
                                          fromfile=str(path), tofile=str(path)))

# Validate the entire source set before writing any file.
for path, swaps in targets:
    updated = path.read_text()
    for old, new in swaps.items():
        pattern = re.escape(old) if old.startswith("extension ") else rf"\b{re.escape(old)}\b"
        updated = re.sub(pattern, new, updated)
    if updated != path.read_text():
        path.write_text(updated)

(evidence / f"theme-sdk-compat-{args.phase}.json").write_text(json.dumps({"files": records}, indent=2) + "\n")
(evidence / f"theme-sdk-compat-{args.phase}.patch").write_text("".join(patch))
print(f"Theme type normalization {args.phase}: {len(targets)} files; "
      f"{sum(sum(record['replacements'].values()) for record in records)} replacements")
