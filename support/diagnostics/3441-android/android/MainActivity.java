package org.localsend.fixture3441;

import android.app.Activity;
import android.os.Bundle;
import android.os.Build;
import android.content.ContentValues;
import android.net.Uri;
import android.provider.MediaStore;
import android.widget.*;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.media.MediaMetadataRetriever;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import org.json.*;

/** Public MediaStore staging only. LocalSend is installed and driven separately. */
public final class MainActivity extends Activity {
  private TextView status;
  private volatile boolean busy;
  private JSONObject manifest;
  private final LinkedHashMap<String,Uri> owned = new LinkedHashMap<>();
  public void onCreate(Bundle saved) {
    super.onCreate(saved);
    LinearLayout panel = new LinearLayout(this); panel.setOrientation(1);
    status = new TextView(this); status.setMaxLines(8); panel.addView(status);
    try {
      manifest = new JSONObject(read(getAssets().open("manifest.json")));
      JSONObject retained = new JSONObject(getPreferences(MODE_PRIVATE).getString("owned", "{}"));
      Iterator<String> keys = retained.keys();
      while(keys.hasNext()) {String name=keys.next(); owned.put(name,Uri.parse(retained.getString(name)));}
    } catch(Exception error) {show("FIXTURE_FAILED manifest "+error.getClass().getSimpleName()); return;}
    button(panel,"Stage and verify all fixtures",()->work(()->stage()));
    for(String id:new String[]{"control","initial207","retry73"})
      button(panel,"Expose "+id+" album",()->work(()->expose(id)));
    button(panel,"Delete owned fixtures",()->work(()->{
      for(Uri uri:owned.values()) getContentResolver().delete(uri,null,null);
      owned.clear(); persist(); show("FIXTURE_DELETED");
    }));
    ScrollView scroll=new ScrollView(this); scroll.addView(panel); setContentView(scroll);
    show("FIXTURE_IDLE Android="+Build.VERSION.RELEASE+" SDK="+Build.VERSION.SDK_INT+" model="+Build.MODEL);
  }
  private void button(LinearLayout panel,String name,Runnable action) {
    Button button=new Button(this); button.setText(name); button.setContentDescription(name);
    button.setOnClickListener(v->action.run()); panel.addView(button);
  }
  private void work(Task action) {
    if(busy)return; busy=true; show("FIXTURE_WORKING");
    new Thread(()->{try{action.run();}catch(Exception error){show("FIXTURE_FAILED "+error.getClass().getSimpleName()+": "+error.getMessage());}finally{busy=false;}},"fixture3441").start();
  }
  private interface Task {void run() throws Exception;}
  private void show(String value) {runOnUiThread(()->{status.setText(value);status.setContentDescription(value);});}
  private static String read(InputStream in) throws Exception {
    try(InputStream source=in; ByteArrayOutputStream out=new ByteArrayOutputStream()) {
      byte[] buffer=new byte[8192]; int n; while((n=source.read(buffer))!=-1)out.write(buffer,0,n);
      return out.toString("UTF-8");
    }
  }
  private static String hex(byte[] digest) {
    StringBuilder result=new StringBuilder(); for(byte b:digest)result.append(String.format("%02x",b&255)); return result.toString();
  }
  private void persist() throws Exception {
    JSONObject values=new JSONObject(); for(Map.Entry<String,Uri> entry:owned.entrySet())values.put(entry.getKey(),entry.getValue().toString());
    if(!getPreferences(MODE_PRIVATE).edit().putString("owned",values.toString()).commit())throw new IOException("Ownership persistence failed");
  }
  private JSONObject verify(JSONObject file,Uri uri,int index) throws Exception {
    MessageDigest digest=MessageDigest.getInstance("SHA-256"); long count=0;
    try(InputStream in=getContentResolver().openInputStream(uri)) {
      if(in==null)throw new IOException("Cannot reopen staged URI");
      byte[] buffer=new byte[1048576]; int n;
      while((n=in.read(buffer))!=-1){count+=n;digest.update(buffer,0,n);}
    }
    String hash=hex(digest.digest());
    if(count!=file.getLong("bytes")||!hash.equals(file.getString("sha256")))throw new IOException("Readback mismatch: "+file.getString("name"));
    JSONObject result=new JSONObject().put("index",index).put("name",file.getString("name")).put("uri",uri.toString()).put("bytes",count).put("sha256",hash);
    if(file.getString("mimeType").equals("image/jpeg")) {
      try(InputStream in=getContentResolver().openInputStream(uri)) {
        Bitmap bitmap=BitmapFactory.decodeStream(in); if(bitmap==null)throw new IOException("JPEG decode failed");
        result.put("decodedWidth",bitmap.getWidth()).put("decodedHeight",bitmap.getHeight()); bitmap.recycle();
      }
    } else {
      MediaMetadataRetriever retriever=new MediaMetadataRetriever();
      try {
        retriever.setDataSource(this,uri); Bitmap frame=retriever.getFrameAtTime(0);
        if(frame==null)throw new IOException("MP4 frame decode failed");
        result.put("decodedWidth",frame.getWidth()).put("decodedHeight",frame.getHeight()); frame.recycle();
        result.put("durationMs",retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION));
      } finally {retriever.release();}
    }
    return result;
  }
  private void stage() throws Exception {
    JSONArray files=manifest.getJSONArray("files"),receipt=new JSONArray();
    for(int i=0;i<files.length();i++) {
      JSONObject file=files.getJSONObject(i); String name=file.getString("name"),mime=file.getString("mimeType");
      if(!name.matches("[A-Za-z0-9_.-]+")||!(mime.equals("image/jpeg")||mime.equals("video/mp4")))throw new IOException("Unexpected source name/type");
      Uri uri=owned.get(name);
      if(uri==null) {
        ContentValues values=new ContentValues(); values.put(MediaStore.MediaColumns.DISPLAY_NAME,name);
        values.put(MediaStore.MediaColumns.MIME_TYPE,mime);values.put(MediaStore.MediaColumns.RELATIVE_PATH,"DCIM/Issue3441_unselected");
        // Descending timestamps make explicit manifest order the Media picker order.
        values.put(MediaStore.MediaColumns.DATE_ADDED,1700000000L-i);
        values.put(MediaStore.MediaColumns.DATE_MODIFIED,1700000000L-i);
        values.put("datetaken",1700000000000L-i*1000L);
        values.put(MediaStore.MediaColumns.IS_PENDING,1);
        uri=getContentResolver().insert(mime.equals("image/jpeg")?MediaStore.Images.Media.EXTERNAL_CONTENT_URI:MediaStore.Video.Media.EXTERNAL_CONTENT_URI,values);
        if(uri==null)throw new IOException("MediaStore insert failed"); owned.put(name,uri); persist();
        try(InputStream in=getAssets().open(name);OutputStream out=getContentResolver().openOutputStream(uri)) {
          if(out==null)throw new IOException("MediaStore output unavailable");
          byte[] buffer=new byte[1048576];int n;while((n=in.read(buffer))!=-1)out.write(buffer,0,n);
        }
        ContentValues done=new ContentValues();done.put(MediaStore.MediaColumns.IS_PENDING,0);
        if(getContentResolver().update(uri,done,null,null)!=1)throw new IOException("Publish failed");
      }
      receipt.put(verify(file,uri,i));show("FIXTURE_STAGING verified="+(i+1)+"/"+files.length());
    }
    String result=new JSONObject().put("files",receipt).put("android",Build.VERSION.RELEASE).put("sdk",Build.VERSION.SDK_INT).put("model",Build.MODEL).put("verifiedUtcMs",System.currentTimeMillis()).toString();
    try(FileOutputStream out=openFileOutput("source-manifest.json",MODE_PRIVATE)){out.write(result.getBytes("UTF-8"));}
    // Retain every readback hash in the observable helper UI, without private-files access.
    show("FIXTURE_READY\n"+result);
  }
  private void expose(String id) throws Exception {
    JSONArray cases=manifest.getJSONArray("cases"),selected=null;
    for(int i=0;i<cases.length();i++)if(cases.getJSONObject(i).getString("id").equals(id))selected=cases.getJSONObject(i).getJSONArray("names");
    if(selected==null)throw new IOException("Unknown case"); Set<String> names=new HashSet<>();
    for(int i=0;i<selected.length();i++)names.add(selected.getString(i));
    if(names.size()!=selected.length())throw new IOException("Case contains duplicate source names");
    for(Map.Entry<String,Uri> entry:owned.entrySet()) {
      ContentValues values=new ContentValues();values.put(MediaStore.MediaColumns.RELATIVE_PATH,"DCIM/Issue3441_"+(names.contains(entry.getKey())?id:"unselected"));
      if(getContentResolver().update(entry.getValue(),values,null,null)!=1)throw new IOException("Album update failed");
    }
    if(!owned.keySet().containsAll(names))throw new IOException("Case source missing");
    show("FIXTURE_CASE_READY "+new JSONObject().put("id",id).put("album","Issue3441_"+id).put("names",selected).put("count",selected.length()).toString());
  }
}
