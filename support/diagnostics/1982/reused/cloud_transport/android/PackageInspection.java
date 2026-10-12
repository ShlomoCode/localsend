package org.localsend.cloudtransport;

import android.app.Activity;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import org.json.JSONArray;
import org.json.JSONObject;

/** Public read-only package metadata and APK inspection; never scans received files. */
final class PackageInspection {
  static JSONObject inspect(Activity activity) throws Exception {
    JSONObject report = new JSONObject();
    report.put("readOnly", true);
    report.put("packageName", "org.localsend.localsend_app");
    report.put("initiatingPackage", activity.getPackageName());
    report.put("inspectionId", java.util.UUID.randomUUID().toString());
    report.put("startedUnixMillis", System.currentTimeMillis());
    report.put("sdk", android.os.Build.VERSION.SDK_INT);
    report.put("successful", false);
    String operation = "PackageManager.getPackageInfo(GET_SIGNING_CERTIFICATES)";
    try {
      if (android.os.Build.VERSION.SDK_INT < 28)
        throw new UnsupportedOperationException("Inspection requires public SigningInfo API on Android 28+");
      PackageInfo info = activity.getPackageManager().getPackageInfo("org.localsend.localsend_app", PackageManager.GET_SIGNING_CERTIFICATES);
      report.put("versionName", info.versionName == null ? JSONObject.NULL : info.versionName);
      report.put("longVersionCode", info.getLongVersionCode());
      report.put("targetSdk", info.applicationInfo.targetSdkVersion);
      report.put("sourceDir", info.applicationInfo.sourceDir);
      report.put("publicSourceDir", info.applicationInfo.publicSourceDir);
      report.put("splitNames", info.splitNames == null ? new JSONArray() : new JSONArray(info.splitNames));
      report.put("splitSourceDirs", info.applicationInfo.splitSourceDirs == null ? new JSONArray() : new JSONArray(info.applicationInfo.splitSourceDirs));
      report.put("splitPublicSourceDirs", info.applicationInfo.splitPublicSourceDirs == null ? new JSONArray() : new JSONArray(info.applicationInfo.splitPublicSourceDirs));
      operation = "SigningInfo.getApkContentsSigners SHA-256";
      if (info.signingInfo == null) throw new IllegalStateException("PackageInfo returned no SigningInfo");
      JSONArray certificates = new JSONArray();
      for (Signature signer : info.signingInfo.getApkContentsSigners())
        certificates.put(hex(MessageDigest.getInstance("SHA-256").digest(signer.toByteArray())));
      report.put("signingCertificateSha256", certificates);
      report.put("hasMultipleSigners", info.signingInfo.hasMultipleSigners());
      operation = "FileInputStream SHA-256 of ApplicationInfo.sourceDir";
      report.put("baseApk", inspectFile(new File(info.applicationInfo.sourceDir)));
      JSONArray splits = new JSONArray();
      report.put("splitApks", splits);
      if (info.applicationInfo.splitSourceDirs != null) for (String path : info.applicationInfo.splitSourceDirs) {
        operation = "FileInputStream SHA-256 of split APK " + path;
        splits.put(inspectFile(new File(path)));
      }
      report.put("successful", true);
    } catch (Exception error) {
      report.put("failedOperation", operation);
      report.put("errorType", error.getClass().getName());
      report.put("error", error.toString());
    }
    report.put("completedUnixMillis", System.currentTimeMillis());
    File output = new File(activity.getExternalFilesDir(null), "localsend-apk-inspection.json");
    try (FileOutputStream stream = new FileOutputStream(output)) {
      stream.write(report.toString(2).getBytes(StandardCharsets.UTF_8));
    }
    return report;
  }

  private static JSONObject inspectFile(File path) throws Exception {
    JSONObject result = new JSONObject();
    result.put("path", path.getAbsolutePath());
    long beforeBytes = path.length(), beforeModified = path.lastModified(), bytes = 0;
    MessageDigest hash = MessageDigest.getInstance("SHA-256");
    try (FileInputStream input = new FileInputStream(path)) {
      byte[] buffer = new byte[64 * 1024];
      int count;
      while ((count = input.read(buffer)) != -1) { hash.update(buffer, 0, count); bytes += count; }
    }
    result.put("bytes", bytes);
    result.put("sha256", hex(hash.digest()));
    result.put("beforeBytes", beforeBytes);
    result.put("afterBytes", path.length());
    result.put("beforeModifiedUnixMillis", beforeModified);
    result.put("afterModifiedUnixMillis", path.lastModified());
    result.put("stableWhileRead", beforeBytes == bytes && beforeBytes == path.length() && beforeModified == path.lastModified());
    return result;
  }

  private static String hex(byte[] digest) {
    StringBuilder result = new StringBuilder();
    for (byte value : digest) result.append(String.format(java.util.Locale.ROOT, "%02x", value & 0xff));
    return result.toString();
  }
}
