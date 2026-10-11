"""Measure screenshot pixels, independently of panel configuration and icon files."""
import json
import re
import sys
from pathlib import Path
from PIL import Image

directory = Path(sys.argv[1])
rows = []
for path in sorted(directory.glob("*.png")):
    if path.name == "desktop-ready.png" or path.stem.endswith(("-icon", "-tray", "-reference")):
        continue
    image = Image.open(path).convert("RGB")
    assert image.size == (3840, 2160), image.size
    scale = 2 if path.name.startswith("200") else 1
    windows_path = directory / "guest-evidence" / "evidence" / (path.stem + "-windows.txt")
    if path.stem == "100-gui-before":
        windows_path = directory / "guest-evidence" / "evidence" / "100-live-first-windows.txt"
    panel_match = re.search(r'"Top Panel".*3840x(\d+)\+0\+0', windows_path.read_text())
    assert panel_match, windows_path
    panel_height = int(panel_match.group(1))
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
    # A volume icon can appear left of LocalSend after panel replacement. Its
    # white mask is taller than it is wide; LocalSend's circular logo is square.
    groups = [group for group in groups if 0.9 <= (group[-1] - group[0] + 1) / (max(y for x in group for y in hits[x]) - min(y for x in group for y in hits[x]) + 1) <= 1.1]
    assert groups, path
    group = groups[0]
    ys = [y for x in group for y in hits[x]]
    bounds = [3200 + group[0], min(ys), 3200 + group[-1] + 1, max(ys) + 1]
    width = bounds[2] - bounds[0]
    height = bounds[3] - bounds[1]
    # The system volume control is the independent reference. Its gray speaker
    # and blue level arcs sit to the right of LocalSend and before the clock.
    # Find achromatic non-background pixels by column, then select a compact
    # candidate in that known neighboring region. Keep the measurements
    # explicitly unknown if the reference is absent or ambiguous.
    ref_mask = {}
    for x in range(crop.width):
        active = []
        for y in range(crop.height):
            pixel = crop.getpixel((x, y))
            if min(pixel) > 80 and max(pixel) - min(pixel) < 75:
                active.append(y)
        if active:
            ref_mask[x] = active
    ref_groups = []
    for x in ref_mask:
        if not ref_groups or x - ref_groups[-1][-1] > 3:
            ref_groups.append([])
        ref_groups[-1].append(x)
    ref_candidates = []
    for candidate in ref_groups:
        if candidate[0] <= group[-1] + 5:
            continue
        candidate_ys = [y for x in candidate for y in ref_mask[x]]
        candidate_width = candidate[-1] - candidate[0] + 1
        candidate_height = max(candidate_ys) - min(candidate_ys) + 1
        # At 100% the volume glyph is about 16x21; at 200% it is about 32x43.
        if (10 * scale <= candidate_width <= 40 * scale and
                13 * scale <= candidate_height <= 50 * scale and
                0.45 <= candidate_width / candidate_height <= 1.0):
            ref_candidates.append((candidate, candidate_ys, candidate_width, candidate_height))
    reference = None
    alignment = None
    if len(ref_candidates) == 1:
        ref_group, ref_ys, ref_width, ref_height = ref_candidates[0]
        ref_bounds = [3200 + ref_group[0], min(ref_ys), 3200 + ref_group[-1] + 1, max(ref_ys) + 1]
        ref_center_y = (ref_bounds[1] + ref_bounds[3]) / 2
        icon_center_y = (bounds[1] + bounds[3]) / 2
        reference = {"name": "system-volume-control", "bounds": ref_bounds,
                     "width": ref_width, "height": ref_height, "center_y": ref_center_y}
        alignment = {"center_y_delta": icon_center_y - ref_center_y,
                     "icon_to_reference_width_ratio": width / ref_width,
                     "icon_to_reference_height_ratio": height / ref_height}
        image.crop((ref_bounds[0] - 6, 0, ref_bounds[2] + 6, panel_height)).save(directory / (path.stem + "-reference.png"))
    rows.append({"case": path.stem, "scale": scale, "screen": image.size, "panel_height": panel_height,
                 "white_icon_bounds": bounds, "width": width, "height": height,
                 "height_over_panel": height / panel_height, "reference": reference,
                 "alignment": alignment,
                 "reference_confidence": "high" if reference else "unknown"})
    image.crop((bounds[0] - 6, 0, bounds[2] + 6, panel_height)).save(directory / (path.stem + "-icon.png"))
(directory / "measurements.json").write_text(json.dumps(rows, indent=2) + "\n")
print(json.dumps(rows, indent=2))
