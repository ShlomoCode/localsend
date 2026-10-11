package org.localsend.cloudtransport;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.os.Bundle;
import android.os.Environment;
import android.provider.MediaStore;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONObject;

/** Read-only diagnostic; queries only exact runner-owned fixture names. */
final class StorageObserver {
  static JSONObject collect(Activity activity) throws Exception {
    JSONObject config = new JSONObject(new String(readAsset(activity), StandardCharsets.UTF_8));
    JSONArray names = config.getJSONArray("observerNames");
    String run = config.getString("observerRun");
    if (!run.matches("[0-9]+") || names.length() < 1 || names.length() > 4)
      throw new IllegalArgumentException("Missing bounded runner ownership configuration");
    JSONObject report = new JSONObject();
    report.put("readOnly", true);
    report.put("unixMillis", System.currentTimeMillis());
    report.put("sdk", android.os.Build.VERSION.SDK_INT);
    report.put("targetSdk", activity.getApplicationInfo().targetSdkVersion);
    report.put("allFilesAccess", Environment.isExternalStorageManager());
    report.put("readExternalStorageGranted", activity.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED);
    JSONArray observations = new JSONArray();
    report.put("observations", observations);
    for (int n = 0; n < names.length(); n++) {
      String name = names.getString(n);
      if (!name.matches("2007-" + run + "-[a-z]+\\.txt"))
        throw new IllegalArgumentException("Refuse query outside this run's owned fixtures");
      JSONObject observation = new JSONObject();
      observations.put(observation);
      observation.put("name", name);
      File path = new File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), name);
      observation.put("path", path.getAbsolutePath());
      observation.put("exists", path.exists());
      observation.put("isFile", path.isFile());
      observation.put("readable", path.canRead());
      observation.put("bytes", path.exists() ? path.length() : JSONObject.NULL);
      JSONArray queries = new JSONArray();
      observation.put("queries", queries);
      for (int match : new int[]{MediaStore.MATCH_DEFAULT, MediaStore.MATCH_INCLUDE, MediaStore.MATCH_ONLY}) {
        JSONObject query = new JSONObject();
        queries.put(query);
        query.put("uri", MediaStore.Files.getContentUri("external").toString());
        query.put("matchTrashed", match);
        query.put("selection", "_display_name = ? AND relative_path = ?");
        query.put("arguments", new JSONArray().put(name).put("Download/"));
        String[] projection = {"_id", "_display_name", "relative_path", "is_trashed", "date_expires", "_data", "owner_package_name", "_size", "is_pending"};
        query.put("projection", new JSONArray(projection));
        Bundle args = new Bundle();
        args.putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION, "_display_name = ? AND relative_path = ?");
        args.putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, new String[]{name, "Download/"});
        args.putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, match);
        JSONArray rows = new JSONArray();
        query.put("rows", rows);
        try (Cursor cursor = activity.getContentResolver().query(MediaStore.Files.getContentUri("external"), projection, args, null)) {
          query.put("nullCursor", cursor == null);
          if (cursor != null) {
            while (cursor.moveToNext()) {
              JSONObject row = new JSONObject();
              for (int i = 0; i < projection.length; i++) row.put(projection[i], cursor.isNull(i) ? JSONObject.NULL : cursor.getString(i));
              rows.put(row);
            }
          }
        } catch (Exception error) {
          query.put("errorType", error.getClass().getName());
          query.put("error", error.toString());
        }
      }
    }
    File output = new File(activity.getExternalFilesDir(null), "storage-observer.json");
    try (FileOutputStream stream = new FileOutputStream(output)) {
      stream.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
    }
    return report;
  }

  private static byte[] readAsset(Activity activity) throws Exception {
    try (java.io.InputStream input = activity.getAssets().open("config.json"); java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream()) {
      byte[] buffer = new byte[4096];
      int count;
      while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
      return output.toByteArray();
    }
  }
}
