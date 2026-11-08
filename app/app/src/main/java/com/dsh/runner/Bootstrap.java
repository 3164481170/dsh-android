package com.dsh.runner;

import android.content.Context;
import android.system.Os;

import java.io.*;
import java.util.*;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/** 首次启动时把 assets 里的 Termux 运行时 + Node 摊到应用私有目录。 */
final class Bootstrap {

    interface Log { void line(String s); }

    final Context ctx;
    final File files;
    final File usr;
    final File home;
    final Log log;

    Bootstrap(Context ctx, Log log) {
        this.ctx = ctx;
        this.log = log;
        this.files = ctx.getFilesDir();
        this.usr = new File(files, "usr");
        this.home = new File(files, "home");
    }

    File nodeBin() { return new File(usr, "bin/node"); }
    File dshBin()  { return new File(usr, "lib/node_modules/@deepseek-ai/dsh/lib/bin.js"); }
    boolean runtimeReady() {
        return new File(usr, "bin/bash").exists() && nodeBin().exists()
                && new File(usr, "lib/node_modules/npm/bin/npm-cli.js").exists();
    }
    boolean dshReady() { return dshBin().exists(); }

    void ensureDirs() {
        home.mkdirs();
        new File(files, "logs").mkdirs();
        new File(files, "tmp").mkdirs();
        new File(home, ".dsh").mkdirs();
    }

    void installRuntime() throws Exception {
        ensureDirs();
        log.line("解包 bootstrap…");
        unzipAsset("bootstrap.zip", usr);
        log.line("解包 node…");
        copyAssetTree("node", "", usr);
        log.line("解包 npm…");
        unzipAsset("npm.zip", usr);
        log.line("改写 Termux 前缀引用…");
        rewriteTermuxPaths();
        log.line("重建符号链接…");
        applySymlinks();
        log.line("修权限…");
        chmodTree(usr);
        log.line("运行时: " + nodeBin() + " ok=" + nodeBin().exists());
    }

    private void unzipAsset(String asset, File dest) throws IOException {
        dest.mkdirs();
        try (ZipInputStream zin = new ZipInputStream(new BufferedInputStream(ctx.getAssets().open(asset), 1 << 16))) {
            ZipEntry e;
            byte[] buf = new byte[1 << 16];
            while ((e = zin.getNextEntry()) != null) {
                String name = e.getName();
                if (name.equals("SYMLINKS.txt")) continue;
                File out = new File(dest, name);
                if (e.isDirectory()) { out.mkdirs(); continue; }
                File parent = out.getParentFile();
                if (parent != null) parent.mkdirs();
                try (OutputStream os = new FileOutputStream(out)) {
                    int n;
                    while ((n = zin.read(buf)) > 0) os.write(buf, 0, n);
                }
            }
        }
    }

    /** 递归复制 assets 下整棵子树，保持相对路径。 */
    private void copyAssetTree(String assetPath, String rel, File destRoot) throws IOException {
        String[] children = ctx.getAssets().list(assetPath);
        if (children == null || children.length == 0) {
            File out = new File(destRoot, rel);
            File parent = out.getParentFile();
            if (parent != null) parent.mkdirs();
            try (InputStream in = ctx.getAssets().open(assetPath);
                 OutputStream os = new FileOutputStream(out)) {
                byte[] buf = new byte[1 << 16];
                int n;
                while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
            }
            return;
        }
        for (String c : children) {
            copyAssetTree(assetPath + "/" + c, rel.isEmpty() ? c : rel + "/" + c, destRoot);
        }
    }

