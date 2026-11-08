package com.dsh.runner;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.File;
import java.io.FileInputStream;

/** 单 Activity：内嵌 WebView 承载 dsh 的浏览器 UI，服务端由前台服务常驻。 */
public class MainActivity extends Activity {

    public static final int PORT = 61374;

    private WebView web;
    private TextView status;
    private TextView logView;
    private LinearLayout overlay;
    private final Handler h = new Handler(Looper.getMainLooper());
    private boolean loadedOnce = false;
    private String lastUrl = null;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildUi();
        startService(new Intent(this, ServerService.class));
        requestStorage();
        requestIgnoreBatteryOptimizations();
        pollUrl();
    }

    private void requestStorage() {
        try {
            if (Build.VERSION.SDK_INT >= 30) {
                if (!android.os.Environment.isExternalStorageManager()) {
                    Intent i = new Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
                    i.setData(android.net.Uri.parse("package:" + getPackageName()));
                    startActivity(i);
                }
            } else if (Build.VERSION.SDK_INT >= 23) {
                if (checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE)
                        != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(new String[]{
                            android.Manifest.permission.READ_EXTERNAL_STORAGE,
                            android.Manifest.permission.WRITE_EXTERNAL_STORAGE}, 7);
                }
            }
        } catch (Exception ignored) {
        }
    }

    private void requestIgnoreBatteryOptimizations() {
        try {
            if (Build.VERSION.SDK_INT >= 23) {
                Intent i = new Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
                i.setData(android.net.Uri.parse("package:" + getPackageName()));
                startActivity(i);
            }
        } catch (Exception ignored) {
        }
    }

    private void buildUi() {
        FrameLayout root = new FrameLayout(this);

        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(false);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setTextZoom(110);
        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onReceivedError(WebView v, android.webkit.WebResourceRequest req,
                                        android.webkit.WebResourceError err) {
                if (req != null && req.isForMainFrame()) {
                    status.setText("连接失败，重试中…");
                    h.postDelayed(() -> {
                        String u = readUrl();
                        if (u != null) { lastUrl = u; loadedOnce = true; openUi(u); }
                    }, 2000);
                }
            }
        });
        web.setWebChromeClient(new WebChromeClient());
        web.setBackgroundColor(Color.parseColor("#111318"));
        root.addView(web, new FrameLayout.LayoutParams(-1, -1));

        overlay = new LinearLayout(this);
        overlay.setOrientation(LinearLayout.VERTICAL);
        overlay.setBackgroundColor(Color.parseColor("#0F1115"));
        overlay.setPadding(40, 90, 40, 40);

        TextView title = new TextView(this);
        title.setText("DeepSeek Harness · Android");
        title.setTextColor(Color.parseColor("#E6E8EB"));
        title.setTextSize(20);
        overlay.addView(title);

        status = new TextView(this);
        status.setTextColor(Color.parseColor("#8AB4F8"));
        status.setTextSize(13);
        status.setPadding(0, 18, 0, 18);
        status.setText("正在启动服务…");
        overlay.addView(status);

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.START);

        Button reload = new Button(this);
        reload.setText("重载界面");
        reload.setOnClickListener(v -> {
            String url = readUrl();
            if (url != null) web.loadUrl(url);
        });
        row.addView(reload);

        Button restart = new Button(this);
        restart.setText("重启服务");
        restart.setOnClickListener(v -> {
            stopService(new Intent(this, ServerService.class));
            loadedOnce = false;
            status.setText("正在重启…");
            h.postDelayed(() -> startService(new Intent(this, ServerService.class)), 800);
        });
        row.addView(restart);

        Button browser = new Button(this);
        browser.setText("完整功能");
        browser.setOnClickListener(v -> openInBrowser());
        row.addView(browser);

        Button logBtn = new Button(this);
        logBtn.setText("日志");
        logBtn.setOnClickListener(v -> toggleLog());
        row.addView(logBtn);

        overlay.addView(row);

        ScrollView sc = new ScrollView(this);
        logView = new TextView(this);
        logView.setTextColor(Color.parseColor("#B0B6BE"));
        logView.setTextSize(10);
        logView.setVisibility(View.GONE);
        logView.setPadding(0, 16, 0, 16);
        sc.addView(logView);
        overlay.addView(sc, new LinearLayout.LayoutParams(-1, 0, 1f));

        root.addView(overlay, new FrameLayout.LayoutParams(-1, -1));
        setContentView(root);
    }

    private void toggleLog() {
        if (logView.getVisibility() == View.GONE) {
            logView.setVisibility(View.VISIBLE);
            logView.setText(tailLog(120));
        } else {
            logView.setVisibility(View.GONE);
        }
    }

    private String tailLog(int lines) {
        try {
            File f = new File(getFilesDir(), "logs/server.log");
            if (!f.exists()) return "(暂无日志)";
            byte[] all = new byte[(int) Math.min(f.length(), 400_000)];
            try (FileInputStream in = new FileInputStream(f)) {
                in.skip(Math.max(0, f.length() - all.length));
                in.read(all);
            }
            String[] parts = new String(all, "UTF-8").split("\n");
            StringBuilder sb = new StringBuilder();
            for (int i = Math.max(0, parts.length - lines); i < parts.length; i++) sb.append(parts[i]).append('\n');
            return sb.toString();
        } catch (Exception e) {
            return "日志读取失败: " + e;
        }
    }

    private String readUrl() {
        try {
            File f = new File(getFilesDir(), "server.url");
            if (!f.exists()) return null;
            byte[] b = new byte[(int) f.length()];
            try (FileInputStream in = new FileInputStream(f)) {
                in.read(b);
            }
            String s = new String(b, "UTF-8").trim();
            return s.startsWith("http") ? s : null;
        } catch (Exception e) {
            return null;
        }
    }


    /** L1：官方 SPA（内核够新）；L0：内置精简客户端；都同源，cookie 直接可用。 */
    private void openUi(String tokenUrl) {
        final String url = tokenUrl;
        web.evaluateJavascript("(typeof Promise.withResolvers === 'function') ? '1' : '0'", value -> {
            boolean modern = value != null && value.contains("1");
            String target;
            if (modern) {
                target = url;
                status.setText("界面：官方 SPA（内核已支持）");
            } else {
                int q = url.indexOf("?token=");
                String token = q >= 0 ? url.substring(q + "?token=".length()) : "";
                target = url.substring(0, url.indexOf("/", 8) + 1)
                        + "mini.html?token=" + token + "&workspace=" + readWorkspace();
                status.setText("界面：内置客户端（系统 WebView 版本较旧）");
            }
            web.loadUrl(target);
            overlay.animate().alpha(0f).setDuration(300).withEndAction(() -> overlay.setVisibility(View.GONE));
        });
    }

    private String readWorkspace() {
        try {
            File f = new File(getFilesDir(), "workspace.path");
            if (!f.exists()) return "";
            byte[] b = new byte[(int) f.length()];
            try (FileInputStream in = new FileInputStream(f)) { in.read(b); }
            return java.net.URLEncoder.encode(new String(b, "UTF-8").trim(), "UTF-8");
        } catch (Exception e) {
            return "";
        }
    }

    /** L2：交给已安装的现代浏览器，拿完整功能。 */
    private void openInBrowser() {
        String u = readUrl();
        if (u == null) return;
        try {
            Intent i = new Intent(Intent.ACTION_VIEW, android.net.Uri.parse(u));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
        } catch (Exception e) {
            status.setText("没有可用浏览器：" + e.getMessage());
        }
    }

    private void pollUrl() {
        h.postDelayed(() -> {
            String url = readUrl();
            if (url != null) {
                status.setText("已连接 · " + url.replaceAll("token=.*", "token=***"));
                if (!url.equals(lastUrl)) {
                    lastUrl = url;
                    loadedOnce = false;
                }
                if (!loadedOnce) {
                    loadedOnce = true;
                    openUi(url);
                }
            } else {
                status.setText(ServerService.sRunning ? "服务启动中…" : "正在准备运行时（首次需数分钟）…");
            }
            pollUrl();
        }, 700);
    }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) web.goBack();
        else moveTaskToBack(true);
    }
}