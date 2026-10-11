package org.localsend.cloudtransport;
import android.content.Context;
import android.database.Cursor;
import android.media.ExifInterface;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.provider.MediaStore;
import android.system.Os;
import android.system.StructStat;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.FileInputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.util.TimeZone;

// Separate diagnostic app: ordinary shared-media permission, no product instrumentation.
public final class ImageMetadata {
 public static String read(Context context,String filename){
  JSONObject result=new JSONObject();JSONArray files=new JSONArray(),rows=new JSONArray();
  try{
   result.put("filename",filename);result.put("utcMs",System.currentTimeMillis());
   result.put("androidSdk",android.os.Build.VERSION.SDK_INT);result.put("androidRelease",android.os.Build.VERSION.RELEASE);result.put("androidModel",android.os.Build.MODEL);
   TimeZone timezone=TimeZone.getDefault();result.put("systemTimezone",timezone.getID());result.put("systemTimezoneOffsetAtObservationMs",timezone.getOffset(System.currentTimeMillis()));
   if(!filename.matches("issue2311-[a-zA-Z0-9-]+\\.(png|jpg|mp4)"))throw new IllegalArgumentException("Unexpected diagnostic filename");
   boolean video=filename.endsWith(".mp4");
   Uri collection=video?MediaStore.Video.Media.EXTERNAL_CONTENT_URI:MediaStore.Images.Media.EXTERNAL_CONTENT_URI;
   result.put("collection",collection.toString());
   for(String directory:new String[]{video?"Movies":"Pictures","Download"}){
    JSONObject entry=new JSONObject();String path="/sdcard/"+directory+"/"+filename;entry.put("path",path);
    if(android.os.Build.VERSION.SDK_INT>=26){
     try{entry.put("filesystemMtimeMs",Files.readAttributes(Paths.get(path),BasicFileAttributes.class).lastModifiedTime().toMillis());}
     catch(Exception error){entry.put("filesystemMtimeMsError",error.toString());}
    }
    try{StructStat stat=Os.stat(path);entry.put("filesystemMtimeSeconds",stat.st_mtime);entry.put("size",stat.st_size);
     MessageDigest digest=MessageDigest.getInstance("SHA-256");try(FileInputStream stream=new FileInputStream(path)){byte[] buffer=new byte[8192];int count;while((count=stream.read(buffer))!=-1)digest.update(buffer,0,count);}
     StringBuilder hex=new StringBuilder();for(byte b:digest.digest())hex.append(String.format("%02x",b&255));entry.put("sha256",hex.toString());
    }catch(Exception error){entry.put("error",error.toString());}
    if(filename.endsWith(".jpg")){
     try(FileInputStream stream=new FileInputStream(path)){
      ExifInterface exif=new ExifInterface(stream.getFD());JSONObject tags=new JSONObject();
      for(String tag:new String[]{ExifInterface.TAG_DATETIME_ORIGINAL,ExifInterface.TAG_DATETIME_DIGITIZED,ExifInterface.TAG_DATETIME,ExifInterface.TAG_ORIENTATION,"OffsetTimeOriginal","OffsetTimeDigitized"}){
       String value=exif.getAttribute(tag);tags.put(tag,value==null?JSONObject.NULL:value);
      }
      entry.put("rawExif",tags);
     }catch(Exception error){entry.put("rawExifError",error.toString());}
    }
    if(video){
     MediaMetadataRetriever retriever=new MediaMetadataRetriever();
     try(FileInputStream stream=new FileInputStream(path)){
      retriever.setDataSource(stream.getFD());JSONObject tags=new JSONObject();
      String[] names={"date","durationMs","width","height","rotation"};
      int[] keys={MediaMetadataRetriever.METADATA_KEY_DATE,MediaMetadataRetriever.METADATA_KEY_DURATION,MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH,MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT,MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION};
      for(int i=0;i<keys.length;i++){String value=retriever.extractMetadata(keys[i]);tags.put(names[i],value==null?JSONObject.NULL:value);}
      entry.put("rawVideoMetadata",tags);
     }catch(Exception error){entry.put("rawVideoMetadataError",error.toString());}
     finally{try{retriever.release();}catch(Exception ignored){}}
    }
    files.put(entry);
   }
   String[] projection=video?new String[]{"_id","_display_name","_data","date_modified","date_added","datetaken","relative_path","_size","mime_type","width","height","duration"}:new String[]{"_id","_display_name","_data","date_modified","date_added","datetaken","relative_path","_size","mime_type","width","height","orientation"};
   try(Cursor cursor=context.getContentResolver().query(collection,projection,"_display_name=?",new String[]{filename},null)){
    while(cursor!=null&&cursor.moveToNext()){JSONObject row=new JSONObject();for(int i=0;i<projection.length;i++)row.put(projection[i],cursor.isNull(i)?JSONObject.NULL:cursor.getString(i));rows.put(row);}
   }catch(Exception error){result.put("mediaStoreError",error.toString());}
   result.put("filesystem",files);result.put("mediaStore",rows);
  }catch(Exception error){try{result.put("error",error.toString());}catch(Exception ignored){}}
  return result.toString();
 }
}
