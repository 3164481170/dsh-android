#!/data/data/com.termux/files/usr/bin/bash
# dsh-android-fix.sh —— 让 DeepSeek Harness 在 Termux/Android 上真正可用
# 幂等：可以反复执行。每次 npm i -g 升级、或 dsh 重建 profile 之后重跑一次即可。
set -u
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME="${HOME:-/data/data/com.termux/files/home}"
WORK=$HOME/.dsh-android
mkdir -p "$WORK"
export PATH=$PREFIX/bin:$PATH
export LD_LIBRARY_PATH=$PREFIX/lib

ok=0; skip=0; fail=0
good() { ok=$((ok+1)); printf '  [fix] %s\n' "$*"; }
keep() { skip=$((skip+1)); printf '  [ok ] %s\n' "$*"; }
bad()  { fail=$((fail+1)); printf '  [ERR] %s\n' "$*"; }

cat > "$WORK/patch-flock.mjs" <<'PATCHFLOCK'
import fs from 'node:fs';
const f = process.argv[2];
let s = fs.readFileSync(f, 'utf8');
if (s.includes('dsh-android fallback')) { console.log('already'); process.exit(0); }
const start = s.indexOf("if (platform !== 'linux' && platform !== 'darwin') {");
if (start < 0) { console.error('anchor-miss'); process.exit(3); }
const endMarker = '});\n    }';
const end = s.indexOf(endMarker, start);
if (end < 0) { console.error('end-miss'); process.exit(3); }
const replacement = [
  "if (platform !== 'linux' && platform !== 'darwin') {",
  '        // dsh-android fallback: no prebuilt native binding exists for this platform.',
  '        // A single local host process serialises its own writes, and the atomic',
  '        // write path commits through temp+rename, so an exclusive cross-process',
  '        // lock degrades to a no-op instead of failing the run.',
  '        binding = { tryLock(_fd, done) { done(0); } };',
  '        return binding;',
  '    }',
].join('\n');
s = s.slice(0, start) + replacement + s.slice(end + endMarker.length);
fs.writeFileSync(f, s);
console.log('patched');
PATCHFLOCK

cat > "$WORK/patch-session-link.mjs" <<'PATCHSESSION'
import fs from 'node:fs';
const f = process.argv[2];
let s = fs.readFileSync(f, 'utf8');
if (s.includes('android app-data mounts deny hardlinks')) { console.log('already'); process.exit(0); }
const needle = 'await link(tmp, finalPath);';
if (!s.includes(needle)) { console.error('anchor-miss'); process.exit(3); }
const block = [
  'try { await link(tmp, finalPath); } catch (linkError) {',
  '\t\t\t\tconst code = linkError?.code;',
  '\t\t\t\tif (code !== "EACCES" && code !== "EPERM" && code !== "EXDEV" && code !== "ENOTSUP" && code !== "EOPNOTSUPP") throw linkError;',
  '\t\t\t\t// android app-data mounts deny hardlinks',
  '\t\t\t\tconst { rename } = await import("node:fs/promises");',
  '\t\t\t\tawait rename(tmp, finalPath);',
  '\t\t\t}',
].join('\n');
s = s.replace(needle, block);
fs.writeFileSync(f, s);
console.log('patched');
PATCHSESSION


# ---------- 1. flock ----------
fix_flock() {
  f="$1"
  if grep -q 'dsh-android fallback' "$f" 2>/dev/null; then keep "flock: $f"; return; fi
  cp "$f" "$f.dshbak" 2>/dev/null
  if node "$WORK/patch-flock.mjs" "$f" >/dev/null 2>&1; then good "flock: $f"; else bad "flock: $f"; fi
}

# ---------- 2. require-builtin 垫片 ----------
make_shim() {
  loaderDir="$1"            # .../node_modules/node-addon-native-custom-loader
  target="$(dirname "$loaderDir")/node-addon-require-builtin-android-arm64"
  if [ -f "$target/index.js" ]; then keep "shim: $target"; return; fi
  mkdir -p "$target" || { bad "mkdir $target"; return; }
  cat > "$target/package.json" <<'EOJ'
{ "name": "node-addon-require-builtin-android-arm64", "version": "0.1.9", "main": "index.js" }
EOJ
  cat > "$target/index.js" <<'EOJ'
'use strict';
const { createRequire } = require('node:module');
const req = createRequire(__filename);
function requireBuiltin(moduleId) {
  try { return req(moduleId); } catch (e) {
    if (typeof moduleId === 'string' && moduleId.startsWith('node:')) return req(moduleId.slice(5));
    throw e;
  }
}
function isAllowedInternalId() { return false; }
function getNativeBindingInfo() {
  return { mode: 'js-shim', product: 'require-builtin', backend: 'napi', abi: 'napi-v9' };
}
module.exports = { requireBuiltin, isAllowedInternalId, getNativeBindingInfo, bindingPath: __filename };
EOJ
  good "shim: $target"
}

# ---------- 3. 硬链接 -> rename ----------
fix_session() {
  f="$1"
  if grep -q 'android app-data mounts deny hardlinks' "$f" 2>/dev/null; then keep "session: $f"; return; fi
  cp "$f" "$f.dshbak" 2>/dev/null
  if node "$WORK/patch-session-link.mjs" "$f" >/dev/null 2>&1; then good "session: $f"; else bad "session: $f"; fi
}

# ---------- 4. node-pty 预编译 ----------
fix_pty() {
  d="$1"; src="$PREFIX/lib/node_modules/node-pty/prebuilds/android-arm64/pty.node"
  [ -f "$d/prebuilds/android-arm64/pty.node" ] && { keep "pty: $d"; return; }
  [ -f "$src" ] || src="$HOME/pty.node"
  [ -f "$src" ] || { bad "pty source missing: $src"; return; }
  mkdir -p "$d/prebuilds/android-arm64" && cp -f "$src" "$d/prebuilds/android-arm64/pty.node" \
    && good "pty: $d" || bad "pty: $d"
}

printf '=== 1/4 flock (android-arm64 无原生绑定) ===\n'
for f in $(find "$PREFIX/lib/node_modules" "$HOME/.dsh" -name flock.js -path '*node-addon-system*' 2>/dev/null); do fix_flock "$f"; done

printf '=== 2/4 require-builtin 垫片 ===\n'
for p in $(find "$PREFIX/lib/node_modules" "$HOME/.dsh" -type d -name node-addon-native-custom-loader 2>/dev/null); do make_shim "$p"; done

printf '=== 3/4 session 持久化硬链接回退 ===\n'
for f in $(find "$PREFIX/lib/node_modules" "$HOME/.dsh" -path '*dsh-session-persistence-jsonl*' -name index.js 2>/dev/null); do fix_session "$f"; done

printf '=== 4/4 node-pty android 预编译 ===\n'
for d in $(find "$PREFIX/lib/node_modules" "$HOME/.dsh" -type d -name node-pty 2>/dev/null); do fix_pty "$d"; done

printf '\n结果: 修复 %s / 已就绪 %s / 失败 %s\n\n' "$ok" "$skip" "$fail"
printf '启动（必须带 --expose-internals）:\n'
printf '  node --expose-internals %s/lib/node_modules/@deepseek-ai/dsh/lib/bin.js --profile web --host 127.0.0.1 --port 61374 --no-open\n' "$PREFIX"
[ "$fail" -gt 0 ] && exit 1
exit 0
