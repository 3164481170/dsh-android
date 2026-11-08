# Android 真机验证脚本

`scripts` 目录下三个文件，用于反复验证 `com.dsh.runner` 在 OnePlus 8（Android 12 / arm64，序列号 `b82a026f`）上的安装与启动。

> adb 不在 PATH：`C:\Program Files\ASUS\GlideX\adb.exe`。脚本已内置该路径，可用 `-Adb` 覆盖。

## 1. verify-apk.ps1 —— 装包 → 启动 → 等服务 → PC 端验证

```powershell
# 标准流程：卸载旧包 + 安装 + 启动 + 最多等 15 分钟
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify-apk.ps1

# 反复验证：跳过卸载（复用已解包的 Termux 运行时，快很多），只等 5 分钟
pwsh -NoProfile -File .\verify-apk.ps1 -KeepAppData -TimeoutMin 5

# 只检查 adb / 设备 / APK，不装不启动
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify-apk.ps1 -DryRun
```

参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-TimeoutMin` | 15 | 等待 `server.url` 出现的最长分钟数（首装建议 25-30） |
| `-ApkPath` | `E:\dsh-android\app\app\build\outputs\apk\debug\app-debug.apk` | 待装 APK |
| `-Serial` | `b82a026f` | 设备序列号 |
| `-Adb` | `C:\Program Files\ASUS\GlideX\adb.exe` | adb 可执行文件 |
| `-Package` / `-Activity` | `com.dsh.runner` / `com.dsh.runner/.MainActivity` | 包与入口 |
| `-DevicePort` / `-LocalPort` | 61374 / 16137 | adb forward 映射 |
| `-PollSec` | 20 | 轮询间隔秒数 |
| `-KeepAppData` | 关 | 跳过卸载，`-r` 覆盖安装并复用私有目录 |
| `-DryRun` | 关 | 只做只读检查并打印将执行的命令 |
| `-ResultJson` | `scripts\verify-last.json` | 结构化结果落盘位置 |

流程与 PHASE：

1. `install` —— `adb uninstall`（失败忽略）→ `adb push` 到 `/data/local/tmp` → `pm install -r -g`。
   大 APK 走 push + `pm install`，不用 `adb install`（streamed install 在几百 MB 时会挂）。
2. `start` —— `logcat -c` → `am start -n com.dsh.runner/.MainActivity`。
3. `wait` —— 每 20 秒读 `files/server.url`、`logcat -s DshRunner:V`、`files/logs/server.log` 尾部、`pidof`、崩溃行。
4. `ok` —— 拿到 `http://127.0.0.1:61374/?token=...` → `adb forward tcp:16137 tcp:61374` → PC 端 `GET /?token=...` 期望 **303**。
5. `fail` —— 打印 3 条最可能原因 + 可复制诊断命令。

判定依据（`ServerService` 与 dsh web 的鉴权实现）：

- `GET /`（无 token）→ **401**，属正常。
- `GET /?token=<server.url 里的 token>` → **303** + `Location: ./` + `Set-Cookie`，说明服务活着且 token 正确。
- 200 也算活着（个别版本不重定向），401 表示 token 不匹配。

输出：终端有 PHASE 时间线、关键日志、RESULT 结果块；同时写 `scripts\verify-last.json`（token 已打码）。
退出码：`0` 成功 / `1` 验证失败 / `2` 前置条件不满足（adb、设备、APK）。
`-DryRun` 即使设备不在线或 APK 未构建，也只预览命令并返回 0。

验证通过后 token 不打印，用脚本给出的这行命令复制到剪贴板，再在 PC 浏览器打开：

```powershell
$u = (& "C:\Program Files\ASUS\GlideX\adb.exe" -s b82a026f shell run-as com.dsh.runner cat files/server.url).Trim(); ($u -replace ':61374', ':16137') | Set-Clipboard
```

