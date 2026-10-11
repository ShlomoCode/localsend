package org.localsend.diagnostic.directtcp;

import android.app.Activity;
import android.os.Bundle;
import android.widget.*;
import java.io.*;
import java.net.*;
import java.security.MessageDigest;
import org.json.*;

/** Synthetic native transport control; no LocalSend code or TLS interception. */
public final class MainActivity extends Activity {
    private TextView status;
    private JSONObject config, result;
    private String phase = "configuration";
    private final JSONArray events = new JSONArray(), cases = new JSONArray();
    private void event(String name, Object detail) throws JSONException {
        phase = name;
        Object snapshot = detail instanceof JSONObject ? new JSONObject(detail.toString()) : detail;
        events.put(new JSONObject().put("phase", name).put("utcMillis", System.currentTimeMillis()).put("detail", snapshot));
    }
    private void publish() {
        final String text = "DIRECT_TCP_RESULT\n" + result.toString();
        runOnUiThread(() -> { status.setText(text); status.setContentDescription(text); });
    }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout layout = new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL);
        Button button = new Button(this); button.setText("Run direct TCP control"); button.setContentDescription("Run direct TCP control");
        status = new TextView(this); status.setText("Ready: synthetic 0, 1, 65537 byte cases");
        layout.addView(button); ScrollView scroll = new ScrollView(this); scroll.addView(status); layout.addView(scroll); setContentView(layout);
        button.setOnClickListener(v -> { button.setEnabled(false); status.setText("Running"); new Thread(this::runControl, "direct-tcp-control").start(); });
    }
    private static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder(); for (byte value : bytes) text.append(String.format("%02x", value & 255)); return text.toString();
    }
    private void runControl() {
        result = new JSONObject();
        try {
            ByteArrayOutputStream configBytes = new ByteArrayOutputStream();
            try (InputStream input = getAssets().open("config.json")) { byte[] buffer = new byte[4096]; int n; while ((n = input.read(buffer)) != -1) configBytes.write(buffer, 0, n); }
            config = new JSONObject(configBytes.toString("UTF-8")); String host = config.getString("host");
            event("http-control-start", host);
            HttpURLConnection http = (HttpURLConnection) new URL("http://" + host + ":8080/health").openConnection();
            http.setConnectTimeout(10000); http.setReadTimeout(10000); http.setRequestProperty("Authorization", "Bearer " + config.getString("token"));
            try {
                if (http.getResponseCode() != 200) throw new IOException("HTTP control status " + http.getResponseCode());
                ByteArrayOutputStream body = new ByteArrayOutputStream();
                try (InputStream input = http.getInputStream()) { int b; while ((b = input.read()) != -1) { if (body.size() >= 4096) throw new IOException("HTTP response too large"); body.write(b); } }
                JSONObject response = new JSONObject(body.toString("UTF-8"));
                if (!response.getString("marker").equals(config.getString("marker"))) throw new IOException("HTTP marker mismatch");
                result.put("httpControl", response); event("http-control-passed", response);
            } finally { http.disconnect(); }
            // DNS can block below Java's socket timeouts. Isolate it with a finite deadline.
            event("native-dns-start", host);
            java.util.concurrent.ExecutorService dns = java.util.concurrent.Executors.newSingleThreadExecutor();
            InetAddress[] addresses;
            try { addresses = dns.submit(() -> InetAddress.getAllByName(host)).get(10, java.util.concurrent.TimeUnit.SECONDS); }
            finally { dns.shutdownNow(); }
            JSONArray resolved = new JSONArray(); for (InetAddress address : addresses) resolved.put(address.getHostAddress());
            event("native-dns-resolved", resolved); if (addresses.length == 0) throw new IOException("No native DNS addresses");
            // Use the first actual native DNS answer, and expose it instead of silently falling back.
            for (int count : new int[]{0, 1, 65537}) {
                JSONObject c = new JSONObject().put("expectedCount", count).put("address", addresses[0].getHostAddress()); cases.put(c);
                byte[] bytes = new byte[count]; for (int i = 0; i < count; i++) bytes[i] = (byte)((i * 31 + 7) & 255);
                String expectedHash = hex(MessageDigest.getInstance("SHA-256").digest(bytes));
                java.util.concurrent.ScheduledExecutorService watchdog = java.util.concurrent.Executors.newSingleThreadScheduledExecutor();
                try (Socket socket = new Socket()) {
                    watchdog.schedule(() -> { try { socket.close(); } catch (IOException ignored) {} }, 25, java.util.concurrent.TimeUnit.SECONDS);
                    event("native-connect-start", c); socket.connect(new InetSocketAddress(addresses[0], 53317), 10000); socket.setSoTimeout(10000);
                    c.put("connectedUtcMillis", System.currentTimeMillis()); event("native-connected", c);
                    phase = "native-write"; socket.getOutputStream().write(bytes); socket.getOutputStream().flush();
                    socket.shutdownOutput(); c.put("shutdownOutputUtcMillis", System.currentTimeMillis()); event("native-output-halfclosed", count);
                    phase = "native-response-through-eof"; ByteArrayOutputStream reply = new ByteArrayOutputStream();
                    long deadline = System.nanoTime() + 10000000000L;
                    while (true) {
                        long remaining = deadline - System.nanoTime(); if (remaining <= 0) throw new SocketTimeoutException("Response absolute deadline");
                        socket.setSoTimeout((int)Math.max(1, remaining / 1000000L));
                        int b = socket.getInputStream().read(); if (b == -1) break;
                        if (reply.size() >= 4096) throw new IOException("TCP response too large"); reply.write(b);
                    }
                    c.put("replyReadThroughEof", true).put("replyEofUtcMillis", System.currentTimeMillis());
                    JSONObject response = new JSONObject(reply.toString("UTF-8")); c.put("response", response);
                    phase = "native-byte-eof-marker-verify";
                    if (response.getInt("count") != count || !response.getString("sha256").equals(expectedHash)
                        || !response.getString("marker").equals(config.getString("marker"))) throw new IOException("TCP byte/hash/marker mismatch");
                    c.put("verified", true); event("native-case-passed", count);
                } finally { watchdog.shutdownNow(); }
            }
            result.put("status", "passed");
        } catch (Exception error) {
            try {
                String message = String.valueOf(error.getMessage());
                if (config != null) message = message.replace(config.optString("token", "[absent]"), "[redacted]");
                result.put("status", "failed").put("failedPhase", phase).put("exceptionType", error.getClass().getName()).put("message", message);
                if (error.getCause() != null) {
                    String causeMessage = String.valueOf(error.getCause().getMessage());
                    if (config != null) causeMessage = causeMessage.replace(config.optString("token", "[absent]"), "[redacted]");
                    result.put("causeType", error.getCause().getClass().getName()).put("causeMessage", causeMessage);
                }
            } catch (JSONException ignored) {}
        } finally {
            try { result.put("events", events).put("cases", cases).put("finishedUtcMillis", System.currentTimeMillis()); } catch (JSONException ignored) {}
            publish();
        }
    }
}
