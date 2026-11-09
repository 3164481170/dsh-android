# dsh-android

把 [DeepSeek Harness](https://github.com/deepseek-ai)（下称 dsh）跑在 Android 手机上的**单 APK 方案**：点开即用，服务端和界面在同一个应用里，前台服务常驻，不需要 Termux，不需要电脑。

![界面](docs/img/app-ui.png)

## 下载

预编译 APK（arm64-v8a，debug 签名，不含本地扩展载荷）：

**[dsh-android-0.1.0-debug.apk](https://github.com/3164481170/dsh-android/releases/download/v0.1.0/dsh-android-0.1.0-debug.apk)** — 73.4 MB · [发布说明](https://github.com/3164481170/dsh-android/releases/tag/v0.1.0)

```
SHA256  3343b4022cc6ffae0da2b5e2a8a77cabaef6d603c3c0f90b76631e709dc93634
```

也可以自行构建，见下方「构建」。

## 它是什么

APK 内置了一套 ARM64 的 Linux 运行时（Termux bootstrap + node + npm）和 dsh 本体，首次启动时摊到应用私有目录，然后用前台服务把 `dsh web` 拉起来，WebView 直接连本机 `127.0.0.1` 加载界面。

- **没有电脑依赖**：所有东西都在手机上
- **不会被杀后台**：前台服务 + 常驻通知 + `PARTIAL_WAKE_LOCK`
- **工作区可见**：默认 `/sdcard/DSH/workspace`，文件管理器里能直接看到
- **自动打兼容补丁**：dsh 原本在 Android 上有 4 处硬伤，应用每次启动都会幂等修复

## 三种界面模式

启动时按系统 WebView 的能力自动选择，用户无感：

| 模式 | 触发条件 | 表现 |
|---|---|---|
| **L1 官方 SPA** | WebView ≥ 119（特性检测 `Promise.withResolvers`） | 完整官方界面，功能与桌面版一致 |
| **L0 内置客户端** | WebView 较旧 | 自带的精简客户端：会话列表 / 对话 / 发送 / 工具调用，保证能开 |
| **L2 外部浏览器** | 手动点「完整功能」 | 交给已安装的现代浏览器（Chrome/Cromite 等）打开同一地址 |

L0 不是重新实现 dsh，而是直接调它的 RPC（`session/list`、`session/create`、`session/prompt`、`session/page`），协议逆向结果见 [docs/mini-client-contract.md](docs/mini-client-contract.md)。

## 架构

```
┌─────────────────────────── Android APK ───────────────────────────┐
│                                                                    │
│  MainActivity ──WebView──► http://127.0.0.1:61374                 │
│       │                        │                                   │
│       │                  官方 SPA / 内置 mini-client               │
│       │                        │ HTTP + WebSocket                 │
│  ServerService（前台服务）      ▼                                   │
│       └──► node --expose-internals dsh/lib/bin.js --profile web    │
│                    │                                               │
│                    ├── $FILES/usr     Termux 运行时（bash/coreutils）│
│                    ├── $FILES/home    HOME，dsh 配置与会话          │
│                    └── /sdcard/DSH    用户可见工作区                │
└────────────────────────────────────────────────────────────────────┘
```

关键设计：**`targetSdk 28`**。Android 10+ 禁止应用从私有数据目录 `exec` 二进制，只有 `targetSdk < 29` 才允许（Termux 也是这么做的）。代价是要自己处理分区存储，见 [docs/android-porting-notes.md](docs/android-porting-notes.md)。

## 构建

前置：JDK 21、Android SDK（platform 34 + build-tools 34.0.0）、Gradle 8.9、Python 3。

```bash
# 1. 生成大体积运行时资源（不放在 Git 里，约 130 MB）
bash scripts/fetch-runtime.sh

# 2. 写 SDK 路径
echo 'sdk.dir=/path/to/android-sdk' > app/local.properties

# 3. 构建
cd app && gradle assembleDebug
# 产物：app/app/build/outputs/apk/debug/app-debug.apk
```

安装（首次约 5–8 分钟，要联网拉 dsh 依赖）：

```bash
adb install -r -g app-debug.apk
```

## 首次启动做了什么

1. 解包 `bootstrap.zip` 到 `files/usr`（bash、coreutils、openssl 等）
2. 拷贝 `node/`（node 26 + 动态库闭包）与 `npm.zip`
3. 改写 Termux 写死的前缀路径，重建符号链接，修权限
4. `npm i -g @deepseek-ai/dsh`
5. 跑 `patches/dsh-android-fix.sh`（4 项兼容补丁，幂等）
6. 若本地放入了自定义载荷（见下）则运行；仓库不带载荷，缺省直接跳过
7. 建工作区 `/sdcard/DSH/workspace` 并软链 `$HOME/默认`
8. 启动 `dsh web`，把带 token 的地址写进 `files/server.url`

## 目录结构

```
app/                    Gradle 工程（Java，无 Kotlin）
  app/src/main/java/com/dsh/runner/
    Bootstrap.java      运行时安装、补丁、工作区
    ServerService.java  前台服务，拉起并守护 node
    MainActivity.java   WebView 壳 + 三档界面选择
  app/src/main/assets/  大资产由 scripts/fetch-runtime.sh 生成
assets-src/             本地扩展载荷源（不分发，见「本地扩展」）
patches/                运行时补丁脚本
docs/                   协议文档、移植笔记
scripts/                取运行时、APK 验证、截图
```

## 本地扩展（不随仓库分发）

应用支持在启动时加载一份本地载荷（`assets-src/`、`assets/prompt-inject.md`、`assets/purge-install.sh`），
用于打自己的运行时定制补丁。这些路径已在 `.gitignore` 中排除，仓库里不含任何载荷内容；
缺失时安装流程会打印「跳过」并继续，不影响启动。

需要时把载荷放到对应路径再构建即可，接口约定是：

```
assets-src/purge/          载荷包目录
assets-src/prompt-inject.md 注入文本
patches/purge-install.sh   安装脚本（幂等，支持 --assets/--prefix/--home/--quiet）
```

## 已知限制

- 只支持 **arm64-v8a**，Android 8.0+（在 OnePlus 8 / Android 12 实测）
- 沙箱不可用：Android 内核默认禁 user namespace，且 4.19 无 Landlock，dsh 的 `bwrap` 沙箱在这类设备上跑不起来
- 缺原生模块时对应功能降级：`sharp`（图片处理）、LibreOffice（文档转 PDF）、sherpa-onnx（语音输入）
- 系统 WebView < 119 时只能走 L0 精简界面
- 首次启动需要网络；后续离线可用

## 排障

| 现象 | 原因 / 处理 |
|---|---|
| 界面白屏 | 系统 WebView 太旧，本应自动落到 L0；若仍白屏，看 `files/logs/server.log` |
| 启动失败 `flock is not supported on android-arm64` | 补丁未生效，重装或手工跑 `patches/dsh-android-fix.sh` |
| `Cannot find module 'internal/modules/esm/loader'` | 启动 node 时必须带 `--expose-internals` |
| 界面连不上 / 超时 | 服务被系统冻结；确认前台服务在跑，或把应用加入电池白名单 |
| `EPERM: mkdir '/sdcard/DSH'` | 缺存储权限（Android 12 对 targetSdk 28 也强制分区存储） |

更细的坑与解法见 [docs/android-porting-notes.md](docs/android-porting-notes.md)。

## 说明

本项目只包含"把 dsh 装进 Android 应用"的外壳与兼容层，不含 dsh 本体（运行时通过 npm 安装）。使用前请自行确认对 dsh 的使用符合其许可条款。
