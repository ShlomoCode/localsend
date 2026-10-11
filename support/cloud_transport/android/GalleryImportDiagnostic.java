/*
 * Gal operations adapted from Gal 2.3.0.
 * Copyright (c) 2023 Midori Design Studio by @natsuk4ze
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 * 1. Redistributions of source code must retain the above copyright notice,
 *    this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution.
 * 3. Neither the name of the Midori Design Studio nor the names of its contributors
 *    may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 * OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
 * OF THE POSSIBILITY OF SUCH DAMAGE.
 */
package org.localsend.cloudtransport;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import android.provider.MediaStore;
import android.system.Os;
import android.system.StructStat;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

// Component-only experiment. It does not observe LocalSend's cache or change its code.
public final class GalleryImportDiagnostic {
  private static final long OLD_SECONDS=1739455860L;
  private static final String EXPECTED_HASH="561fa660b1ee2b0a3ab29d36c157ae238a0b27d4db0b6aa4154e892b4699a7ef";
  private static final String[] COLUMNS={"_id","_display_name","_data","relative_path","date_modified","date_added","datetaken","_size","mime_type","is_pending","owner_package_name"};

  public static String run(Context context,String filename){
    JSONObject result=new JSONObject();JSONArray cases=new JSONArray();
    try{
      result.put("evidenceLevel","component-only native extraction; no LocalSend cache observation");
      result.put("galVersion","2.3.0");result.put("sdk",Build.VERSION.SDK_INT);result.put("utcMs",System.currentTimeMillis());
      result.put("sourceReference","gal-2.3.0/android/src/main/java/studio/midoridesign/gal/GalPlugin.java: writeData, getUniqueFileUri, createContentValues");
      result.put("filename",filename);result.put("requestedMtimeSeconds",OLD_SECONDS);result.put("cases",cases);
      if(!filename.matches("issue2311-[a-zA-Z0-9-]+\\.png"))throw new IllegalArgumentException("Expected an issue2311 diagnostic PNG filename");
      File source=new File("/sdcard/Download",filename);
      if(!source.exists())source=new File("/sdcard/Pictures",filename);
      result.put("sourceBefore",fileObservation(source));
      StructStat original=Os.stat(source.getPath());
      if(original.st_mtime!=OLD_SECONDS||original.st_size!=1042||!EXPECTED_HASH.equals(hash(new FileInputStream(source)))){
        throw new IllegalArgumentException("Source must be the verified Save-to-gallery-Off PNG (1042 bytes, old mtime and expected hash)");
      }
      String runName=filename.substring(0,filename.length()-4)+"-causal-"+System.currentTimeMillis();
      File cache=new File(context.getCacheDir(),runName+".png");
      try(InputStream in=new FileInputStream(source);OutputStream out=new FileOutputStream(cache)){copy(in,out);}
      result.put("ownCacheBeforeTimestamp",fileObservation(cache));
      result.put("ownCacheSetLastModified",cache.setLastModified(OLD_SECONDS*1000));
      result.put("ownCacheAfterTimestamp",fileObservation(cache));
      if(Os.stat(cache.getPath()).st_mtime!=OLD_SECONDS)throw new IllegalStateException("Own cache timestamp was not set");
      ContentResolver resolver=context.getContentResolver();
      for(String mode:new String[]{"baseline","dbonly","filesystem"}){
        JSONObject entry=new JSONObject();entry.put("mode",mode);cases.put(entry);
        try{
          Uri uri;
          try(InputStream in=new FileInputStream(cache)){uri=writeData(resolver,in,true,runName+"-"+mode,".png",null);}
          entry.put("uri",uri.toString());
          entry.put("afterImport",observe(resolver,uri));
          String path=pathFor(resolver,uri);entry.put("path",path==null?JSONObject.NULL:path);
          if("dbonly".equals(mode)){
            ContentValues values=new ContentValues();values.put(MediaStore.MediaColumns.DATE_MODIFIED,OLD_SECONDS);
            try{entry.put("dateModifiedUpdateRows",resolver.update(uri,values,null,null));}
            catch(Exception error){entry.put("dateModifiedUpdateError",error.toString());}
          }else if("filesystem".equals(mode)){
            try{
              if(path==null)throw new IllegalStateException("Owned image URI has no filesystem path");
              entry.put("fileSetLastModified",new File(path).setLastModified(OLD_SECONDS*1000));
            }catch(Exception error){entry.put("fileSetLastModifiedError",error.toString());}
          }
          entry.put("afterOperationReopened",observe(resolver,uri));
          if(path==null){entry.put("scanError","Owned URI did not expose a path");}
          else{
            CountDownLatch scanned=new CountDownLatch(1);JSONObject callback=new JSONObject();
            try{
              MediaScannerConnection.scanFile(context,new String[]{path},new String[]{"image/png"},(scanPath,scanUri)->{
                try{callback.put("path",scanPath);callback.put("uri",scanUri==null?JSONObject.NULL:scanUri.toString());}
                catch(Exception ignored){}finally{scanned.countDown();}
              });
              entry.put("scanCompleted",scanned.await(30,TimeUnit.SECONDS));entry.put("scanCallback",callback);
            }catch(Exception error){entry.put("scanError",error.toString());}
          }
          entry.put("afterScanReopened",observe(resolver,uri));
        }catch(Exception error){entry.put("error",error.toString());}
      }
      result.put("ownCacheAfterImports",fileObservation(cache));result.put("sourceAfter",fileObservation(source));
    }catch(Exception error){try{result.put("error",error.toString());}catch(Exception ignored){}}
    return result.toString();
  }

