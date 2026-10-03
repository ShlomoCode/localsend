package proof;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.net.Uri;
import java.util.ArrayList;
import java.util.List;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34, manifest = Config.NONE)
public class NullFilesCompletionTest {
    private Activity activity;
    private ClipboardManager clipboard;
    private NullFilesReaders readers;

    @Before public void setUp() {
        activity = Robolectric.buildActivity(Activity.class).setup().get();
        clipboard = (ClipboardManager) activity.getSystemService(Context.CLIPBOARD_SERVICE);
        readers = new NullFilesReaders(activity);
        clipboard.clearPrimaryClip();
    }

    private static class CapturingResult implements NativeResult {
        int completions;
        Object value;
        @Override public void success(Object result) { completions++; value = result; }
    }

    @Test public void nullPrimaryClipBaselineNeverRepliesPatchedCompletesOnceWithEmptyList() {
        assertNull(clipboard.getPrimaryClip());
        CapturingResult before = new CapturingResult();
        CapturingResult after = new CapturingResult();
        readers.baseline(before);
        readers.patched(after);
        assertEquals("baseline Dart Future has no callback", 0, before.completions);
        assertEquals(1, after.completions);
        assertEquals(List.of(), after.value);
        System.out.println("NULL_FILES baselineCallbacks=" + before.completions + " patchedCallbacks=" + after.completions + " result=" + after.value);
    }

    @Test public void twoUrisHaveSameSingleCompletionBeforeAndAfter() {
        Uri first = Uri.parse("content://clipboard.proof/document/a.txt");
        Uri second = Uri.parse("content://clipboard.proof/document/b.txt");
        ClipData clip = ClipData.newRawUri("files", first);
        clip.addItem(new ClipData.Item(second));
        clipboard.setPrimaryClip(clip);
        CapturingResult before = new CapturingResult();
        CapturingResult after = new CapturingResult();
        readers.baseline(before);
        readers.patched(after);
        assertEquals(1, before.completions);
        assertEquals(1, after.completions);
        assertEquals(List.of(first.toString(), second.toString()), before.value);
        assertEquals(before.value, after.value);
    }

    @Test public void plainTextHasSameSingleEmptyListCompletionBeforeAndAfter() {
        clipboard.setPrimaryClip(ClipData.newPlainText("text", "ordinary copied text"));
        CapturingResult before = new CapturingResult();
        CapturingResult after = new CapturingResult();
        readers.baseline(before);
        readers.patched(after);
        assertEquals(1, before.completions);
        assertEquals(1, after.completions);
        assertEquals(List.of(), before.value);
        assertEquals(before.value, after.value);
    }
}
