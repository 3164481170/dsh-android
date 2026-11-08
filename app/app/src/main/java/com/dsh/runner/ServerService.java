package com.dsh.runner;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * 前台服务：负责准备运行时并常驻 node 服务端。
 * 前台服务让进程处于 perceptible 状态，Android 的 cached-app freezer 不会冷冻它，
 * 这是本 App 存在的核心理由。
 */
public class ServerService extends Service {

    static final String TAG = "DshRunner";
    static final String CHANNEL = "dsh-server";
    static final int NOTIF_ID = 42;

    static volatile boolean sRunning = false;
    static volatile Process sProc = null;

    private Thread worker;
    private PowerManager.WakeLock wakeLock;
    private PrintWriter logWriter;
    private volatile boolean stopRequested = false;

    @Override
    public void onCreate() {
        super.onCreate();
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dsh:server");
        wakeLock.setReferenceCounted(false);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForeground(NOTIF_ID, buildNotification("正在准备…"));
        wakeLock.acquire();
        if (worker == null || !worker.isAlive()) {
            stopRequested = false;
            worker = new Thread(this::runServer, "dsh-worker");
            worker.start();
        }
        return START_STICKY;
    }

    private Notification buildNotification(String text) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26) {
            NotificationChannel ch = new NotificationChannel(CHANNEL, "DSH 服务", NotificationManager.IMPORTANCE_LOW);
            ch.setShowBadge(false);
            nm.createNotificationChannel(ch);
        }
        Intent i = new Intent(this, MainActivity.class);
        PendingIntent pi = PendingIntent.getActivity(this, 0, i,
                PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0));
        Notification.Builder b = Build.VERSION.SDK_INT >= 26
                ? new Notification.Builder(this, CHANNEL)
                : new Notification.Builder(this);
        return b.setContentTitle("DeepSeek Harness")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setOngoing(true)
                .setContentIntent(pi)
                .build();
    }

    private void updateNotification(String text) {
        ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).notify(NOTIF_ID, buildNotification(text));
    }

    private synchronized void log(String line) {
        Log.i(TAG, line);
        try {
            if (logWriter == null) {
                File f = new File(getFilesDir(), "logs/server.log");
                f.getParentFile().mkdirs();
                logWriter = new PrintWriter(new FileOutputStream(f, true), true);
            }
            logWriter.println(line);
        } catch (Exception ignored) {
        }
    }

    private void runServer() {
        Bootstrap bs = new Bootstrap(this, this::log);
        try {
            if (stopRequested) return;
            if (!bs.runtimeReady()) {
                updateNotification("安装运行时…");
                bs.installRuntime();
            }
            if (!bs.dshReady()) {
                updateNotification("安装 dsh（首次较慢）…");
                bs.installDsh();
            }
            if (stopRequested) return;
            updateNotification("应用补丁…");
            bs.applyPatches();
            if (stopRequested) return;
            startNode(bs);
        } catch (Throwable t) {
            log("启动失败: " + t);
            updateNotification("启动失败，点开查看日志");
            sRunning = false;
        }
    }

    private void startNode(Bootstrap bs) throws Exception {
        File urlFile = new File(getFilesDir(), "server.url");
        urlFile.delete();

        List<String> cmd = new ArrayList<>();
        cmd.add(bs.nodeBin().getAbsolutePath());
        cmd.add("--expose-internals");
        cmd.add(bs.dshBin().getAbsolutePath());
        cmd.add("--profile");
        cmd.add("web");
        cmd.add("--host");
        cmd.add("127.0.0.1");
        cmd.add("--port");
        cmd.add(String.valueOf(MainActivity.PORT));
        cmd.add("--no-open");

        log("exec: " + String.join(" ", cmd));
        ProcessBuilder pb = new ProcessBuilder(cmd);
        Map<String, String> env = pb.environment();
        env.clear();
        env.putAll(bs.env());
        env.put("NODE_ENV", "production");
        pb.directory(bs.home);
        pb.redirectErrorStream(true);

        Process p = pb.start();
        sProc = p;
        sRunning = true;
        updateNotification("服务运行中 · 127.0.0.1:" + MainActivity.PORT);

        BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
        String line;
        while ((line = r.readLine()) != null) {
            log(line);
            int idx = line.indexOf("token=");
            if (idx > 0) {
                String url = line.substring(line.indexOf("http"), line.length()).trim();
                try (FileOutputStream fo = new FileOutputStream(urlFile)) {
                    fo.write(url.getBytes("UTF-8"));
                }
                log("URL 就绪: " + url);
                updateNotification("服务运行中 · 已就绪");
            }
        }
        int code = p.waitFor();
        log("node 退出 code=" + code);
        sRunning = false;
        sProc = null;
        updateNotification("服务已停止");
    }

    @Override
    public void onDestroy() {
        stopRequested = true;
        try {
            if (sProc != null) sProc.destroy();
        } catch (Exception ignored) {
        }
        try {
            if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        } catch (Exception ignored) {
        }
        if (logWriter != null) logWriter.close();
        sRunning = false;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}