  private static JSONObject observe(ContentResolver resolver,Uri uri)throws Exception{
    JSONObject observation=new JSONObject();
    try(Cursor cursor=resolver.query(uri,COLUMNS,null,null,null)){
      JSONArray rows=new JSONArray();
      while(cursor!=null&&cursor.moveToNext()){
        JSONObject row=new JSONObject();for(int i=0;i<COLUMNS.length;i++)row.put(COLUMNS[i],cursor.isNull(i)?JSONObject.NULL:cursor.getString(i));rows.put(row);
      }
      observation.put("mediaStore",rows);
    }catch(Exception error){observation.put("mediaStoreError",error.toString());}
    try(ParcelFileDescriptor descriptor=resolver.openFileDescriptor(uri,"r")){
      if(descriptor==null)throw new IllegalStateException("openFileDescriptor returned null");
      observation.put("uriFdStat",statObservation(Os.fstat(descriptor.getFileDescriptor())));
    }catch(Exception error){observation.put("uriFdStatError",error.toString());}
    try{observation.put("uriSha256",hash(resolver.openInputStream(uri)));}
    catch(Exception error){observation.put("uriHashError",error.toString());}
    try{String path=pathFor(resolver,uri);if(path!=null)observation.put("filesystem",fileObservation(new File(path)));}
    catch(Exception error){observation.put("filesystemError",error.toString());}
    return observation;
  }

  private static String pathFor(ContentResolver resolver,Uri uri){
    try(Cursor cursor=resolver.query(uri,new String[]{MediaStore.MediaColumns.DATA},null,null,null)){
      return cursor!=null&&cursor.moveToFirst()&&!cursor.isNull(0)?cursor.getString(0):null;
    }
  }

  private static JSONObject fileObservation(File file)throws Exception{
    JSONObject observation=new JSONObject();observation.put("path",file.getPath());
    try{observation.put("stat",statObservation(Os.stat(file.getPath())));}
    catch(Exception error){observation.put("statError",error.toString());}
    try{observation.put("sha256",hash(new FileInputStream(file)));}
    catch(Exception error){observation.put("hashError",error.toString());}
    return observation;
  }

  private static JSONObject statObservation(StructStat stat)throws Exception{
    JSONObject result=new JSONObject();result.put("mtimeSeconds",stat.st_mtime);result.put("size",stat.st_size);result.put("inode",stat.st_ino);return result;
  }

  private static String hash(InputStream stream)throws Exception{
    if(stream==null)throw new IllegalStateException("Input stream is null");
    MessageDigest digest=MessageDigest.getInstance("SHA-256");
    try(InputStream in=stream){byte[] buffer=new byte[8192];int count;while((count=in.read(buffer))!=-1)digest.update(buffer,0,count);}
    StringBuilder hex=new StringBuilder();for(byte value:digest.digest())hex.append(String.format("%02x",value&255));return hex.toString();
  }

  private static void copy(InputStream in,OutputStream out)throws java.io.IOException{
    byte[] buffer=new byte[8192];int bytesRead;while((bytesRead=in.read(buffer))!=-1)out.write(buffer,0,bytesRead);
  }

  // Gal 2.3.0 operations below retain its content values, uniqueness retry, buffer and stream closure.
  // The resolver is supplied directly rather than obtained from Flutter's pluginBinding; return the owned URI for observation.
  private static Uri writeData(ContentResolver resolver,InputStream in,boolean isImage,String name,String extension,String album)throws java.io.IOException{
    ContentValues values=createContentValues(isImage,name,extension,album);
    Uri uri=getUniqueFileUri(resolver,values,isImage,name,extension);
    try(OutputStream out=resolver.openOutputStream(uri)){
      byte[] buffer=new byte[8192];int bytesRead;
      while((bytesRead=in.read(buffer))!=-1){out.write(buffer,0,bytesRead);}
    }
    return uri;
  }

  private static Uri getUniqueFileUri(ContentResolver resolver,ContentValues values,boolean isImage,String name,String extension){
    for(int suffix=0;;suffix++){
      try{
        values.put(MediaStore.MediaColumns.DISPLAY_NAME,name+(suffix>0?suffix:"")+extension);
        return resolver.insert(isImage?MediaStore.Images.Media.EXTERNAL_CONTENT_URI:MediaStore.Video.Media.EXTERNAL_CONTENT_URI,values);
      }catch(IllegalStateException error){if(!error.getMessage().contains("Failed to build unique file"))throw error;}
    }
  }

  private static ContentValues createContentValues(boolean isImage,String name,String extension,String album){
    ContentValues values=new ContentValues();
    String dirPath=isImage||album!=null?Environment.DIRECTORY_PICTURES:Environment.DIRECTORY_MOVIES;
    if(Build.VERSION.SDK_INT<=29){
      File dir=new File(Environment.getExternalStoragePublicDirectory(dirPath),album!=null?album:"");
      if(!dir.exists())dir.mkdirs();
      String path;String n=dir.getPath()+File.separator+name;
      for(int i=0;new File(path=n+(i==0?"":i)+extension).exists();i++);
      values.put(MediaStore.MediaColumns.DATA,path);
    }else{
      String path=dirPath+(album!=null?File.separator+album:"");
      values.put(isImage?MediaStore.Images.Media.RELATIVE_PATH:MediaStore.Video.Media.RELATIVE_PATH,path);
    }
    values.put(MediaStore.MediaColumns.DISPLAY_NAME,name+extension);return values;
  }
}
