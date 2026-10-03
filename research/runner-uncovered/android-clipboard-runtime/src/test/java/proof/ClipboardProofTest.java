package proof;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.ProviderInfo;
import android.content.res.AssetFileDescriptor;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import org.robolectric.shadows.ShadowContentResolver;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 34, manifest = Config.NONE)
public class ClipboardProofTest {
    private static final Uri TEXT = Uri.parse("content://clipboard.proof/document/TAIR10_GFF3_genes.gff");
    private static final Uri IMAGE = Uri.parse("content://clipboard.proof/document/image.png");
    private Activity activity;
    private ClipboardManager clipboard;
    private DataProvider provider;

    @Before public void setUp() {
        activity = Robolectric.buildActivity(Activity.class).setup().get();
        clipboard = (ClipboardManager) activity.getSystemService(Context.CLIPBOARD_SERVICE);
        provider = new DataProvider();
        ProviderInfo info = new ProviderInfo();
        info.authority = "clipboard.proof";
        info.exported = true;
        provider.attachInfo(RuntimeEnvironment.getApplication(), info);
        ShadowContentResolver.registerProviderInternal(info.authority, provider);
        clipboard.clearPrimaryClip();
    }

    private Object raw() {
        AtomicReference<Object> result = new AtomicReference<>();
        new NativeRawClipboard(activity).invoke(result::set);
        return result.get();
    }

    // Exact URI enumeration used by installed PasteboardPlugin.files(), expressed in Java.
    // Uses real Android ClipData; it does not coerce text or read provider streams.
    private List<String> fileFallback() {
        List<String> files = new ArrayList<>();
        ClipData clip = clipboard.getPrimaryClip();
        if (clip != null) for (int i = 0; i < clip.getItemCount(); i++) {
            Uri uri = clip.getItemAt(i).getUri();
            if (uri != null) files.add(uri.toString());
        }
        return files;
    }

    @Test public void copiedTextFileBaselineLoadsEntireProviderTextPatchedReadDoesNot() {
        clipboard.setPrimaryClip(ClipData.newUri(activity.getContentResolver(), "copied file", TEXT));
        assertTrue(clipboard.getPrimaryClipDescription().hasMimeType("text/*"));
        CharSequence baseline = new FlutterBaseline(activity).read();
        assertNotNull(baseline);
        assertEquals(DataProvider.SIZE, baseline.length());
        assertEquals(provider.payload, baseline.toString());
        assertTrue("coerceToText must read a provider stream", provider.openCount >= 2);
        System.out.println("BASELINE chars=" + baseline.length() + " providerOpens=" + provider.openCount);
        provider.openCount = 0;
        assertNull(raw());
        assertEquals(List.of(TEXT.toString()), fileFallback());
        assertEquals("raw text and URI fallback must not open provider content", 0, provider.openCount);
        System.out.println("PATCHED rawText=null fileURI=" + fileFallback() + " providerOpens=" + provider.openCount);
    }

    @Test public void realPlainTextIncludingLargeTextRemainsUnchanged() {
        clipboard.setPrimaryClip(ClipData.newPlainText("plain", provider.payload));
        assertEquals(provider.payload, new FlutterBaseline(activity).read().toString());
        assertEquals(provider.payload, raw());
        assertEquals(0, provider.openCount);
    }

    @Test public void mixedExplicitTextAndContentUriKeepsExplicitTextPrecedence() {
        clipboard.setPrimaryClip(new ClipData("mixed", new String[]{"text/plain"},
                new ClipData.Item("https://example.com/path", null, null, TEXT)));
        assertEquals("https://example.com/path", new FlutterBaseline(activity).read().toString());
        assertEquals("https://example.com/path", raw());
        assertEquals(0, provider.openCount);
    }

    @Test public void httpsUriWithoutExplicitTextKeepsExistingNullTextBehavior() {
        Uri url = Uri.parse("https://example.com/path");
        clipboard.setPrimaryClip(ClipData.newRawUri("url", url));
        assertNull(new FlutterBaseline(activity).read());
        assertNull(raw());
        assertEquals(List.of(url.toString()), fileFallback());
        assertEquals(0, provider.openCount);
    }

    @Test public void nonTextImageNeverGetsCoercedIntoText() {
        clipboard.setPrimaryClip(ClipData.newUri(activity.getContentResolver(), "image", IMAGE));
        assertFalse(clipboard.getPrimaryClipDescription().hasMimeType("text/*"));
        assertNull(new FlutterBaseline(activity).read());
        provider.openCount = 0;
        assertNull(raw());
        assertEquals(List.of(IMAGE.toString()), fileFallback());
        assertEquals(0, provider.openCount);
    }

    @Test public void nullClipboardReturnsNullWithoutProviderReads() {
        assertNull(new FlutterBaseline(activity).read());
        assertNull(raw());
        assertEquals(0, provider.openCount);
    }

    @Test @Config(shadows = DeniedClipboard.class)
    public void securityExceptionIsCaughtByBothTextReaders() {
        assertNull(new FlutterBaseline(activity).read());
        assertNull(raw());
    }

    @Implements(ClipboardManager.class)
    public static class DeniedClipboard {
        @Implementation protected boolean hasPrimaryClip() { return true; }
        @Implementation protected ClipData getPrimaryClip() { throw new SecurityException("clipboard denied"); }
        @Implementation protected void clearPrimaryClip() {}
    }

    public static class DataProvider extends ContentProvider {
        static final int SIZE = 4 * 1024 * 1024;
        int openCount;
        File textFile;
        String payload;
        @Override public boolean onCreate() {
            try {
                payload = "chr1\tTAIR10\tgene\t1\t2\t.\t+\t.\tID=test\n";
                payload = payload.repeat(SIZE / payload.length() + 1).substring(0, SIZE);
                textFile = File.createTempFile("clipboard-gff-", ".gff", getContext().getCacheDir());
                Files.writeString(textFile.toPath(), payload, StandardCharsets.UTF_8);
                return true;
            } catch (IOException e) { throw new RuntimeException(e); }
        }
        @Override public String getType(Uri uri) { return uri.equals(IMAGE) ? "image/png" : "text/plain"; }
        @Override public String[] getStreamTypes(Uri uri, String filter) {
            return uri.equals(TEXT) && (filter.equals("text/*") || filter.equals("*/*")) ? new String[]{"text/plain"} : null;
        }
        @Override public AssetFileDescriptor openTypedAssetFile(Uri uri, String filter, Bundle opts) throws FileNotFoundException {
            openCount++;
            if (!uri.equals(TEXT) || !(filter.equals("text/*") || filter.equals("*/*") || filter.equals("text/plain"))) {
                throw new FileNotFoundException("unsupported type " + filter);
            }
            return new AssetFileDescriptor(ParcelFileDescriptor.open(textFile, ParcelFileDescriptor.MODE_READ_ONLY), 0, textFile.length());
        }
        @Override public Cursor query(Uri u, String[] p, String s, String[] a, String o) { return null; }
        @Override public Uri insert(Uri u, ContentValues v) { return null; }
        @Override public int delete(Uri u, String s, String[] a) { return 0; }
        @Override public int update(Uri u, ContentValues v, String s, String[] a) { return 0; }
    }
}
