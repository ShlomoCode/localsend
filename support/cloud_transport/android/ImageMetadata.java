package org.localsend.cloudtransport;
import android.content.Context;
import android.database.Cursor;
import android.provider.MediaStore;
import android.system.Os;
import android.system.StructStat;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.FileInputStream;
import java.security.MessageDigest;

// Separate diagnostic app: ordinary shared-image permission, no product instrumentation.
public final class ImageMetadata {
 public static String read(Context context,String filename){
  JSONObject result=new JSONObject();JSONArray files=new JSONArray(),rows=new JSONArray();
  try{
   result.put("filename",filename);result.put("utcMs",System.currentTimeMillis());
   if(!filename.matches("issue2311-[a-zA-Z0-9-]+\\.png"))throw new IllegalArgumentException("Unexpected diagnostic filename");
   for(String directory:new String[]{"Pictures","Download"}){
    JSONObject entry=new JSONObject();String path="/sdcard/"+directory+"/"+filename;entry.put("path",path);
    try{StructStat stat=Os.stat(path);entry.put("filesystemMtimeSeconds",stat.st_mtime);entry.put("size",stat.st_size);
     MessageDigest digest=MessageDigest.getInstance("SHA-256");try(FileInputStream stream=new FileInputStream(path)){byte[] buffer=new byte[8192];int count;while((count=stream.read(buffer))!=-1)digest.update(buffer,0,count);}
     StringBuilder hex=new StringBuilder();for(byte b:digest.digest())hex.append(String.format("%02x",b&255));entry.put("sha256",hex.toString());
    }catch(Exception error){entry.put("error",error.toString());}
    files.put(entry);
   }
   String[] projection={"_id","_display_name","_data","date_modified","date_added","datetaken"};
   try(Cursor cursor=context.getContentResolver().query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,projection,"_display_name=?",new String[]{filename},null)){
    while(cursor!=null&&cursor.moveToNext()){JSONObject row=new JSONObject();for(int i=0;i<projection.length;i++)row.put(projection[i],cursor.isNull(i)?JSONObject.NULL:cursor.getString(i));rows.put(row);}
   }catch(Exception error){result.put("mediaStoreError",error.toString());}
   result.put("filesystem",files);result.put("mediaStore",rows);
  }catch(Exception error){try{result.put("error",error.toString());}catch(Exception ignored){}}
  return result.toString();
 }
}
