package org.localsend.fixture3556;
import android.app.Activity;
import android.os.*;
import android.content.*;
import android.net.Uri;
import android.provider.MediaStore;
import android.widget.*;
import java.io.*;
import java.security.MessageDigest;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import android.media.MediaMetadataRetriever;

/** Separate fixture app; uses public APIs and never changes LocalSend. */
public final class MainActivity extends Activity {
  private TextView status;
  private final ArrayList<Uri> owned=new ArrayList<>();
  private boolean busy=false;
  private Uri last;
  public void onCreate(Bundle state){
    super.onCreate(state);
    LinearLayout panel=new LinearLayout(this);panel.setOrientation(1);
    status=new TextView(this);status.setText(capacity());panel.addView(status);
    add(panel,"Stage small data",()->stage(1024*1024,false));
    add(panel,"Stage small video",()->stage(1024*1024,true));
    add(panel,"Stage 1GB video",()->stage(1000000000L,true));
    add(panel,"Stage 16GB data",()->stage(16000000000L,false));
    add(panel,"Stage 16GB video",()->stage(16000000000L,true));
    add(panel,"Share owned fixture",()->{if(last!=null){Intent i=new Intent(Intent.ACTION_SEND).setType(getContentResolver().getType(last)).putExtra(Intent.EXTRA_STREAM,last).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);startActivity(Intent.createChooser(i,"Share issue 3556 fixture"));}});
    add(panel,"Refresh capacity",()->status.setText(capacity()));
    add(panel,"Delete owned fixtures",()->{if(!busy){for(Uri u:owned)getContentResolver().delete(u,null,null);owned.clear();last=null;status.setText(capacity()+"\nDeleted this session's fixture URIs only");}});
    ScrollView scroll=new ScrollView(this);scroll.addView(panel);setContentView(scroll);
  }
  private void add(LinearLayout panel,String title,Runnable action){Button b=new Button(this);b.setText(title);b.setContentDescription(title);b.setAllCaps(false);b.setOnClickListener(v->action.run());panel.addView(b);}
  private String capacity(){StatFs s=new StatFs(Environment.getExternalStorageDirectory().getPath());return "Issue 3556 fixture helper\nAndroid="+Build.VERSION.RELEASE+" SDK="+Build.VERSION.SDK_INT+" model="+Build.MODEL+"\navailableBytes="+s.getAvailableBytes()+" totalBytes="+s.getTotalBytes();}
  private void update(String value){runOnUiThread(()->status.setText(value));}
  private void stage(long size,boolean video){
    if(busy)return;
    long free=new StatFs(Environment.getExternalStorageDirectory().getPath()).getAvailableBytes();
    if(free<size+2147483648L){update(capacity()+"\nINSUFFICIENT_STORAGE requested="+size);return;}
    busy=true;
    update(capacity()+"\nSTAGING requestedBytes="+size);
    new Thread(()->{Uri uri=null;long start=SystemClock.elapsedRealtime();try{
      String name="issue3556-"+System.currentTimeMillis()+"-"+size+(video?".mp4":".bin");
      ContentValues values=new ContentValues();values.put(MediaStore.MediaColumns.DISPLAY_NAME,name);values.put(MediaStore.MediaColumns.MIME_TYPE,video?"video/mp4":"application/octet-stream");values.put(MediaStore.MediaColumns.RELATIVE_PATH,video?"Movies/Issue3556":"Download/Issue3556");values.put(MediaStore.MediaColumns.IS_PENDING,1);
      uri=getContentResolver().insert(video?MediaStore.Video.Media.EXTERNAL_CONTENT_URI:MediaStore.Downloads.EXTERNAL_CONTENT_URI,values);if(uri==null)throw new IOException("MediaStore insert failed");owned.add(uri);
      MessageDigest hash=MessageDigest.getInstance("SHA-256");byte[] chunk=new byte[1024*1024];for(int i=0;i<chunk.length;i++)chunk[i]=(byte)(i*31+7);
      long count=0;try(OutputStream out=getContentResolver().openOutputStream(uri)){
        if(video){try(InputStream in=getAssets().open("seed.mp4")){int n;while((n=in.read(chunk))!=-1){out.write(chunk,0,n);hash.update(chunk,0,n);count+=n;}}}
        // ISO-BMFF permits a free box. Extended length keeps a 16GB MP4 valid.
        if(video){byte[] header=ByteBuffer.allocate(16).putInt(1).put(new byte[]{102,114,101,101}).putLong(size-count).array();out.write(header);hash.update(header);count+=header.length;}
        java.util.Arrays.fill(chunk,(byte)0x5a);
        long deadline=start+1800000L;
        while(count<size){if(SystemClock.elapsedRealtime()>deadline)throw new IOException("30 minute staging deadline");int n=(int)Math.min(chunk.length,size-count);out.write(chunk,0,n);hash.update(chunk,0,n);count+=n;if(count%(128*1024*1024)==0)update(capacity()+"\nstagingBytes="+count+" expected="+size);}
      }
      ContentValues ready=new ContentValues();ready.put(MediaStore.MediaColumns.IS_PENDING,0);getContentResolver().update(uri,ready,null,null);last=uri;
      StringBuilder hex=new StringBuilder();for(byte b:hash.digest())hex.append(String.format("%02x",b&255));
      String media="";
      if(video){MediaMetadataRetriever retriever=new MediaMetadataRetriever();try{retriever.setDataSource(this,uri);String duration=retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);android.graphics.Bitmap frame=retriever.getFrameAtTime(0);if(frame==null)throw new IOException("MP4 frame did not decode");media="\nmediaDurationMs="+duration+" decodedFrame="+frame.getWidth()+"x"+frame.getHeight();frame.recycle();}finally{retriever.release();}}
      update(capacity()+"\nREADY name="+name+"\nuri="+uri+"\nbytes="+count+"\nsha256="+hex+media+"\nelapsedMs="+(SystemClock.elapsedRealtime()-start));
    }catch(Exception e){if(uri!=null)getContentResolver().delete(uri,null,null);update(capacity()+"\nFAILED "+e.getClass().getSimpleName()+": "+e.getMessage());}finally{busy=false;}},"fixture-writer").start();
  }
}