## 2. shot.ps1 —— 截屏看界面

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\shot.ps1
pwsh -NoProfile -File .\shot.ps1 -Open      # 截完直接打开
```

落盘到 `E:\dsh-android\shots\<yyyyMMdd-HHmmss>.png`，最后一行输出 `SHOT <路径> (<KB> KB, <时间戳>)`。
实现用 `screencap -p /sdcard/...` + `adb pull` + `rm`，不用 `exec-out` 直出，避免 PowerShell 重定向把 PNG 字节写坏。
参数：`-OutDir`（默认 `E:\dsh-android\shots`）、`-Serial`、`-Adb`、`-Open`。退出码 0/1。

## 3. 常见失败与排查

下面命令里用 `$A` 代表 adb 全路径：

```powershell
$A = "C:\Program Files\ASUS\GlideX\adb.exe"
```

### 3.1 应用崩溃（一启动就没进程）

现象：PHASE=fail，`pidof` 为空，logcat 有 `FATAL EXCEPTION`。

```powershell
& $A -s b82a026f logcat -d -b crash
& $A -s b82a026f logcat -d -s DshRunner:V
& $A -s b82a026f shell run-as com.dsh.runner tail -n 100 files/logs/server.log
& $A -s b82a026f shell run-as com.dsh.runner ls -l files/usr/bin files/usr/lib
```

常见根因：

- `UnsatisfiedLinkError` / `INSTALL_FAILED_NO_MATCHING_ABIS` → APK 里缺 arm64-v8a（看 `abiFilters`，别混 x86_64 库）。
- assets 里的 `bootstrap.zip` / `node/` / `symlinks.txt` 缺失 → 解包阶段就抛异常，重打 assets 后重装。
- 私有目录没有执行权限 → `files/usr/bin/node` 存在但 chmod 没生效，看 `ls -l` 的权限位。

### 3.2 首装耗时长（不是失败）

现象：日志停在「解包 bootstrap…」「安装运行时…」「安装 dsh（首次较慢）…」，`server.url` 还没出现。

```powershell
& $A -s b82a026f shell run-as com.dsh.runner tail -n 20 files/logs/server.log
& $A -s b82a026f shell run-as com.dsh.runner du -sh files/usr files/home
& $A -s b82a026f shell df -h /data
```

首装解包 Termux 运行时 + 安装 dsh 在真机上 5-10 分钟属正常。做法：

- 用 `-TimeoutMin 30` 重跑。
- 已装过一次就别再卸载：加 `-KeepAppData` 覆盖安装，复用 `files/usr`、`files/home`。
- 屏幕别熄：保持解锁，省电模式会明显拖慢解包。

### 3.3 网络不通导致 npm 失败

现象：`server.log` 里出现 `ENOTFOUND` / `EAI_AGAIN` / `ETIMEDOUT` / `ECONNREFUSED` / `npm ERR!` / `self-signed certificate`。

```powershell
& $A -s b82a026f shell run-as com.dsh.runner tail -n 120 files/logs/server.log
& $A -s b82a026f shell ping -c 3 registry.npmjs.org
& $A -s b82a026f shell settings get global http_proxy
& $A -s b82a026f shell run-as com.dsh.runner cat files/home/.npmrc
```

做法：

- 换可达 registry / 代理，写进 `files/home/.npmrc`：
  `adb shell run-as com.dsh.runner sh -c 'printf "registry=https://registry.npmmirror.com\n" > files/home/.npmrc'`
- 手机走代理但 node 不走 → 在 `Bootstrap.env()` 里补 `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY=127.0.0.1,localhost`。
- 证书报错 → 先确认设备时间正确（`adb shell date`），再考虑给 node 加 `--use-openssl-ca`。

### 3.4 WebView 白屏（服务正常但页面出不来）

现象：`verify-apk.ps1` 已打印 `HTTP 303`，真机界面却是黑底/白屏。

```powershell
.\shot.ps1 -Open
& $A -s b82a026f logcat -d -s chromium:V | Select-Object -Last 60
& $A -s b82a026f shell run-as com.dsh.runner cat files/server.url
& $A -s b82a026f forward tcp:16137 tcp:61374
```

判断顺序：

1. PC 浏览器打开同一 URL（带 token）能否出页面 → 能出说明后端没问题，问题在 WebView。
2. 看 `logcat -s chromium:V` 里有没有 `net::ERR_*`；有就是 WebView 连 127.0.0.1 被挡。
3. 点应用内「重载界面」「日志」按钮，必要时「重启服务」。
4. 前端路由 404：`GET /` 带 token 应 303 到 `./`，再查 `usesCleartextTraffic`（已为 true）与 `setAllowFileAccess(false)` 是否挡了资源。

## 4. 其他常用命令

```powershell
& $A -s b82a026f shell dumpsys activity services com.dsh.runner     # 前台服务是否在跑
& $A -s b82a026f shell dumpsys window | Select-String mCurrentFocus # 当前前台窗口
& $A -s b82a026f forward --list                                     # 现有端口映射
& $A -s b82a026f forward --remove tcp:16137                         # 清理映射
& $A -s b82a026f shell am force-stop com.dsh.runner                 # 强杀，重新开始
& $A -s b82a026f uninstall com.dsh.runner                           # 彻底清掉私有目录
& $A -s b82a026f shell pm path com.dsh.runner                       # 确认安装路径
```

## 5. 注意

- 脚本只写 `E:\dsh-android\scripts\`（结果 JSON）与 `E:\dsh-android\shots\`（截图）。
- 首次启动系统会弹「忽略电池优化」授权框，脚本不会自动点；不影响服务启动，但建议手动允许，否则后台常驻容易被杀。
- 同一时刻不要和别的 adb 操作并行：adb server 会把命令串行化，push 70 MB 期间看起来像卡住，长时间无输出属正常等待。