    private void applySymlinks() {
        String prefix = usr.getAbsolutePath();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(ctx.getAssets().open("symlinks.txt"), "UTF-8"))) {
            String line;
            while ((line = r.readLine()) != null) {
                line = line.trim();
                if (line.isEmpty() || line.startsWith("#")) continue;
                int tab = line.indexOf('\t');
                if (tab < 0) continue;
                String linkRel = line.substring(0, tab);
                String target = line.substring(tab + 1).replace("@PREFIX@", prefix);
                File link = new File(files, linkRel);
                File parent = link.getParentFile();
                if (parent != null) parent.mkdirs();
                if (link.exists()) continue;
                try { Os.symlink(target, link.getAbsolutePath()); } catch (Exception ignored) {}
            }
        } catch (IOException ignored) {
        }
    }

    private void chmodTree(File f) {
        File[] kids = f.listFiles();
        if (kids == null) return;
        for (File k : kids) {
            try {
                if (k.isDirectory()) {
                    Os.chmod(k.getAbsolutePath(), 0755);
                    chmodTree(k);
                } else {
                    String p = k.getAbsolutePath();
                    boolean exec = p.contains("/bin/") || p.endsWith(".node")
                            || p.contains("/libexec/") || k.getName().equals("node");
                    Os.chmod(p, exec ? 0755 : 0644);
                }
            } catch (Exception ignored) {}
        }
    }

    
    /** Termux 的 bootstrap 里写死了 /data/data/com.termux/files/usr，改成本应用的 prefix。 */
    private void rewriteTermuxPaths() {
        String[] rels = {
            "etc/tls/openssl.cnf", "etc/tls/cert.pem", "etc/profile", "etc/bash.bashrc",
            "etc/motd", "etc/npmrc", "etc/bash_completion.d/npm"
        };
        int changed = 0;
        for (String rel : rels) changed += rewriteFile(new File(usr, rel));
        log.line("前缀改写完成，命中 " + changed + " 个文件");
    }

    private int rewriteFile(File f) {
        if (!f.isFile() || f.length() > 512 * 1024) return 0;
        try {
            byte[] raw = new byte[(int) f.length()];
            try (FileInputStream in = new FileInputStream(f)) { in.read(raw); }
            String s = new String(raw, "UTF-8");
            if (!s.contains("/data/data/com.termux/files/usr")) return 0;
            String out = s.replace("/data/data/com.termux/files/usr", usr.getAbsolutePath());
            try (FileOutputStream fo = new FileOutputStream(f)) { fo.write(out.getBytes("UTF-8")); }
            return 1;
        } catch (Throwable t) {
            return 0;
        }
    }

    /** 每次启动都跑：幂等补丁 + 内置客户端 + 工作区 + purge。 */
    void applyPatches() {
        // pty 预编译必须先就位，补丁脚本第 4 步要用它
        try { copyAsset("pty.node", new File(home, "pty.node")); } catch (Throwable ignored) {}
        try {
            File fix = new File(home, "dsh-android-fix.sh");
            copyAsset("dsh-android-fix.sh", fix);
            execScript("bash " + fix.getAbsolutePath());
        } catch (Throwable t) { log.line("补丁脚本失败（继续）: " + t); }
        installMiniClient();
        installWorkspace();
        installPurge();
        installPurgePlugin();
    }


    /** 把 dsh-purge 作为 profile bundle 装进 web profile，让它在插件库里可见并真正加载。 */
    void installPurgePlugin() {
        try {
            File profile = new File(new File(home, ".dsh/profiles"), "web");
            File nm = new File(profile, "node_modules");
            File dest = new File(nm, "dsh-purge");
            File srcPkg = new File(new File(home, ".dsh/assets-src"), "purge");
            if (!srcPkg.isDirectory()) { log.line("purge 插件源缺失，跳过"); return; }
            if (!dest.isDirectory() || dest.lastModified() < srcPkg.lastModified()) {
                deleteTree(dest);
                nm.mkdirs();
                copyTree(srcPkg, dest);
            }
            File pkgJson = new File(profile, "package.json");
            if (!pkgJson.isFile()) return;
            String s = readText(pkgJson);
            if (!s.contains("\"dsh-purge\"")) {
                int b = s.indexOf("\"bundles\"");
                int open = b < 0 ? -1 : s.indexOf('[', b);
                int close = open < 0 ? -1 : s.indexOf(']', open);
                if (close > 0) {
                    String head = s.substring(0, close).trim();
                    String tail = s.substring(close);
                    s = head + (head.endsWith("[") ? "" : ",") + "\n        \"dsh-purge\"\n      " + tail;
                }
                int d = s.indexOf("\"dependencies\"");
                int dop = d < 0 ? -1 : s.indexOf('{', d);
                int dcl = dop < 0 ? -1 : s.indexOf('}', dop);
                if (dcl > 0) {
                    String head = s.substring(0, dcl).trim();
                    String tail = s.substring(dcl);
                    s = head + (head.endsWith("{") ? "" : ",") + "\n    \"dsh-purge\": \"1.1.71\"\n  " + tail;
                }
                writeText(pkgJson, s);
                log.line("dsh-purge 已注册为 profile bundle");
            } else {
                log.line("dsh-purge 已注册（跳过）");
            }
        } catch (Throwable t) {
            log.line("dsh-purge 插件注册失败（继续）: " + t);
        }
    }

    private static String readText(File f) throws IOException {
        byte[] raw = new byte[(int) f.length()];
        try (FileInputStream in = new FileInputStream(f)) { in.read(raw); }
        return new String(raw, "UTF-8");
    }

    private static void writeText(File f, String s) throws IOException {
        try (FileOutputStream out = new FileOutputStream(f)) { out.write(s.getBytes("UTF-8")); }
    }

    private static void deleteTree(File f) {
        if (f == null || !f.exists()) return;
        File[] kids = f.listFiles();
        if (kids != null) for (File k : kids) deleteTree(k);
        f.delete();
    }

    private void copyTree(File from, File to) throws IOException {
        if (from.isDirectory()) {
            to.mkdirs();
            File[] kids = from.listFiles();
            if (kids != null) for (File k : kids) copyTree(k, new File(to, k.getName()));
        } else {
            to.getParentFile().mkdirs();
            try (InputStream in = new FileInputStream(from); OutputStream out = new FileOutputStream(to)) {
                byte[] buf = new byte[1 << 16];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            }
        }
    }

    void installDsh() throws Exception {
        File npmCli = new File(usr, "lib/node_modules/npm/bin/npm-cli.js");
        if (!npmCli.isFile()) throw new IOException("缺少 npm-cli.js: " + npmCli);
        log.line("安装 @deepseek-ai/dsh（首次约 4 分钟，需联网）…");
        execScript("node " + npmCli.getAbsolutePath() + " i -g @deepseek-ai/dsh");
        log.line("应用 Android 补丁…");
        File fix = new File(home, "dsh-android-fix.sh");
        copyAsset("dsh-android-fix.sh", fix);
        execScript("bash " + fix.getAbsolutePath());
    }

    /**
     * 补装 dsh-purge：把 assets 里的插件包 + 注入文本摊到 $HOME/.dsh/assets-src，
     * 再跑 purge-install.sh（幂等、失败不阻塞启动）。
     */

    /** 把内置的 L0 客户端放进 dsh 的静态目录，让它与服务同源（cookie/鉴权天然可用）。 */
    void installMiniClient() {
        try {
            File dist = new File(usr,
                "lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist");
            if (!dist.isDirectory()) { log.line("mini-client: 未找到 dist，跳过"); return; }
            File out = new File(dist, "mini.html");
            copyAsset("mini-client/index.html", out);
            log.line("mini-client 就位: " + out.getAbsolutePath());
        } catch (Throwable t) {
            log.line("mini-client 安装失败: " + t);
        }
    }

    /** 工作区放在用户可见的 /sdcard/DSH，并把 dsh 默认工作区 $HOME/默认 软链过去。 */
    void installWorkspace() {
        File ws = new File("/sdcard/DSH/workspace");
        try {
            ws.mkdirs();
            log.line("工作区: " + ws.getAbsolutePath() + " exists=" + ws.exists());
        } catch (Throwable t) {
            log.line("工作区创建失败: " + t);
        }
        File link = new File(home, "默认");
        try {
            if (link.exists() || isSymlink(link)) link.delete();
            Os.symlink(ws.getAbsolutePath(), link.getAbsolutePath());
            log.line("软链: " + link.getAbsolutePath() + " -> " + ws.getAbsolutePath());
        } catch (Throwable t) {
            log.line("软链创建失败（不影响启动）: " + t);
        }
        try {
            File marker = new File(files, "workspace.path");
            FileOutputStream fo = new FileOutputStream(marker);
            fo.write(ws.getAbsolutePath().getBytes("UTF-8"));
            fo.close();
        } catch (Throwable ignored) {}
    }

    private boolean isSymlink(File f) {
        try {
            File canon = new File(f.getParentFile().getCanonicalFile(), f.getName());
            return !canon.getCanonicalPath().equals(f.getAbsolutePath());
        } catch (Throwable t) {
            return false;
        }
    }

    void installPurge() {
        File assetsDst = new File(home, ".dsh/assets-src");
        try {
            log.line("准备 dsh-purge 载荷…");
            copyAssetTree("purge", "purge", assetsDst);
            copyAsset("prompt-inject.md", new File(assetsDst, "prompt-inject.md"));
            File script = new File(assetsDst, "purge-install.sh");
            copyAsset("purge-install.sh", script);
            log.line("应用 dsh-purge（清洗补丁）…");
            execScript("bash " + script.getAbsolutePath()
                    + " --assets=" + assetsDst.getAbsolutePath() + " --quiet");
            log.line("dsh-purge 完成");
        } catch (Throwable t) {
            log.line("dsh-purge 跳过（不影响启动）: " + t);
        }
    }

    void execScript(String script) throws Exception {
        List<String> cmd = Arrays.asList(new File(usr, "bin/bash").getAbsolutePath(), "-c", script);
        ProcessBuilder pb = new ProcessBuilder(cmd);
        pb.environment().clear();
        pb.environment().putAll(env());
        pb.redirectErrorStream(true);
        Process p = pb.start();
        BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
        String line;
        while ((line = r.readLine()) != null) log.line(line);
        int code = p.waitFor();
        if (code != 0) throw new IOException("命令失败(" + code + "): " + script);
    }

    private void copyAsset(String asset, File out) throws IOException {
        File parent = out.getParentFile();
        if (parent != null) parent.mkdirs();
        try (InputStream in = ctx.getAssets().open(asset);
             OutputStream os = new FileOutputStream(out)) {
            byte[] buf = new byte[1 << 16];
            int n;
            while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
        }
        try { Os.chmod(out.getAbsolutePath(), 0755); } catch (Exception ignored) {}
    }

    Map<String, String> env() {
        Map<String, String> e = new HashMap<>();
        e.put("PREFIX", usr.getAbsolutePath());
        e.put("HOME", home.getAbsolutePath());
        e.put("TMPDIR", new File(files, "tmp").getAbsolutePath());
        e.put("PATH", usr.getAbsolutePath() + "/bin:/system/bin");
        e.put("LD_LIBRARY_PATH", usr.getAbsolutePath() + "/lib");
        e.put("LANG", "C.UTF-8");
        e.put("TERM", "xterm-256color");
        e.put("npm_config_fund", "false");
        e.put("npm_config_audit", "false");
        e.put("npm_config_progress", "false");
        File cnf = new File(usr, "etc/tls/openssl.cnf");
        e.put("OPENSSL_CONF", cnf.isFile() ? cnf.getAbsolutePath() : "/dev/null");
        File cert = new File(usr, "etc/tls/cert.pem");
        if (cert.isFile()) {
            e.put("SSL_CERT_FILE", cert.getAbsolutePath());
            e.put("CURL_CA_BUNDLE", cert.getAbsolutePath());
        }
        return e;
    }
}