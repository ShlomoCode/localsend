"""Measure screenshot pixels, independently of panel configuration and icon files."""
import json
import sys
from pathlib import Path
from PIL import Image

directory = Path(sys.argv[1])
rows = []
for path in sorted(directory.glob("*.png")):
    if path.name == "desktop-ready.png":
        continue
    image = Image.open(path).convert("RGB")
    assert image.size == (3840, 2160), image.size
    scale = 2 if path.name.startswith("200") else 1
    panel_height = 25 * scale
    # BlackMATE's tray handle is gray. LocalSend is the leftmost white tray icon.
    # Keep the clock outside the region. Retain crops for independent inspection.
    crop = image.crop((3200, 0, 3840 - 140 * scale, panel_height))
    crop.save(directory / (path.stem + "-tray.png"))
    hits = {}
    for x in range(crop.width):
        ys = [y for y in range(crop.height) if min(crop.getpixel((x, y))) > 160 and max(crop.getpixel((x, y))) - min(crop.getpixel((x, y))) < 25]
        if ys:
            hits[x] = ys
    groups = []
    for x in hits:
        if not groups or x - groups[-1][-1] > 3:
            groups.append([])
        groups[-1].append(x)
    groups = [group for group in groups if group[-1] - group[0] >= 6 and sum(len(hits[x]) for x in group) > 20]
    assert groups, path
    group = groups[0]
    ys = [y for x in group for y in hits[x]]
    bounds = [3200 + group[0], min(ys), 3200 + group[-1] + 1, max(ys) + 1]
    width = bounds[2] - bounds[0]
    height = bounds[3] - bounds[1]
    rows.append({"case": path.stem, "scale": scale, "screen": image.size, "panel_height": panel_height, "white_icon_bounds": bounds, "width": width, "height": height, "height_over_panel": height / panel_height})
    image.crop((bounds[0] - 6, 0, bounds[2] + 6, panel_height)).save(directory / (path.stem + "-icon.png"))
(directory / "measurements.json").write_text(json.dumps(rows, indent=2) + "\n")
print(json.dumps(rows, indent=2))
