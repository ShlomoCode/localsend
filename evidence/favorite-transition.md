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

## Observed complete transition in run 38111740390

Favorites → Add to favorites editor → native keyboard shown was now saved before any hide action. The pre-hide editor XML has three enabled/displayed/clickable EditTexts: Device name empty, bounds [192,441][888,585]; IP empty and focused, [192,708][888,852]; Port 53317, [192,975][888,1020]. Confirm is enabled/displayed/clickable at [590,1092][888,1236], visibly above the keyboard in the screenshot. Native is_keyboard_shown returned true at 04:32:35.259Z. The post-hide XML then has no editor, fields or Confirm. No field input was attempted. Independent review confirmed these attributes and the screenshot.

The next control uses the observed fields directly and removes hide_keyboard entirely. After each field input it verifies actual text and saves a screenshot. It reobserves Confirm bounds after filling, because focusing Port may change the keyboard and layout. This is a diagnostic automation correction; it does not establish a LocalSend application defect.
