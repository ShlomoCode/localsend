package org.localsend.diagnostic.gal2311;

import android.content.ContentProvider;
import android.content.ContentUris;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.provider.MediaStore;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.attribute.FileTime;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.Robolectric;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.Shadows;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.Implementation;
import org.robolectric.annotation.Implements;
import org.robolectric.annotation.LooperMode;
import studio.midoridesign.gal.GalPlugin;
import static org.junit.Assert.*;

// Exact GalPlugin source, real host file timestamps/bytes, controlled provider/scanner.
// No Android MediaProvider, Flutter engine, JNI, device scanner or EXIF parsing claim.
@RunWith(RobolectricTestRunner.class)
@Config(sdk=29,shadows=GalPluginComponentTest.Scanner.class)
@LooperMode(LooperMode.Mode.PAUSED)
public class GalPluginComponentTest {
    private static final byte[] PNG=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jI9sAAAAASUVORK5CYII=");
    private Context context;
    private GalleryProvider provider;
    private GalPlugin plugin;
    private Uri unrelated;
    private byte[] unrelatedHash;

    @Before public void setup()throws Exception{
        context=RuntimeEnvironment.getApplication();
        provider=Robolectric.setupContentProvider(GalleryProvider.class,"media");
        ContentValues values=new ContentValues();values.put(MediaStore.MediaColumns.DISPLAY_NAME,"unrelated-control.png");
        unrelated=provider.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,values);
        Files.write(provider.file(unrelated).toPath(),new byte[]{17,23,41});
        unrelatedHash=hash(provider.file(unrelated));
        Scanner.provider=provider;Scanner.mode=Scanner.Mode.SUCCESS;Scanner.request=null;Scanner.requested=new CountDownLatch(1);
        plugin=new GalPlugin();plugin.onAttachedToEngine(new FlutterPlugin.FlutterPluginBinding(context));
    }

    @Test public void epochZeroIsPreservedInsteadOfTreatedAsReadFailure()throws Exception{
        File source=source(0);Outcome outcome=start(source,true);await(outcome,10000);
        assertNull(outcome.error);assertEquals(1,outcome.successes.get());assertEquals(1,outcome.terminals.get());
        File saved=provider.file(provider.lastInserted);
        assertEquals(0,Files.getLastModifiedTime(saved.toPath()).toMillis());assertArrayEquals(hash(source),hash(saved));
        assertEquals(2,provider.count());assertUnrelatedIntact();
    }

    @Test public void defaultImportDoesNotOptIntoTimestampPreservation()throws Exception{
        File source=source(0);Outcome outcome=start(source,null);await(outcome,10000);
        assertNull(outcome.error);assertEquals(1,outcome.successes.get());
        assertTrue(Files.getLastModifiedTime(provider.file(provider.lastInserted).toPath()).toMillis()>0);
        assertArrayEquals(hash(source),hash(provider.file(provider.lastInserted)));assertNull(Scanner.request);assertUnrelatedIntact();
    }

    @Test public void missingSourceFailsWithoutInsertingAnItem()throws Exception{
        int inserted=provider.inserts.get();Outcome outcome=start(new File(context.getCacheDir(),"missing-source.png"),true);await(outcome,10000);
        assertNotNull(outcome.error);assertEquals(0,outcome.successes.get());assertEquals(1,outcome.terminals.get());
        assertEquals(inserted,provider.inserts.get());assertEquals(1,provider.count());assertUnrelatedIntact();
    }

    @Test public void outputFailureRemovesOnlyTheOwnedItem()throws Exception{
        provider.failOutput=true;Outcome outcome=start(source(1739455860000L),true);await(outcome,10000);
        assertNotNull(outcome.error);assertTrue(outcome.error.contains("controlled output failure"));
        assertEquals(1,provider.outputFailures.get());assertEquals(0,outcome.successes.get());assertEquals(1,outcome.terminals.get());
        assertFalse(provider.contains(provider.lastInserted));assertEquals(1,provider.deletes.size());
        assertEquals(provider.lastInserted,provider.deletes.get(0));assertEquals(1,provider.count());assertUnrelatedIntact();
    }

    @Test public void duplicateNullCallbackDoesNotReplaceTheFirstSuccessfulResult()throws Exception{
        Scanner.mode=Scanner.Mode.SUCCESS_THEN_NULL;File source=source(1739455860000L);Outcome outcome=start(source,true);await(outcome,10000);
        assertNull(outcome.error);assertEquals(1,outcome.successes.get());assertEquals(1,outcome.terminals.get());
        assertArrayEquals(hash(source),hash(provider.file(provider.lastInserted)));
        assertEquals(1739455860000L,Files.getLastModifiedTime(provider.file(provider.lastInserted).toPath()).toMillis());assertUnrelatedIntact();
    }

    @Test public void firstNullCallbackRemainsAFailureEvenIfFollowedBySuccess()throws Exception{
        Scanner.mode=Scanner.Mode.NULL_THEN_SUCCESS;Outcome outcome=start(source(1739455860000L),true);await(outcome,10000);
        assertNotNull(outcome.error);assertEquals(0,outcome.successes.get());assertEquals(1,outcome.terminals.get());
        assertFalse(provider.contains(provider.lastInserted));assertEquals(1,provider.count());assertUnrelatedIntact();
    }

    @Test(timeout=60000) public void scannerTimeoutRollsBackOwnedItemAndLateCallbackDoesNotCompleteAgain()throws Exception{
        Scanner.mode=Scanner.Mode.HOLD;long started=System.nanoTime();Outcome outcome=start(source(1739455860000L),true);
        assertTrue("Production call never reached scanner",Scanner.requested.await(10,TimeUnit.SECONDS));
        await(outcome,45000);long elapsed=TimeUnit.NANOSECONDS.toMillis(System.nanoTime()-started);
        assertNotNull(outcome.error);assertTrue(outcome.error.contains("scan timed out"));
        assertTrue("Expected the immutable 30-second timeout, got "+elapsed,elapsed>=29000&&elapsed<45000);
        Uri owned=provider.lastInserted;assertFalse(provider.contains(owned));assertEquals(1,provider.count());assertUnrelatedIntact();
        int deletions=provider.deletes.size();int terminals=outcome.terminals.get();
        Scanner.request.listener.onScanCompleted(Scanner.request.path,owned);
        Shadows.shadowOf(Looper.getMainLooper()).idle();
        assertEquals(terminals,outcome.terminals.get());assertEquals(1,terminals);assertEquals(0,outcome.successes.get());
        assertEquals(deletions,provider.deletes.size());assertFalse(provider.contains(owned));assertUnrelatedIntact();
    }

    private File source(long mtime)throws Exception{
        File source=File.createTempFile("gal-source-",".png",context.getCacheDir());Files.write(source.toPath(),PNG);
        Files.setLastModifiedTime(source.toPath(),FileTime.fromMillis(mtime));assertEquals(mtime,Files.getLastModifiedTime(source.toPath()).toMillis());return source;
    }
    private Outcome start(File source,Boolean preserve){
        Map<String,Object> arguments=new LinkedHashMap<>();arguments.put("path",source.getPath());
        if(preserve!=null)arguments.put("preserveFileModifiedTime",preserve);
        Outcome outcome=new Outcome();plugin.onMethodCall(new MethodCall("putImage",arguments),outcome);return outcome;
    }
    private void await(Outcome outcome,long timeout)throws Exception{
        long deadline=System.nanoTime()+TimeUnit.MILLISECONDS.toNanos(timeout);
        while(outcome.terminals.get()==0&&System.nanoTime()<deadline){Shadows.shadowOf(Looper.getMainLooper()).idle();Thread.sleep(10);}
        Shadows.shadowOf(Looper.getMainLooper()).idle();assertEquals("No terminal method result within bound",1,outcome.terminals.get());
    }
    private void assertUnrelatedIntact()throws Exception{assertTrue(provider.contains(unrelated));assertArrayEquals(unrelatedHash,hash(provider.file(unrelated)));}
    private static byte[] hash(File file)throws Exception{return MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(file.toPath()));}

    public static final class Outcome implements MethodChannel.Result {
        final AtomicInteger terminals=new AtomicInteger(),successes=new AtomicInteger();volatile String error;
        public void success(Object value){successes.incrementAndGet();terminals.incrementAndGet();}
        public void error(String code,String message,Object details){error=code+": "+message;terminals.incrementAndGet();}
        public void notImplemented(){error="notImplemented";terminals.incrementAndGet();}
    }
    public static final class GalleryProvider extends ContentProvider {
        private final Map<Uri,File> items=new LinkedHashMap<>();final List<Uri> deletes=new ArrayList<>();final AtomicInteger inserts=new AtomicInteger();
        volatile Uri lastInserted;volatile boolean failOutput;final AtomicInteger outputFailures=new AtomicInteger();
        public boolean onCreate(){return true;}
        public synchronized Uri insert(Uri collection,ContentValues values){
            try{
                int id=inserts.incrementAndGet();Uri uri=ContentUris.withAppendedId(collection,id);
                File file=new File(getContext().getCacheDir(),"owned-gallery-"+id+".png");Files.write(file.toPath(),new byte[0]);
                items.put(uri,file);lastInserted=uri;
                if(failOutput){
                    // Robolectric's one-argument openOutputStream swallows provider open failures.
                    // Inject a write failure so the real Gal copy/rollback path receives it.
                    Shadows.shadowOf(getContext().getContentResolver()).registerOutputStream(uri,new OutputStream(){
                        public void write(int value)throws IOException{outputFailures.incrementAndGet();throw new IOException("controlled output failure");}
                    });
                }
                return uri;
            }catch(Exception error){throw new IllegalStateException(error);}
        }
        public synchronized Cursor query(Uri uri,String[] columns,String selection,String[] args,String sort){
            MatrixCursor cursor=new MatrixCursor(columns);File file=items.get(uri);if(file!=null){Object[] values=new Object[columns.length];
                for(int i=0;i<columns.length;i++){if(MediaStore.MediaColumns.DATA.equals(columns[i]))values[i]=file.getAbsolutePath();}
                cursor.addRow(values);
            }return cursor;
        }
        public synchronized ParcelFileDescriptor openFile(Uri uri,String mode)throws FileNotFoundException{
            File file=items.get(uri);if(file==null)throw new FileNotFoundException(uri.toString());
            return ParcelFileDescriptor.open(file,ParcelFileDescriptor.parseMode(mode));
        }
        public synchronized int delete(Uri uri,String selection,String[] args){
            deletes.add(uri);File file=items.remove(uri);if(file==null)return 0;
            if(!file.delete())throw new IllegalStateException("Controlled destination delete failed");return 1;
        }
        public int update(Uri uri,ContentValues values,String selection,String[] args){throw new UnsupportedOperationException();}
        public String getType(Uri uri){return "image/png";}
        synchronized File file(Uri uri){return items.get(uri);}
        synchronized boolean contains(Uri uri){return items.containsKey(uri);}
        synchronized int count(){return items.size();}
        synchronized Uri uriFor(String path){for(Map.Entry<Uri,File> item:items.entrySet())if(item.getValue().getAbsolutePath().equals(path))return item.getKey();return null;}
    }
    @Implements(MediaScannerConnection.class)
    public static final class Scanner {
        enum Mode{SUCCESS,SUCCESS_THEN_NULL,NULL_THEN_SUCCESS,HOLD}
        static volatile Mode mode;static volatile GalleryProvider provider;static volatile Request request;static CountDownLatch requested;
        static final class Request {
            final String path;final MediaScannerConnection.OnScanCompletedListener listener;
            Request(String path,MediaScannerConnection.OnScanCompletedListener listener){this.path=path;this.listener=listener;}
        }
        @Implementation public static void scanFile(Context context,String[] paths,String[] mimeTypes,MediaScannerConnection.OnScanCompletedListener listener){
            request=new Request(paths[0],listener);requested.countDown();Uri uri=provider.uriFor(paths[0]);
            if(mode==Mode.HOLD)return;
            if(mode==Mode.NULL_THEN_SUCCESS)listener.onScanCompleted(paths[0],null);
            listener.onScanCompleted(paths[0],uri);
            if(mode==Mode.SUCCESS_THEN_NULL)listener.onScanCompleted(paths[0],null);
        }
    }
}
