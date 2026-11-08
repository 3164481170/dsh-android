#!/usr/bin/env bash
# 生成本项目不在 Git 里保存的大体积运行时资源
#
#   bash scripts/fetch-runtime.sh
#
# 产物（全部落在 app/app/src/main/assets/，已被 .gitignore 忽略）：
#   bootstrap.zip        Termux 引导包（提供 bash/coreutils 等）
#   node/bin/node        aarch64 版 node
#   node/lib/*.so        node 的动态库闭包
#   npm.zip              npm（打包成 zip，避免 aapt2 丢弃下划线目录）
#   purge/               dsh-purge 载荷（从 assets-src/ 复制）
#
# 另外需要你自备一个 Android 版 pty.node（node-pty 为 android-arm64 预编译的二进制），
# 放到 app/app/src/main/assets/pty.node；缺省时只影响 PTY 终端功能。
set -euo pipefail

cd "$(dirname "$0")/.."
ASSETS="app/app/src/main/assets"
CACHE="dist"
mkdir -p "$ASSETS/node/bin" "$ASSETS/node/lib" "$CACHE"

TERMUX="https://packages-cf.termux.dev/apt/termux-main"
BOOTSTRAP="https://github.com/termux/termux-packages/releases/latest/download/bootstrap-aarch64.zip"

echo "==> 1/5 Termux bootstrap"
if [ ! -f "$CACHE/bootstrap-aarch64.zip" ]; then
  curl -fL --retry 3 -o "$CACHE/bootstrap-aarch64.zip" "$BOOTSTRAP"
fi
cp -f "$CACHE/bootstrap-aarch64.zip" "$ASSETS/bootstrap.zip"

echo "==> 2/5 node（从 Termux deb 取二进制 + 动态库闭包）"
NODE_DEB_URL=$(
  curl -fsSL "$TERMUX/dists/stable/main/binary-aarch64/Packages" | awk '
    /^Package: nodejs$/ {p=1} p && /^Version:/ {v=$2} p && /^Filename:/ {print $2; exit}'
)
echo "    $NODE_DEB_URL"
[ -f "$CACHE/nodejs.deb" ] || curl -fL --retry 3 -o "$CACHE/nodejs.deb" "$TERMUX/$NODE_DEB_URL"

rm -rf "$CACHE/nodex" && mkdir -p "$CACHE/nodex"
( cd "$CACHE/nodex" && ar x ../nodejs.deb && tar -xf data.tar.xz )
NODE_ROOT="$CACHE/nodex/data/data/com.termux/files/usr"

cp -f "$NODE_ROOT/bin/node" "$ASSETS/node/bin/node"
chmod 755 "$ASSETS/node/bin/node"

# node 的动态库闭包（aarch64, Termux 构建）
LIBS="libz.so.1 libz.so.1.4 libsqlite3.so libsqlite3.so.3.54.1 \
libicui18n.so.78 libicui18n.so.78.3 libicuuc.so.78 libicuuc.so.78.3 libicudata.so.78 libicudata.so.78.3 \
libcares.so libffi.so libcrypto.so.3 libssl.so.3 libc++_shared.so"
for l in $LIBS; do
  [ -e "$NODE_ROOT/lib/$l" ] && cp -a "$NODE_ROOT/lib/$l" "$ASSETS/node/lib/" || echo "    [warn] 缺少 $l"
done

echo "==> 3/5 npm（打包成 zip）"
NPM_DEB_URL=$(
  curl -fsSL "$TERMUX/dists/stable/main/binary-aarch64/Packages" | awk '
    /^Package: npm$/ {p=1} p && /^Filename:/ {print $2; exit}'
)
[ -f "$CACHE/npm.deb" ] || curl -fL --retry 3 -o "$CACHE/npm.deb" "$TERMUX/$NPM_DEB_URL"

rm -rf "$CACHE/npmx" && mkdir -p "$CACHE/npmx"
( cd "$CACHE/npmx" && ar x ../npm.deb && tar -xf data.tar.xz )
NPM_ROOT="$CACHE/npmx/data/data/com.termux/files/usr/lib/node_modules/npm"

python3 - "$NPM_ROOT" "$ASSETS/npm.zip" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
n = 0
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
    for root, _dirs, files in os.walk(src):
        for f in files:
            full = os.path.join(root, f)
            rel = os.path.relpath(full, src).replace(os.sep, "/")
            z.write(full, "lib/node_modules/npm/" + rel)
            n += 1
print(f"    npm.zip: {n} entries")
PY

echo "==> 4/5 dsh-purge 载荷"
rm -rf "$ASSETS/purge"
cp -a assets-src/purge "$ASSETS/purge"
cp -f assets-src/prompt-inject.md "$ASSETS/prompt-inject.md"

echo "==> 5/5 校验"
[ -f "$ASSETS/pty.node" ] || echo "    [warn] 缺少 pty.node，PTY 终端功能将不可用"
ls -la "$ASSETS" | sed 's/^/    /'
echo "完成。大资产共 $(du -sh "$ASSETS" | cut -f1)"
