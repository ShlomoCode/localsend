# Retained chooser oracle audit — run 38167982047

Cloud source: [run 38167982047](https://github.com/ShlomoCode/localsend/actions/runs/38167982047), diagnostic head `4d24b6b4`. Compact artifact ID 11714001084 and full artifact ID 11714100892 preserve the original inputs. The independent helper produced this audit before the corresponding source correction. No later timing, geometry, editing, action, lifecycle or speech verdict follows from these still frames.

Read-only product investigation. No app, build, test, VM, or workflow was launched. Derived images and OCR outputs are confined to this directory. Originals are in `/tmp/2754-packaged-38167982047-compact/comparison/{control-system,B-system,AB-package}/guest`.

## Defect

All three variants' full `keyboard-on-file-control-chooser-3.png` frames visibly contain the real GTK Open File chooser and complete Cancel/Open labels. Their full-frame TSVs at attempts 1, 2, 3 recognize `Can` at x 1124, y 733 (21×9), and exact `Open` at x 1216, y 733 (31×11).

All variants' recorded chooser geometry is X 194, Y 359, WIDTH 1096, HEIGHT 441. The current source derives crop x 930, y 735, width 360, height 65. Since screen width is 1,280, its retained image is actually 350 × 65. Its top starts below the first Cancel/Open glyph pixels at y 733, clipping their tops and including the desktop panel. The visible dialog's bottom is 759, whereas reported Y+HEIGHT is 800. The native-coordinate crop cannot be treated as the visible button strip.

Retained faulty button TSVs identify panel symbols and time instead of Cancel/Open: control `©`, `O&`, `©`, `w:5`; B `©`, `Ow`, `022`; AB `©`, `Ow`, `1948`. This is an oracle failure, not evidence of a failed File action.

## Bounded replay

ImageMagick extracted a 160 × 22 crop at root x 1105, y 728 from each variant’s chooser attempts 1, 2, 3. This covers the visible text baseline with padding, anchored to the exact Open row at 1216,733. Crop anchors can be expressed as Open.left−111, Open.top−5 for these retained frames. Do not silently apply these measurements to arbitrary desktop geometries; retain the exact chooser-title/owner guard and record the actual rendered anchor.

Commands used within this directory:

```sh
rtk proxy magick ORIGINAL.png -crop 160x22+1105+728 +repage CROP.png
rtk proxy magick CROP.png -resize 300% SCALED.png
rtk proxy tesseract SCALED.png OUTPUT --psm 7 tsv
```

Tesseract 5.5.3, Leptonica 1.87.0, local macOS. Relative image names are required by the local Tesseract installation; absolute `/tmp/...` input paths failed to open. Cloud Tesseract's exact version/output is not validated by this replay.

All nine unscaled positive crops recognize exact `Cancel` confidence 75.698067 and `Open` confidence 74.980362. All nine 3× scaled positive crops recognize exact `Cancel` confidence 96.321098 and `Open` confidence 96.570328. Each saved TSV preserves the evidence. `AB-package-2.png` was visually inspected: both complete labels are visible.

Scaled boxes are identical across all nine:

| Label | left | top | width | height | confidence |
|---|---:|---:|---:|---:|---:|
| Cancel |50|7|123|46|96.321098|
| Open |330|14|97|34|96.570328|

Coordinate transform is rootX=cropX+(left+width/2)/3; rootY=cropY+(top+height/2)/3. Cancel's center is approximately (1142.17,738.00), so integer click (1142,738) lies in the visually confirmed Cancel button. Open's center is approximately (1231.17,738.33). Current click logic must divide scaled boxes by 3 before adding the crop origin.

## Negative controls

For each variant, the identical root crop from `keyboard-on-file-control-before.png` (no chooser) and an adjacent strip at x 1105, y 690 from chooser attempt 2 were processed at both original size and 3× scale: six negative crops in each mode. All reject exact Cancel/Open. Non-dialog crops produce `Be` confidence 0. Adjacent scaled crops produce only `19:31` (control,96.152008), `19:38` (B,95.736099), `18:41` (AB,96.454597). Their PNGs/TSVs remain alongside positive evidence.

## Smallest supported correction

### Guest-compatible FFmpeg replay

The same nine positives and six negatives were also replayed with FFmpeg, which is already installed in the guest. Use the saved full `snap` PNG as input so the crop and root anchor share one frame; do not take another scrot between anchor detection and cropping.

```sh
rtk proxy ffmpeg -v error -y -i ORIGINAL.png -vf crop=160:22:1105:728,scale=480:66:flags=lanczos -frames:v 1 DERIVED.png
rtk proxy tesseract DERIVED.png OUTPUT --psm 7 tsv
```

All nine FFmpeg positive TSVs recognize exact `Cancel` at 50,7,123,46 confidence 96.512077 and exact `Open` at 330,14,97,34 confidence 96.465927. The coordinate transforms above therefore stay identical. All six FFmpeg negative TSVs reject Cancel/Open: before crops contain no recognized words; adjacent crops contain only their timestamps (control, 96.494751, B, 95.454086, AB, 96.676216).

A 90 confidence threshold for each exact word is supported by all nine local positive replays (minimum 96.465927), and none of the negative outputs match the words. This threshold is fail-closed and has not yet been validated with the guest Tesseract version. A unique exact action anchor must be in the lower chooser region and paired with exact Cancel on the same derived baseline. Do not choose the first `Select` from a window title: folder-picker evidence is not retained from this failed run, so that case still needs the next cloud control. Record anchor box, crop coordinates, OCR confidence, and unscaled root click position.

Keep the active exact chooser-title and owner guard. Replace the bottom-of-xdotool-window crop with a padded crop anchored to the already-recognized rendered Open/Select row. Apply single-line OCR to that strip; 3× scale gives stronger evidence than changing the deadline. Continue requiring exact Cancel and Open/Select, then transform recognized coordinates back to root pixels, click Cancel, and require the returned rendered Send Selection heading. Do not accept the fragment `Can` globally or declare cancel/return validation complete from these still frames.

The corresponding source now rejects crops outside the saved PNG dimensions before FFmpeg can clamp their origin. It requires the chooser owner PID to match the actual LocalSend process, which all three retained GTK choosers do. An independently owned desktop portal remains unproven by this cohort and requires a separate provenance gate. Cancel/return requires the former chooser to be absent from visible windows and focus to return to the LocalSend window with the actual app PID, alongside rendered Selection. Exact label uniqueness is checked before the confidence threshold.

Native GTK accessibility-tree inspection of the active chooser's Cancel/Open push buttons could supplement a separate post-timing replay and provide bounds independently of native window-origin discrepancies. Independent audit found that libatspi automatically issues Cache.GetItems even with CACHE_NONE. Therefore, run this only in a separate replay after ALL original timing cases finish; do not insert it at the initial chooser before repeated Text measurements. Use a deadline and retain raw outputs. It must not replace rendered evidence. No accessibility-tree probe was run in this offline audit.
