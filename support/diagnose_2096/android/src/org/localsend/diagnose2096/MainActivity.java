package org.localsend.diagnose2096;

import android.app.Activity;
import android.content.ContentValues;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ProviderInfo;
import android.content.pm.ResolveInfo;
import android.content.pm.Signature;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.DocumentsContract;
import android.provider.MediaStore;
import android.view.View;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Separate diagnostic app; all grants come from the platform picker. */
public final class MainActivity extends Activity {
    private static final int TREE_REQUEST = 2096;
    private static final int REQUESTED_TREE_FLAGS = Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION;
    private static final int MAX_FILES = 20, MAX_ROWS = 100, MAX_DEPTH = 5;
    private static final long MAX_BYTES = 5L * 1024 * 1024;
    private static final String[] ASSETS = {"Download/ls2096-note.txt", "Download/ls2096-table.csv",
            "Download/Issue2096/Nested/ls2096-note.txt"};
    private final List<Button> buttons = new ArrayList<Button>();
    private TextView status, result;
    private String route;
    private boolean busy;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        route = state == null ? null : state.getString("route");
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        status = new TextView(this);
        status.setId(1001);
        layout.addView(status);
        addButton(layout, "STAGE_FIXTURES", new Runnable() { public void run() { work("STAGING", new Task() {
            public JSONObject run() throws Exception { return stage(); }
        }); }});
        addButton(layout, "INSPECT_DOWNLOADS_TREE", new Runnable() { public void run() { choose("downloads"); }});
        addButton(layout, "INSPECT_DEVICE_DOWNLOAD_TREE", new Runnable() { public void run() { choose("device_download"); }});
        addButton(layout, "CLEANUP_FIXTURES", new Runnable() { public void run() { work("CLEANING", new Task() {
            public JSONObject run() throws Exception { return cleanup(); }
        }); }});
        result = new TextView(this);
        result.setId(1002);
        result.setTextIsSelectable(true);
        layout.addView(result);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(layout);
        setContentView(scroll);
        try { publish(read("last-result.json")); } catch (Exception e) { setStatus("READY"); }
    }

    @Override public void onSaveInstanceState(Bundle state) {
        state.putString("route", route);
        super.onSaveInstanceState(state);
    }

    private void addButton(LinearLayout layout, String label, final Runnable action) {
        Button button = new Button(this);
        button.setText(label);
        button.setContentDescription(label);
        button.setOnClickListener(new View.OnClickListener() { public void onClick(View v) { if (!busy) action.run(); }});
        layout.addView(button);
        buttons.add(button);
    }

    private void setStatus(String text) {
        status.setText(text);
        status.setContentDescription("DIAG2096_STATUS:" + text);
    }

    private void choose(String selectedRoute) {
        route = selectedRoute;
        setStatus("SELECTING_TREE");
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        intent.addFlags(REQUESTED_TREE_FLAGS);
        startActivityForResult(intent, TREE_REQUEST);
    }

    @Override protected void onActivityResult(int request, int response, Intent data) {
        super.onActivityResult(request, response, data);
        if (request != TREE_REQUEST) return;
        if (response != RESULT_OK || data == null || data.getData() == null) {
            try { publish(new JSONObject().put("status", "TREE_REJECTED").put("route", route).put("admitted", false)
                    .put("reason", "Picker cancelled or returned no tree grant")); } catch (Exception ignored) { setStatus("ERROR"); }
            return;
        }
        final Uri tree = data.getData();
        final String selectedRoute = route;
        final int returnedGrantFlags = data.getFlags();
        try {
            if ((data.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION) == 0) throw new Exception("No read grant returned");
            getContentResolver().takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION);
            work("INSPECTING", new Task() { public JSONObject run() throws Exception { return inspect(tree, selectedRoute, returnedGrantFlags); }});
        } catch (Exception e) { error(e); }
    }

    private interface Task { JSONObject run() throws Exception; }
    private void work(String state, final Task task) {
        busy = true;
        for (Button button : buttons) button.setEnabled(false);
        setStatus(state);
        new Thread(new Runnable() { public void run() {
            try {
                final JSONObject value = task.run();
                write("last-result.json", value);
                runOnUiThread(new Runnable() { public void run() { publish(value); finishWork(); }});
            } catch (final Exception e) {
                runOnUiThread(new Runnable() { public void run() { error(e); finishWork(); }});
            }
        }}, "issue2096-helper").start();
    }

    private void finishWork() { busy = false; for (Button button : buttons) button.setEnabled(true); }
    private void error(Exception e) {
        try { publish(new JSONObject().put("status", "ERROR").put("error", e.toString())); }
        catch (Exception ignored) { setStatus("ERROR"); }
    }
    private void publish(JSONObject value) {
        setStatus(value.optString("status", "READY"));
        String json = value.toString();
        result.setText(json);
        result.setContentDescription("DIAG2096_JSON:" + json);
    }

    private JSONObject stage() throws Exception {
        File inventory = new File(getFilesDir(), "fixtures.json");
        if (inventory.exists()) {
            JSONObject existing = read("fixtures.json");
            if (existing.getJSONArray("fixtures").length() != 3 || !existing.optBoolean("complete")) {
                throw new Exception("Partial fixture staging exists; cleanup before staging again");
            }
            verifyFixtures(existing.getJSONArray("fixtures"));
            existing.put("status", "STAGED").put("installedLocalSend", installedLocalSend()).put("resolvedTreePicker", resolvedTreePicker());
            write("fixtures.json", existing);
            return existing;
        }
        JSONArray fixtures = new JSONArray();
        JSONObject saved = new JSONObject().put("status", "STAGING").put("complete", false).put("fixtures", fixtures);
        write("fixtures.json", saved);
        for (String asset : ASSETS) {
            byte[] bytes;
            try (InputStream source = getAssets().open("fixtures/" + asset)) { bytes = readSmall(source, 4096); }
            int slash = asset.lastIndexOf('/');
            ContentValues values = new ContentValues();
            values.put(MediaStore.MediaColumns.DISPLAY_NAME, asset.substring(slash + 1));
            values.put(MediaStore.MediaColumns.RELATIVE_PATH, asset.substring(0, slash + 1));
            values.put(MediaStore.MediaColumns.MIME_TYPE, asset.endsWith(".csv") ? "text/csv" : "text/plain");
            values.put(MediaStore.MediaColumns.IS_PENDING, 1);
            Uri uri = getContentResolver().insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
            if (uri == null) throw new Exception("MediaStore insert returned null");
            JSONObject fixture = new JSONObject().put("asset", asset).put("uri", uri.toString()).put("sourceSha256", sha(bytes))
                    .put("sourceBytes", bytes.length).put("committed", false);
            fixtures.put(fixture);
            write("fixtures.json", saved);
            try (OutputStream out = getContentResolver().openOutputStream(uri, "w")) {
                if (out == null) throw new Exception("MediaStore output stream returned null");
                out.write(bytes);
            }
            values.clear();
            values.put(MediaStore.MediaColumns.IS_PENDING, 0);
            if (getContentResolver().update(uri, values, null, null) != 1) throw new Exception("Commit did not update one fixture");
            try (Cursor cursor = getContentResolver().query(uri, new String[] {MediaStore.MediaColumns.DISPLAY_NAME,
                    MediaStore.MediaColumns.RELATIVE_PATH, MediaStore.MediaColumns.SIZE}, null, null, null)) {
                if (cursor == null || !cursor.moveToFirst()) throw new Exception("Committed URI unavailable");
                fixture.put("displayName", cursor.getString(0)).put("relativePath", cursor.getString(1)).put("bytes", cursor.getLong(2));
            }
            try (InputStream in = getContentResolver().openInputStream(uri)) {
                if (in == null) throw new Exception("Committed fixture input unavailable");
                byte[] reopened = readSmall(in, 4096);
                fixture.put("sha256", sha(reopened)).put("reopenedBytes", reopened.length).put("committed", true);
                if (reopened.length != bytes.length || !sha(bytes).equals(sha(reopened))) throw new Exception("Reopened bytes differ from asset");
            }
            write("fixtures.json", saved);
        }
        saved.put("complete", true).put("status", "STAGED").put("installedLocalSend", installedLocalSend())
                .put("resolvedTreePicker", resolvedTreePicker());
        write("fixtures.json", saved);
        return saved;
    }

    private JSONObject installedLocalSend() throws Exception {
        PackageInfo installed = getPackageManager().getPackageInfo("org.localsend.localsend_app", PackageManager.GET_SIGNING_CERTIFICATES);
        if (installed.signingInfo == null) throw new Exception("Installed LocalSend signing information unavailable");
        JSONArray currentSigners = new JSONArray();
        for (Signature signer : installed.signingInfo.getApkContentsSigners()) currentSigners.put(sha(signer.toByteArray()));
        if (currentSigners.length() == 0) throw new Exception("Installed LocalSend has no current signer");
        JSONObject identity = new JSONObject().put("package", installed.packageName).put("versionName", installed.versionName)
                .put("versionCode", installed.getLongVersionCode()).put("signerSha256", currentSigners)
                .put("hasMultipleSigners", installed.signingInfo.hasMultipleSigners());
        if (installed.applicationInfo != null) {
            identity.put("sourceDir", installed.applicationInfo.sourceDir).put("nativeLibraryDir", installed.applicationInfo.nativeLibraryDir);
        }
        return identity;
    }

    private JSONObject resolvedTreePicker() throws Exception {
        ResolveInfo resolved = getPackageManager().resolveActivity(new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), PackageManager.MATCH_DEFAULT_ONLY);
        if (resolved == null || resolved.activityInfo == null) throw new Exception("No tree picker resolves through PackageManager");
        PackageInfo picker = getPackageManager().getPackageInfo(resolved.activityInfo.packageName, 0);
        return new JSONObject().put("package", resolved.activityInfo.packageName).put("activity", resolved.activityInfo.name)
                .put("versionName", picker.versionName).put("versionCode", picker.getLongVersionCode());
    }

    private void verifyFixtures(JSONArray fixtures) throws Exception {
        for (int i = 0; i < fixtures.length(); i++) {
            JSONObject fixture = fixtures.getJSONObject(i);
            try (Cursor cursor = getContentResolver().query(Uri.parse(fixture.getString("uri")),
                    new String[] {MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.RELATIVE_PATH, MediaStore.MediaColumns.SIZE},
                    null, null, null)) {
                if (cursor == null || !cursor.moveToFirst() || !fixture.getString("displayName").equals(cursor.getString(0))
                        || !fixture.getString("relativePath").equals(cursor.getString(1)) || fixture.getLong("bytes") != cursor.getLong(2)) {
                    throw new Exception("Owned fixture metadata changed or is unavailable");
                }
            }
            try (InputStream in = getContentResolver().openInputStream(Uri.parse(fixture.getString("uri")))) {
                if (in == null) throw new Exception("Owned fixture missing");
                byte[] data = readSmall(in, 4096);
                if (data.length != fixture.getLong("sourceBytes") || !sha(data).equals(fixture.getString("sourceSha256"))) {
                    throw new Exception("Owned fixture changed");
                }
            }
        }
    }

    private final class Inventory {
        JSONArray rows = new JSONArray(), reasons = new JSONArray();
        Set<String> seen = new HashSet<String>(), ownedFound = new HashSet<String>();
        Set<String> documentIds = new HashSet<String>(), documentUris = new HashSet<String>();
        int files; long bytes; boolean complete = true;
        void reject(String reason) { complete = false; reasons.put(reason); }
    }

    private JSONObject inspect(Uri tree, String selectedRoute, int returnedGrantFlags) throws Exception {
        JSONArray fixtures = read("fixtures.json").getJSONArray("fixtures");
        verifyFixtures(fixtures);
        String rootId = DocumentsContract.getTreeDocumentId(tree);
        Uri rootUri = DocumentsContract.buildDocumentUriUsingTree(tree, rootId);
        JSONObject root;
        try (Cursor c = getContentResolver().query(rootUri, columns(), null, null, null)) {
            if (c == null || !c.moveToFirst()) throw new Exception("Tree root unavailable");
            root = row(c, tree, null, 0);
        }
        Inventory inventory = new Inventory();
        inventory.documentIds.add(rootId);
        inventory.documentUris.add(rootUri.toString());
        if (!DocumentsContract.Document.MIME_TYPE_DIR.equals(root.getString("mimeType"))) inventory.reject("Root is not a directory");
        else walk(tree, rootId, 0, "", fixtures, inventory);
        String expectedAuthority = "downloads".equals(selectedRoute) ? "com.android.providers.downloads.documents" : "com.android.externalstorage.documents";
        String expectedId = "downloads".equals(selectedRoute) ? "downloads" : "primary:Download";
        boolean routeMatches = expectedAuthority.equals(tree.getAuthority()) && expectedId.equals(rootId);
        if (!routeMatches) inventory.reject("Selected tree is not the requested actual root");
        if (inventory.ownedFound.size() != 3) inventory.reject("Not all three owned fixture payload counterparts were matched and hashed");
        ProviderInfo provider = getPackageManager().resolveContentProvider(tree.getAuthority(), 0);
        JSONObject identity = new JSONObject().put("authority", tree.getAuthority()).put("model", Build.MODEL)
                .put("manufacturer", Build.MANUFACTURER).put("api", Build.VERSION.SDK_INT).put("release", Build.VERSION.RELEASE);
        if (provider != null) {
            PackageInfo pkg = getPackageManager().getPackageInfo(provider.packageName, 0);
            identity.put("package", provider.packageName).put("versionName", pkg.versionName).put("versionCode", pkg.getLongVersionCode());
        }
        boolean admitted = inventory.complete;
        JSONObject manifest = new JSONObject().put("status", admitted ? "TREE_ADMITTED" : "TREE_REJECTED").put("route", selectedRoute)
                .put("resolvedTreePicker", resolvedTreePicker()).put("requestedGrantFlags", REQUESTED_TREE_FLAGS)
                .put("returnedGrantFlags", returnedGrantFlags).put("persistedGrantFlags", Intent.FLAG_GRANT_READ_URI_PERMISSION)
                .put("grantScope", "Helper-only read tree grant obtained through its separate platform picker; not a LocalSend grant")
                .put("treeUri", tree.toString()).put("rootDocumentId", rootId).put("rootDisplayName", root.getString("displayName"))
                .put("root", root).put("provider", identity).put("rows", inventory.rows).put("fileCount", inventory.files)
                .put("totalBytes", inventory.bytes).put("rowCount", inventory.rows.length() + 1).put("inventoryComplete", inventory.complete)
                .put("admitted", admitted).put("reasons", inventory.reasons).put("ownedFixtureCount", inventory.ownedFound.size())
                .put("fixtureMatchMethod", "granted-document-content-match")
                .put("fixtureMatchScope", "Payload counterparts verified by metadata, bytes and hash; document and MediaStore URI object identity not asserted")
                .put("fixtures", fixtures).put("limits", new JSONObject().put("files", MAX_FILES).put("bytes", MAX_BYTES)
                        .put("directoryLevels", MAX_DEPTH).put("providerRows", MAX_ROWS));
        write("manifest-" + selectedRoute + ".json", manifest);
        return manifest;
    }

    private static String[] columns() { return new String[] {DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE}; }
    private JSONObject row(Cursor c, Uri tree, String parent, int depth) throws Exception {
        String id = c.getString(0);
        return new JSONObject().put("parentDocumentId", parent == null ? JSONObject.NULL : parent).put("documentId", id)
                .put("displayName", c.isNull(1) ? JSONObject.NULL : c.getString(1)).put("mimeType", c.isNull(2) ? JSONObject.NULL : c.getString(2))
                .put("bytes", c.isNull(3) ? JSONObject.NULL : c.getLong(3)).put("depth", depth)
                .put("uri", DocumentsContract.buildDocumentUriUsingTree(tree, id).toString());
    }

    private void walk(Uri tree, String parentId, int parentDepth, String parentPath, JSONArray fixtures, Inventory inventory) throws Exception {
        if (!inventory.seen.add(parentId)) { inventory.reject("Repeated directory document ID"); return; }
        Uri children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId);
        List<JSONObject> directories = new ArrayList<JSONObject>();
        try (Cursor c = getContentResolver().query(children, columns(), null, null, null)) {
            if (c == null) { inventory.reject("Provider returned no child cursor"); return; }
            while (c.moveToNext()) {
                if (inventory.rows.length() >= MAX_ROWS - 1) { inventory.reject("Provider rows exceed limit including root; remaining rows not admitted"); return; }
                JSONObject item = row(c, tree, parentId, parentDepth + 1);
                if (item.isNull("displayName") || item.getString("displayName").length() == 0) inventory.reject("Document display name unavailable");
                String relativePath = parentPath + item.optString("displayName", "");
                item.put("relativePath", relativePath);
                inventory.rows.put(item);
                if (!inventory.documentIds.add(item.getString("documentId")) || !inventory.documentUris.add(item.getString("uri"))) {
                    inventory.reject("Repeated document ID or URI in the whole-root inventory");
                    continue;
                }
                if (DocumentsContract.Document.MIME_TYPE_DIR.equals(item.optString("mimeType"))) {
                    boolean fixtureAncestor = false;
                    for (int i = 0; i < fixtures.length(); i++) {
                        JSONObject fixture = fixtures.getJSONObject(i);
                        String physicalPath = fixture.getString("relativePath") + fixture.getString("displayName");
                        if (physicalPath.startsWith("Download/" + relativePath + "/")) fixtureAncestor = true;
                    }
                    item.put("fixtureAncestorMetadataMatch", fixtureAncestor);
                    if (!fixtureAncestor) inventory.reject("Directory is outside the owned fixture display-name hierarchy");
                    if (parentDepth + 1 > MAX_DEPTH) inventory.reject("Directory depth exceeds limit; descendants not admitted");
                    else directories.add(item);
                } else {
                    inventory.files++;
                    if (item.isNull("bytes") || item.getLong("bytes") < 0) inventory.reject("File size unavailable");
                    else inventory.bytes += item.getLong("bytes");
                    if (inventory.files > MAX_FILES || inventory.bytes > MAX_BYTES) {
                        inventory.reject("Whole-root file count or bytes exceed limit; remaining rows not admitted"); return;
                    }
                    hashOwned(Uri.parse(item.getString("uri")), item, fixtures, inventory);
                }
            }
        } catch (Exception e) { inventory.reject("Child query failed: " + e.toString()); return; }
        for (JSONObject directory : directories) {
            if (inventory.rows.length() >= MAX_ROWS - 1) { inventory.reject("Row limit including root reached before completing traversal"); return; }
            walk(tree, directory.getString("documentId"), parentDepth + 1, directory.getString("relativePath") + "/", fixtures, inventory);
        }
    }

    private void hashOwned(Uri document, JSONObject item, JSONArray fixtures, Inventory inventory) throws Exception {
        item.put("owned", false);
        JSONObject candidate = null;
        for (int i = 0; i < fixtures.length(); i++) {
            JSONObject fixture = fixtures.getJSONObject(i);
            String physicalDirectory = fixture.getString("relativePath");
            if (!physicalDirectory.startsWith("Download/")) throw new Exception("Owned fixture is outside the physical Download root");
            String expectedPath = physicalDirectory.substring("Download/".length()) + fixture.getString("displayName");
            if (!expectedPath.equals(item.getString("relativePath"))
                    || !fixture.getString("displayName").equals(item.getString("displayName"))
                    || item.isNull("bytes") || fixture.getLong("bytes") != item.getLong("bytes")) continue;
            if (candidate != null) {
                inventory.reject("Ambiguous fixture metadata matches for one tree document");
                item.put("identityMethod", "Ambiguous metadata; content not read");
                return;
            }
            candidate = fixture;
        }
        if (candidate != null) {
            JSONObject fixture = candidate;
            Uri owned = Uri.parse(fixture.getString("uri"));
            item.put("identityMethod", "granted-document-content-match").put("uriObjectIdentityVerified", false)
                    .put("expectedFixtureRelativePath", fixture.getString("relativePath").substring("Download/".length()) + fixture.getString("displayName"));
            if (inventory.ownedFound.contains(owned.toString())) {
                inventory.reject("Multiple tree documents match one owned fixture's metadata");
                return;
            }
            try (InputStream in = getContentResolver().openInputStream(document)) {
                if (in == null) throw new Exception("Owned document stream unavailable");
                byte[] data = readSmall(in, 4096);
                String hash = sha(data);
                item.put("sha256", hash).put("hashedBytes", data.length);
                if (data.length != fixture.getLong("sourceBytes") || !hash.equals(fixture.getString("sourceSha256"))) {
                    inventory.reject("Tree document matching fixture metadata has different content");
                } else {
                    item.put("owned", true).put("payloadCounterpartMediaStoreUri", owned.toString()).put("ownedAsset", fixture.getString("asset"));
                    inventory.ownedFound.add(owned.toString());
                }
            }
            return;
        }
        item.put("identityMethod", "No exact owned fixture metadata match; content not read");
        inventory.reject("Unowned file exists in the whole-root inventory; content not read or admitted");
    }

    private JSONObject cleanup() throws Exception {
        File saved = new File(getFilesDir(), "fixtures.json");
        JSONArray deleted = new JSONArray(), remaining = new JSONArray();
        if (saved.exists()) {
            JSONArray fixtures = read("fixtures.json").getJSONArray("fixtures");
            for (int i = 0; i < fixtures.length(); i++) {
                JSONObject item = fixtures.getJSONObject(i);
                try {
                    Uri owned = Uri.parse(item.getString("uri"));
                    int deletedRows = getContentResolver().delete(owned, null, null);
                    boolean verifiedAbsent = false;
                    if (deletedRows == 0) {
                        try (Cursor cursor = getContentResolver().query(owned, new String[] {MediaStore.MediaColumns._ID}, null, null, null)) {
                            if (cursor == null) throw new Exception("Cleanup cannot confirm URI absence: no cursor");
                            verifiedAbsent = !cursor.moveToFirst();
                        }
                        if (!verifiedAbsent) throw new Exception("Cleanup deleted no rows and owned URI is still present");
                    } else if (deletedRows != 1) throw new Exception("Cleanup did not delete exactly one owned row");
                    deleted.put(new JSONObject().put("uri", item.getString("uri")).put("deletedRows", deletedRows)
                            .put("verifiedAbsent", verifiedAbsent));
                }
                catch (Exception e) { remaining.put(item); deleted.put(new JSONObject().put("uri", item.getString("uri")).put("error", e.toString())); }
            }
            if (remaining.length() == 0) { if (!saved.delete()) throw new Exception("Could not remove ownership ledger"); }
            else write("fixtures.json", new JSONObject().put("complete", false).put("fixtures", remaining));
        }
        return new JSONObject().put("status", remaining.length() == 0 ? "CLEANED" : "ERROR").put("deleted", deleted)
                .put("remaining", remaining).put("scope", "Only persisted helper-owned MediaStore URIs");
    }

    private JSONObject read(String name) throws Exception {
        try (InputStream in = new FileInputStream(new File(getFilesDir(), name))) {
            return new JSONObject(new String(readSmall(in, 256 * 1024), "UTF-8"));
        }
    }
    private void write(String name, JSONObject data) throws Exception {
        File temp = new File(getFilesDir(), name + ".tmp"), dest = new File(getFilesDir(), name);
        try (FileOutputStream out = new FileOutputStream(temp)) { out.write(data.toString().getBytes("UTF-8")); out.getFD().sync(); }
        if (!temp.renameTo(dest)) throw new Exception("Cannot persist " + name);
    }
    private static byte[] readSmall(InputStream in, int max) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096]; int read;
        while ((read = in.read(buffer)) != -1) {
            if (out.size() + read > max) throw new Exception("Read exceeds diagnostic byte limit");
            out.write(buffer, 0, read);
        }
        return out.toByteArray();
    }
    private static String sha(byte[] data) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(data);
        StringBuilder hex = new StringBuilder();
        for (byte b : digest) hex.append(String.format(java.util.Locale.US, "%02x", b & 255));
        return hex.toString();
    }
}
