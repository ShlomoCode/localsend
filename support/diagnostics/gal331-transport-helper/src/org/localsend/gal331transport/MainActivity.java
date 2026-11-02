package org.localsend.gal331transport;

import android.Manifest;
import android.app.Activity;
import android.content.ContentResolver;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.provider.MediaStore;
import android.system.Os;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.ByteArrayOutputStream;
import java.net.HttpURLConnection;
import java.net.InetSocketAddress;
import java.net.ProxySelector;
import java.net.Socket;
import java.net.URI;
import java.net.URL;
import java.security.MessageDigest;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private final ExecutorService workers = Executors.newFixedThreadPool(8);
    private volatile boolean running;
    private EditText host;
    private TextView status;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        host = new EditText(this);
        host.setSingleLine(true);
        host.setText("bs-local.com");
        layout.addView(host);
        Button start = new Button(this);
        start.setText("Start transport");
        start.setOnClickListener(v -> startTransport());
        layout.addView(start);
        Button probe = new Button(this);
        probe.setText("Probe HTTP transport");
        probe.setOnClickListener(v -> new Thread(() -> {
            try {
                String base = "http://" + host.getText().toString().trim() + ":18453";
                String proxies = ProxySelector.getDefault().select(URI.create(base)).toString();
                showStatus("proxy=" + proxies + " health=" + getText(base + "/health"));
            } catch (Exception e) {
                showStatus("HTTP probe: " + e.getClass().getSimpleName() + ": " + e.getMessage());
            }
        }).start());
        layout.addView(probe);
        Button inspect = new Button(this);
        inspect.setText("Inspect gallery");
        inspect.setOnClickListener(v -> inspectGallery());
        layout.addView(inspect);
        Button inspectFile = new Button(this);
        inspectFile.setText("Inspect chosen image");
        inspectFile.setOnClickListener(v -> {
            Intent picker = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            picker.setType("image/*");
            picker.addCategory(Intent.CATEGORY_OPENABLE);
            startActivityForResult(picker, 2);
        });
        layout.addView(inspectFile);
        status = new TextView(this);
        status.setText("Ready");
        layout.addView(status);
        ScrollView scroll = new ScrollView(this);
        scroll.addView(layout);
        setContentView(scroll);
    }

    private void startTransport() {
        if (running) return;
        running = true;
        String transportHost = host.getText().toString().trim();
        status.setText("Connecting to " + transportHost + ":18453");
        for (int i = 0; i < 8; i++) {
            workers.execute(() -> workerLoop(transportHost));
        }
    }

    private void workerLoop(String transportHost) {
        String base = "http://" + transportHost + ":18453";
        while (running) {
            try {
                String id = getText(base + "/take");
                if (id.isEmpty()) continue;
                try (Socket receiver = new Socket()) {
                    receiver.connect(new InetSocketAddress("127.0.0.1", 53317), 10000);
                    receiver.setTcpNoDelay(true);
                    Thread upload = new Thread(() -> pushLoop(base, id, receiver));
                    upload.start();
                    pullLoop(base, id, receiver);
                    upload.join(30000);
                }
                post(base + "/finish?id=" + id, new byte[0], 0);
            } catch (Exception e) {
                showStatus("Transport: " + e.getClass().getSimpleName() + ": " + e.getMessage());
                try { Thread.sleep(1500); } catch (InterruptedException ignored) { return; }
            }
        }
    }

    private static void pullLoop(String base, String id, Socket destination) throws Exception {
        while (true) {
            HttpURLConnection connection = open(base + "/pull?id=" + id, "GET");
            int code = connection.getResponseCode();
            if (code == 410) {
                destination.shutdownOutput();
                connection.disconnect();
                return;
            }
            if (code == 200) {
                try (InputStream input = connection.getInputStream()) {
                    byte[] buffer = new byte[32768];
                    int count;
                    while ((count = input.read(buffer)) >= 0) destination.getOutputStream().write(buffer, 0, count);
                }
            } else if (code != 204) {
                throw new Exception("Pull HTTP " + code);
            }
            connection.disconnect();
        }
    }

    private static void pushLoop(String base, String id, Socket source) {
        byte[] buffer = new byte[32768];
        try {
            InputStream input = source.getInputStream();
            int count;
            while ((count = input.read(buffer)) >= 0) {
                post(base + "/push?id=" + id, buffer, count);
            }
        } catch (Exception ignored) {
            try { source.shutdownInput(); } catch (Exception ignoredAgain) { }
        }
    }

    private static HttpURLConnection open(String address, String method) throws Exception {
        HttpURLConnection connection = (HttpURLConnection) new URL(address).openConnection();
        connection.setRequestMethod(method);
        connection.setConnectTimeout(10000);
        connection.setReadTimeout(30000);
        connection.setUseCaches(false);
        return connection;
    }

    private static String getText(String address) throws Exception {
        HttpURLConnection connection = open(address, "GET");
        try {
            int code = connection.getResponseCode();
            if (code == 204) return "";
            if (code != 200) throw new Exception("GET HTTP " + code);
            try (InputStream input = connection.getInputStream(); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[1024];
                int count;
                while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
                return output.toString("UTF-8");
            }
        } finally {
            connection.disconnect();
        }
    }

    private static void post(String address, byte[] bytes, int length) throws Exception {
        HttpURLConnection connection = open(address, "POST");
        connection.setDoOutput(true);
        connection.setFixedLengthStreamingMode(length);
        try {
            try (OutputStream output = connection.getOutputStream()) {
                output.write(bytes, 0, length);
            }
            if (connection.getResponseCode() != 200) throw new Exception("POST HTTP " + connection.getResponseCode());
        } finally {
            connection.disconnect();
        }
    }

    private void inspectGallery() {
        if (checkSelfPermission(Manifest.permission.READ_MEDIA_IMAGES) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {Manifest.permission.READ_MEDIA_IMAGES}, 1);
            return;
        }
        new Thread(() -> {
            StringBuilder result = new StringBuilder();
            ContentResolver resolver = getContentResolver();
            Uri uri = MediaStore.Images.Media.EXTERNAL_CONTENT_URI;
            String[] columns = {
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DISPLAY_NAME,
                MediaStore.Images.Media.DATE_MODIFIED,
                MediaStore.Images.Media.DATE_TAKEN,
                MediaStore.Images.Media.DATE_ADDED,
                MediaStore.Images.Media.SIZE,
                MediaStore.Images.Media.RELATIVE_PATH
            };
            try (Cursor cursor = resolver.query(uri, columns, null, null,
                    MediaStore.Images.Media.DATE_ADDED + " DESC")) {
                if (cursor == null) throw new Exception("MediaStore returned no cursor");
                int count = 0;
                while (cursor.moveToNext() && count < 10) {
                    if (!cursor.getString(1).startsWith("gal331")) continue;
                    long id = cursor.getLong(0);
                    Uri item = Uri.withAppendedPath(uri, Long.toString(id));
                    result.append("name=").append(cursor.getString(1))
                            .append(" modifiedSeconds=").append(cursor.getLong(2))
                            .append(" takenMillis=").append(cursor.getLong(3))
                            .append(" addedSeconds=").append(cursor.getLong(4))
                            .append(" size=").append(cursor.getLong(5))
                            .append(" path=").append(cursor.getString(6))
                            .append(" statMtimeSeconds=").append(statMtime(resolver, item))
                            .append(" sha256=").append(sha256(resolver, item)).append('\n');
                    count++;
                }
                if (count == 0) result.append("No gallery images visible");
            } catch (Exception e) {
                result.append(e.getClass().getSimpleName()).append(": ").append(e.getMessage());
            }
            showStatus(result.toString());
        }).start();
    }

    private static long statMtime(ContentResolver resolver, Uri uri) throws Exception {
        try (ParcelFileDescriptor descriptor = resolver.openFileDescriptor(uri, "r")) {
            if (descriptor == null) throw new Exception("Cannot open descriptor " + uri);
            return Os.fstat(descriptor.getFileDescriptor()).st_mtime;
        }
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != 2 || resultCode != RESULT_OK || data == null || data.getData() == null) return;
        Uri selected = data.getData();
        new Thread(() -> {
            try {
                ContentResolver resolver = getContentResolver();
                showStatus("chosenUri=" + selected + " statMtimeSeconds=" + statMtime(resolver, selected)
                        + " sha256=" + sha256(resolver, selected));
            } catch (Exception e) {
                showStatus(e.getClass().getSimpleName() + ": " + e.getMessage());
            }
        }).start();
    }

    private static String sha256(ContentResolver resolver, Uri uri) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = resolver.openInputStream(uri)) {
            if (input == null) throw new Exception("Cannot open " + uri);
            byte[] buffer = new byte[32768];
            int count;
            while ((count = input.read(buffer)) >= 0) digest.update(buffer, 0, count);
        }
        StringBuilder hex = new StringBuilder();
        for (byte value : digest.digest()) hex.append(String.format("%02x", value & 0xff));
        return hex.toString();
    }

    private void showStatus(String value) {
        runOnUiThread(() -> status.setText(value));
    }

    @Override public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grants) {
        super.onRequestPermissionsResult(requestCode, permissions, grants);
        if (requestCode == 1 && grants.length > 0 && grants[0] == PackageManager.PERMISSION_GRANTED) {
            inspectGallery();
        }
    }

    @Override public void onDestroy() {
        running = false;
        workers.shutdownNow();
        super.onDestroy();
    }
}
