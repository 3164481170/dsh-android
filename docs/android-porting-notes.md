# Android 移植笔记

把 dsh 塞进 APK 的过程中踩到的坑，按"症状 → 根因 → 解法"记录，方便换机或升级时少走一遍。

## 1. targetSdk 必须是 28

**症状**：应用内 `exec` node 直接 `EACCES`。

**根因**：Android 10（API 29）起禁止应用从可写数据目录执行二进制（W^X）。

**解法**：`targetSdk 28`，和 Termux 同一策略。副作用是分区存储也按旧规则走：需要在 manifest 里声明
`READ/WRITE_EXTERNAL_STORAGE` + `android:requestLegacyExternalStorage="true"`，否则连 `/sdcard/DSH` 都建不了。

## 2. aapt2 会丢掉下划线开头的资源目录

**症状**：npm 启动即崩，`Cannot find module './__generated__/envelope'`。

**根因**：`@sigstore/protobuf-specs/dist/__generated__/` 这类以 `_` 开头的目录在打包时被 aapt 过滤掉了。

**解法**：不要把 npm 以目录形式放进 `assets/`，改成 `npm.zip`，运行时自己解压。

## 3. Termux bootstrap 里写死 `/data/data/com.termux`

**症状**：
- `bash: /data/data/com.termux/files/usr/etc/profile: Permission denied`
- `node: OpenSSL configuration error: ... fopen(/data/data/com.termux/files/usr/etc/tls/openssl.cnf)`

**根因**：bootstrap 是按 `com.termux` 的路径编的，换到自己的包名后全部指向别人的数据目录（存在但不可读）。

**解法**：
1. 解包后把 `etc/tls/openssl.cnf`、`etc/profile`、`etc/bash.bashrc` 等文本里的旧前缀替换成本应用 prefix（`Bootstrap#rewriteTermuxPaths`）
2. 显式设 `OPENSSL_CONF` / `SSL_CERT_FILE` / `CURL_CA_BUNDLE` 指向自己的 `etc/tls/`
3. 调用 bash 用 `-c` 而不是 `-lc`，避开 login profile

## 4. npm 的 shebang 指向 Termux

**症状**：`npm: command not found`。

**根因**：Termux 的 `npm`/`node` 是独立 deb，`bin/npm` 的 shebang 是 `#!/data/data/com.termux/files/usr/bin/node`。

**解法**：不依赖 shebang，直接 `node $PREFIX/lib/node_modules/npm/bin/npm-cli.js i -g <pkg>`。

## 5. node-pty 没有 android 预编译

**症状**：`pty source missing`，PTY 相关功能不可用。

**根因**：npm 12 默认跳过 native 构建脚本，且 `node-pty` 官方不发 android 产物。

**解法**：从 Termux 里已修好的安装中取 `prebuilds/android-arm64/pty.node`，作为 assets 一起打包，
启动时复制到 `$HOME/pty.node`，由补丁脚本搬到 `node-pty/prebuilds/android-arm64/`。
**注意顺序**：必须先复制 pty.node 再跑补丁脚本。

## 6. Android 12 上 `run-as` 测不了 sdcard

**症状**：`run-as com.xxx mkdir /sdcard/DSH` 返回 Permission denied。

**根因**：`run-as` 的 SELinux 上下文是 `runas_app`，本来就没有外部存储权限。

**结论**：**不要用 `run-as` 判断存储权限**，要在应用进程里测（例如通过 RPC 调 `session/create`）。

## 7. 系统 WebView 升级被签名白名单卡住

**症状**：`pm install` 一个第三方 WebView（如 Cromite）后，
`dumpsys webviewupdate` 报 `Invalid package ... reason: Incorrect signature`。

**根因**：framework 的 `config_webview_packages` 里，非系统应用不被接受；报错文案有误导性。

**解法**（需要 root）：
1. 用 Magisk 模块把 APK 装成**系统应用**：`/data/adb/modules/<id>/system/app/<Name>/<Name>.apk`
2. 重启，此时 `dumpsys webviewupdate` 会显示 `Valid package`
3. `su -c "cmd webviewupdate set-webview-implementation <包名>"` 切过去

回滚：`cmd webviewupdate set-webview-implementation com.google.android.webview` + 删模块重启。

## 8. WebView 加载旧 token

**症状**：服务重启后界面 `ERR_CONNECTION_REFUSED`，地址里的 token 是上一轮的。

**根因**：`server.url` 先被删除再写入，客户端可能在中间态读到旧值。

**解法**：客户端记录 `lastUrl`，URL 变化就重载；并在 `onReceivedError`（主框架）里延迟 2 秒重试。

## 9. dsh-purge 的 DSH_BASE 探测

**症状**：安装日志出现 `WARN 未探测到 DSH_BASE（插件根）`。

**根因**：插件真实根在 `$PREFIX/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai`，
候选列表里少了作用域那一层。

**解法**：补上该路径，并加 `find -maxdepth 6 -name dsh-agent-instructions` 兜底。

## 10. run_code 环境里的 PowerShell 陷阱（开发期）

- 模板字符串里的反引号会打断 TS 语法，用 `[char]10` 代替 `\`n`
- 双引号字符串里的 `$VAR` 会在本机展开，设备侧脚本要么用单引号，要么写文件再 `cat >` 推过去
- `$args` 是 PowerShell 自动变量，别当参数名

## 环境基线（实测）

- 设备：OnePlus 8 IN2010，Android 12（SDK 31），arm64-v8a，内核 4.19.157
- 运行时：Termux bootstrap + node 26.13.0 + npm 12.2.2 + dsh 0.2.2-rc.1
- 系统 WebView 97 → 升级到 Cromite 153（Magisk 系统应用）
