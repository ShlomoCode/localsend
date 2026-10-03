package proof;
import android.app.Activity;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.ClipData;
import android.content.res.AssetFileDescriptor;
import android.net.Uri;
import android.util.Log;
import java.io.FileNotFoundException;
import java.io.IOException;
public class FlutterBaseline {
  private static final String TAG = "FlutterBaseline";
  private final Activity activity;
  public FlutterBaseline(Activity activity) { this.activity = activity; }
  public CharSequence read() { return getClipboardData(PlatformChannel.ClipboardContentFormat.PLAIN_TEXT); }
  static class PlatformChannel { enum ClipboardContentFormat { PLAIN_TEXT } }
  private CharSequence getClipboardData(PlatformChannel.ClipboardContentFormat format) {
    ClipboardManager clipboard =
        (ClipboardManager) activity.getSystemService(Context.CLIPBOARD_SERVICE);

    if (!clipboard.hasPrimaryClip()) return null;

    CharSequence itemText = null;
    try {
      ClipData clip = clipboard.getPrimaryClip();
      if (clip == null) return null;
      if (format == null || format == PlatformChannel.ClipboardContentFormat.PLAIN_TEXT) {
        ClipData.Item item = clip.getItemAt(0);
        // First, try getting clipboard data as text; no further processing
        // required if so.
        itemText = item.getText();
        if (itemText == null) {
          // Clipboard data does not contain text, so check whether or not it
          // contains a URI to extract text from.
          Uri itemUri = item.getUri();

          if (itemUri == null) {
            Log.w(
                TAG, "Clipboard item contained no textual content nor a URI to retrieve it from.");
            return null;
          }

          // Will only try to extract text from URI if it has the content scheme.
          String uriScheme = itemUri.getScheme();

          if (!uriScheme.equals("content")) {
            Log.w(
                TAG,
                "Clipboard item contains a Uri with scheme '" + uriScheme + "'that is unhandled.");
            return null;
          }

          AssetFileDescriptor assetFileDescriptor =
              activity.getContentResolver().openTypedAssetFileDescriptor(itemUri, "text/*", null);

          // Safely return clipboard data coerced into text; will return either
          // itemText or text retrieved from its URI.
          itemText = item.coerceToText(activity);
          if (assetFileDescriptor != null) assetFileDescriptor.close();
        }

        return itemText;
      }
    } catch (SecurityException e) {
      Log.w(
          TAG,
          "Attempted to get clipboard data that requires additional permission(s).\n"
              + "See the exception details for which permission(s) are required, and consider adding them to your Android Manifest as described in:\n"
              + "https://developer.android.com/guide/topics/permissions/overview",
          e);
      return null;
    } catch (FileNotFoundException e) {
      Log.w(TAG, "Clipboard text was unable to be received from content URI.");
      return null;
    } catch (IOException e) {
      Log.w(TAG, "Failed to close AssetFileDescriptor while trying to read text from URI.", e);
      return itemText;
    }

    return null;
  }

}
