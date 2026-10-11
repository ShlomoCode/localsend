# Retained Folder opener audit — run 38173103833

Product source is unmodified. This audit only reads retained artifacts and writes derived PNGs, TSVs, and this report. No application, build, test, VM, or job was started. Original artifacts are in `/tmp/2754-packaged-38173103833-compact/comparison/{control-system,B-system,AB-package}`. All three Folder-before and File-returned full images were visually inspected.

## Actual run boundary

File opening, Cancel, and return succeeded in all three variants. Each logged a Cancel click at root (1142,738), followed by a returned screenshot showing the Send page with Selection and File/Folder/Text/Paste controls. Each return event reports no visible chooser windows and active LocalSend owned by the original app PID:

| Variant | App PID | Old chooser | Returned window |
|---|---:|---:|---:|
| control-system |4489|41950857|41943043|
| B-system |4482|37756753|37748739|
| AB-package |4619|39854860|39845891|

File button OCR in all three live variants recognized Cancel/Open at confidences 96.605789/96.425331. The actual live coordinate click plus disappearance/focus evidence and the returned rendered page support cancellation and return; this is stronger than a retained chooser still alone.

All three scenarios then fail in `click_word` before any Folder click: `Missing UI label Folder in keyboard-on-folder-control-before`. Events end at the Folder-before screenshot. No Folder native chooser opened, and no Folder cancellation was executed. Official plugin source defaults describing Choose Directory/Open/Cancel are supplementary expectations for the future control, not evidence from this run.

## Opener OCR defect

The visible full Folder label is present in all three before screenshots. Whole-screen sparse OCR truncates it:

| Variant | Recognized text | root left,top,width,height | confidence |
|---|---|---|---:|
| control-system |Folde|737,444,33,11|87.568878|
| B-system |Fol|926,444,17,11|95.350601|
| AB-package |Fol|926,444,17,11|95.350601|

The existing Selection-anchored fallback is only applied to Text. Selection is at root (594,375) in control and (784,375) in B/AB. The app's visible horizontal position shifts by 190 pixels between variants; use the rendered anchor from the same saved screenshot.

## Exact retained replay

Extend targeted picker recognition to the Folder opener, using the already-established picker rectangle: left=Selection.left−8, top=Selection.top+24, width 460, height 80. Apply FFmpeg 3× Lanczos scaling and Tesseract PSM 11 to the SAME saved full screenshot, avoiding another scrot between anchor detection and cropping.

```sh
rtk proxy ffmpeg -v error -y -i ORIGINAL.png -vf crop=460:80:LEFT:399,scale=1380:240:flags=lanczos -frames:v 1 DERIVED.png
rtk proxy tesseract DERIVED.png OUTPUT --psm 11 tsv
```

LEFT is 586 for control and 776 for B/AB. Host Tesseract 5.5.3 recognizes all three positive crops identically: exact File 96.836243, Folder 95.629387, Text 96.820099, Paste 96.126106. The unique Folder box is scaled left 450, top 135, width 123, height 33.

Transform back with rootX=cropX+(left+width/2)/3, rootY=cropY+(top+height/2)/3. Folder center is (756.5,449.5) for control and (946.5,449.5) for B/AB; integer clicks (756,450) or (946,450) are within the visible respective Folder buttons. Require exact Folder and confidence≥90, which all three positive crops satisfy. Do not accept Fol/Folde fragments. Raw crops and TSVs are saved as VARIANT-picker.png/.tsv.

## Negative controls and required modal guard

Three same-size adjacent crops (top 479) and three File-chooser non-Send crops (same picker coordinates) reject exact Folder. Adjacent outputs include Nearby/devices and symbols; native chooser crops yield only partial timestamps. Raw outputs are retained under `*-negative-adjacent*` and `*-negative-chooser*`.

CRITICAL: all three modal crops from keyboard-on-65.png still recognize the dimmed background Folder with confidence 96.484970. Thus exact label plus confidence alone fails the modal negative. The corrected coordinate modal outputs are `*-negative-modal-correct*`; the earlier exploratory modal crops also remain, clearly named separately.

A guard based on the existing fresh-Text modal region discriminates all three negatives. From the SAME full image, crop left=Selection.left+1, top=Selection.top+184, width 310, height 220; PSM 6 without scaling:

```sh
rtk proxy ffmpeg -v error -y -i ORIGINAL.png -vf crop=310:220:MODAL_LEFT:559 -frames:v 1 MODAL.png
rtk proxy tesseract MODAL.png OUTPUT --psm 6 tsv
```

MODAL_LEFT is 595 for control, 785 for B/AB. All three modal negatives recognize exact Type 96.254738 and message 96.917572; all three positive Folder-before guard crops contain neither word (only Troubleshoc 91.050735). Guard crops/TSVs are saved as `*-modal-gate*` and `*-positive-gate*`. Reject picker activation when Type/message are both present. This guard only covers the specific retained MessageInputDialog; it is not a universal modal detector.

The supported correction therefore combines the exact Selection-anchored picker fallback with a same-frame no-MessageInputDialog guard before clicking. Retain active-window title/ownership checks and existing native chooser/cancel/return gates. Local retained processing is evidence for these frames only; guest OCR and the actual Folder opening/cancel/return remain for the next cloud control. No conclusion about original Text timing follows from this opener audit.
