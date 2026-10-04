package proof;
import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.net.Uri;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import static org.junit.Assert.*;
@RunWith(RobolectricTestRunner.class)
@Config(sdk=34, manifest=Config.NONE)
public class FreshHasClipboardContentTest {
    private Activity activity;
    private ClipboardManager clipboard;
    @Before public void setup() {
        activity = Robolectric.buildActivity(Activity.class).setup().get();
        clipboard = (ClipboardManager) activity.getSystemService(Context.CLIPBOARD_SERVICE);
        clipboard.clearPrimaryClip();
    }
    private boolean read() {
        AtomicReference<Object> result = new AtomicReference<>();
        AtomicInteger calls = new AtomicInteger();
        new HasClipboardContent(activity).invoke(value -> { result.set(value); calls.incrementAndGet(); });
        assertEquals(1,calls.get());
        assertTrue(result.get() instanceof Boolean);
        return (Boolean) result.get();
    }
    @Test public void emptyClipboardIsFalse() { assertFalse(read()); }
    @Test public void ordinaryTextIsTrue() {
        clipboard.setPrimaryClip(ClipData.newPlainText("plain","ordinary text"));
        assertTrue(read());
    }
    @Test public void twoCopiedFileUrisAreTrue() {
        ClipData files = ClipData.newRawUri("files",Uri.parse("content://proof/a"));
        files.addItem(new ClipData.Item(Uri.parse("content://proof/b")));
        clipboard.setPrimaryClip(files);
        assertTrue(read());
    }
    @Test public void imageUriIsTrue() {
        clipboard.setPrimaryClip(new ClipData("image",new String[]{"image/png"},new ClipData.Item(Uri.parse("content://proof/image.png"))));
        assertTrue(read());
    }
}
