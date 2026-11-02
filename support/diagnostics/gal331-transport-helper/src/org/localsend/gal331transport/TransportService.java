package org.localsend.gal331transport;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.IBinder;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class TransportService extends Service {
    private final ExecutorService workers = Executors.newFixedThreadPool(2);
    private volatile boolean running;

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String host = intent == null ? null : intent.getStringExtra("host");
        if (host == null || host.isEmpty()) {
            stopSelf();
            return START_NOT_STICKY;
        }
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(
                "gal331-transport", "Gal331 transport", NotificationManager.IMPORTANCE_LOW));
        Notification notification = new Notification.Builder(this, "gal331-transport")
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle("Gal331 transport")
                .setContentText("Forwarding LocalSend connections")
                .build();
        startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        if (!running) {
            running = true;
            for (int i = 0; i < 2; i++) workers.execute(() -> workerLoop(host));
        }
        return START_NOT_STICKY;
    }

    private void workerLoop(String host) {
        String base = "http://" + host + ":18453";
        while (running) {
            try {
                String id = MainActivity.getText(base + "/take");
                if (id.isEmpty()) continue;
                try (Socket receiver = new Socket()) {
                    receiver.connect(new InetSocketAddress("127.0.0.1", 53317), 10000);
                    receiver.setTcpNoDelay(true);
                    Thread upload = new Thread(() -> MainActivity.pushLoop(base, id, receiver));
                    upload.start();
                    MainActivity.pullLoop(base, id, receiver);
                    upload.join(30000);
                }
                MainActivity.post(base + "/finish?id=" + id, new byte[0], 0);
            } catch (Exception e) {
                try { Thread.sleep(1500); } catch (InterruptedException ignored) { return; }
            }
        }
    }

    @Override public void onDestroy() {
        running = false;
        workers.shutdownNow();
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) {
        return null;
    }
}
