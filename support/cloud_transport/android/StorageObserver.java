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
    android.content.SharedPreferences registrations = activity.getSharedPreferences("owned-observer-rows", Activity.MODE_PRIVATE);
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
      observation.put("nativeStat", stat(path));
      JSONArray queries = new JSONArray();
      observation.put("queries", queries);
      String registrationKey = run + ":" + name;
      java.util.Set<String> ownedIds = new java.util.HashSet<>(registrations.getStringSet(registrationKey, java.util.Collections.emptySet()));
      observation.put("registeredIdsBefore", new JSONArray(ownedIds));
      for (int match : new int[]{MediaStore.MATCH_DEFAULT, MediaStore.MATCH_INCLUDE, MediaStore.MATCH_ONLY}) {
        JSONObject query = new JSONObject();
        queries.put(query);
        query.put("uri", MediaStore.Files.getContentUri("external").toString());
        query.put("matchTrashed", match);
        // The baseline proves ownership of row IDs. Follow those exact IDs if
        // Trash changes the display name or moves the row outside Download/.
        String selection = "_display_name = ? OR _data = ?";
        java.util.ArrayList<String> selectionArgs = new java.util.ArrayList<>();
        selectionArgs.add(name);
        selectionArgs.add(path.getAbsolutePath());
        for (String id : ownedIds) { selection += " OR _id = ?"; selectionArgs.add(id); }
        query.put("selection", selection);
        query.put("arguments", new JSONArray(selectionArgs));
        String[] projection = {"_id", "_display_name", "relative_path", "is_trashed", "date_expires", "_data", "owner_package_name", "_size", "is_pending"};
        query.put("projection", new JSONArray(projection));
        Bundle args = new Bundle();
        args.putString(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION, selection);
        args.putStringArray(android.content.ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selectionArgs.toArray(new String[0]));
        args.putInt(MediaStore.QUERY_ARG_MATCH_TRASHED, match);
        // Direct FUSE-created files can be pending even while path reads work.
        // Include pending rows explicitly; capture the returned flag and errors.
        args.putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE);
        query.put("matchPending", MediaStore.MATCH_INCLUDE);
        JSONArray rows = new JSONArray();
        query.put("rows", rows);
        try (Cursor cursor = activity.getContentResolver().query(MediaStore.Files.getContentUri("external"), projection, args, null)) {
          query.put("nullCursor", cursor == null);
          if (cursor != null) {
            while (cursor.moveToNext()) {
              JSONObject row = new JSONObject();
              for (int i = 0; i < projection.length; i++) row.put(projection[i], cursor.isNull(i) ? JSONObject.NULL : cursor.getString(i));
              String id = row.getString("_id");
              row.put("previouslyRegisteredId", ownedIds.contains(id));
              if (name.equals(row.optString("_display_name")) || path.getAbsolutePath().equals(row.optString("_data"))) ownedIds.add(id);
              if (ownedIds.contains(id) && !row.isNull("_data")) row.put("nativeStat", stat(new File(row.getString("_data"))));
              if (ownedIds.size() > 8) throw new IllegalStateException("Ambiguous fixture ownership: more than eight matching row IDs");
              rows.put(row);
            }
          }
        } catch (Exception error) {
          query.put("errorType", error.getClass().getName());
          query.put("error", error.toString());
        }
      }
      registrations.edit().putStringSet(registrationKey, ownedIds).apply();
      observation.put("registeredIdsAfter", new JSONArray(ownedIds));
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

  private static JSONObject stat(File path) throws Exception {
    JSONObject result = new JSONObject();
    result.put("path", path.getAbsolutePath());
    try {
      android.system.StructStat stat = android.system.Os.stat(path.getAbsolutePath());
      result.put("bytes", stat.st_size);
      result.put("inode", stat.st_ino);
      result.put("device", stat.st_dev);
      result.put("uid", stat.st_uid);
    } catch (android.system.ErrnoException error) {
      result.put("errno", error.errno);
      result.put("error", error.toString());
    }
    return result;
  }
}
