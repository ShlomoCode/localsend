# Favorite transition evidence

Run 38110612173, original LocalSend 1.18.2, actual portrait 1080×2400 screenshot / 1080×2178 source.

| State | Saved evidence | Observation |
| --- | --- | --- |
| Favorites | `windows-transfer/favorites-before-add.xml` / PNG at 04:10:56.133Z | Favorites, No favorite devices yet., Cancel, Add. Add enabled/displayed/clickable, bounds [668,1233][888,1377]. |
| Editor open | Missing before keyboard action | Add touch centered at (778,1305), started 04:10:56.224Z, returned HTTP 200 at 56.426Z. No source or screenshot between this touch and hide_keyboard. HTTP 200 does not prove the editor appeared. |
| Keyboard shown | Missing | No keyboard visibility query was made. hide_keyboard started immediately at 56.426Z and returned HTTP 200 at 56.925Z. |

The next source at 56.925Z–57.473Z and screenshot at 58.225Z show Favorites again, with zero EditTexts. The final failure source is semantically identical. The evidence cannot distinguish an unsuccessful Add transition from an editor dismissed by hide_keyboard. An independent review confirmed this exact missing observation.

Run 38108337095 has a separate landscape failure source with Add to favorites, Cancel and Confirm but no EditTexts. Its screenshot shows a keyboard. That separate run establishes the editor's labels; it does not fill the missing states in run 38110612173.

Next control sequence:

1. Observe Favorites and the actual Add bounds, then touch Add.
2. Wait for Add to favorites plus Confirm, save fresh editor XML/PNG.
3. Read native is_keyboard_shown and record its boolean. If true, recheck the same editor, save the pre-hide frame, then hide. If false, do not send a hide or Back action.
4. Save the post-action state and require the editor still present. Stop on disappearance. Only then discover fields, enter each value and verify actual readback before Confirm.

The next run is the 1 MiB actual application control only. Share is disabled until this gate passes.
