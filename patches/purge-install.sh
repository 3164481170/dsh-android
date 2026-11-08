#!/usr/bin/env bash
# purge-install.sh — 把 dsh-purge 装进 Android/Termux 上的 DSH 运行时
#
# 设计前提：这是 APK 首次启动时的一次性补装步骤，任何时候都不能拖死 DSH 启动。
#   * 幂等：重复执行结果一致；已应用过则默认跳过（--force 强制重跑）
#   * 容错：任何一步失败只打印 WARN 并继续，脚本始终以 0 退出
#   * 无外部依赖：只用 Termux 自带 coreutils + node
#
# 用法：
#   bash purge-install.sh [--force] [--quiet]
#        [--assets=DIR] [--prefix=DIR] [--home=DIR]
#
# 环境变量（同名命令行参数优先）：
#   PREFIX / DSH_PREFIX         Termux 前缀        默认 /data/data/com.termux/files/usr
#   HOME   / DSH_HOME_DIR       用户主目录        默认 /data/data/com.termux/files/home
#   PURGE_ASSETS                assets 解出目录    默认自动探测（含 purge/ 与 prompt-inject.md）
#   DSH_BASE                    宿主插件根          默认自动探测
#   DSH_PROFILE                 宿主 surface        默认 web
#   DSH_PURGE_RESTART           重启载荷            默认 0（本脚本不触发宿主重启）
#   PURGE_NODE_TIMEOUT          单次 node 调用上限  默认 90（秒，需 timeout 可用）

set -u
umask 022

FORCE=0
QUIET=0
LOG_PREFIX="[purge-install]"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)   FORCE=1 ;;
    --quiet)   QUIET=1 ;;
    --assets=*) PURGE_ASSETS="${1#*=}" ;;
    --prefix=*) DSH_PREFIX_ARG="${1#*=}" ;;
    --home=*)   DSH_HOME_ARG="${1#*=}" ;;
    -h|--help)
      sed -n '2,20p' "$0" 2>/dev/null
      exit 0
      ;;
    *) printf '%s 忽略未知参数: %s\n' "$LOG_PREFIX" "$1" >&2 ;;
  esac
  shift
done

say()  { [ "$QUIET" -eq 1 ] || printf '%s %s\n' "$LOG_PREFIX" "$*"; }
warn() { printf '%s WARN %s\n' "$LOG_PREFIX" "$*" >&2; }

# ---------- 路径解析 ----------

TPREFIX="${DSH_PREFIX_ARG:-${PREFIX:-/data/data/com.termux/files/usr}}"
THOME="${DSH_HOME_ARG:-${HOME:-/data/data/com.termux/files/home}}"
DSH_HOME_DIR="$THOME/.dsh"
LOG="$DSH_HOME_DIR/purge-apply.log"
APPLY_STAMP="$DSH_HOME_DIR/.purge-applied"
PKG_ROOT="$TPREFIX/lib/node_modules/dsh-purge"

mkdir -p "$DSH_HOME_DIR" 2>/dev/null || warn "无法创建 $DSH_HOME_DIR（继续，仅控制台输出）"

log() { printf '%s\n' "$*" >>"$LOG" 2>/dev/null; }
stamp_log() { printf '\n===== %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" >>"$LOG" 2>/dev/null; }

log "== purge-install.sh prefix=$TPREFIX home=$THOME force=$FORCE"

# ---------- 定位 assets ----------

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
ASSETS_DIR=""
for cand in   "${PURGE_ASSETS:-}"   "$SCRIPT_DIR"   "$SCRIPT_DIR/.."   "$SCRIPT_DIR/../assets-src"   "$DSH_HOME_DIR/purge-assets"   "$THOME/dsh-assets"   "$THOME/.dsh/assets-src"
do
  [ -n "$cand" ] || continue
  if [ -f "$cand/purge/package.json" ]; then ASSETS_DIR="$cand"; break; fi
done

if [ -z "$ASSETS_DIR" ]; then
  warn "未找到 assets 目录（需要其中同时有 purge/ 与 prompt-inject.md），跳过安装"
  log "WARN assets not found"
  exit 0
fi
say "assets: $ASSETS_DIR"
log "assets=$ASSETS_DIR"

# ---------- node ----------

NODE_BIN=""
for cand in "$(command -v node 2>/dev/null)" "$TPREFIX/bin/node" "$THOME/.dsh/node/bin/node"; do
  [ -n "$cand" ] && [ -x "$cand" ] && { NODE_BIN="$cand"; break; }
done
if [ -z "$NODE_BIN" ]; then
  warn "未找到可执行的 node，跳过 --apply / --status（插件文件仍会复制）"
  log "WARN node not found"
fi

TIMEOUT_BIN="$(command -v timeout 2>/dev/null || true)"
NODE_TIMEOUT="${PURGE_NODE_TIMEOUT:-90}"

run_node() {
  # $@ = node 参数；成功 0，失败非 0，超时非 0
  [ -n "$NODE_BIN" ] || return 127
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$NODE_TIMEOUT" "$NODE_BIN" "$@"
  else
    "$NODE_BIN" "$@"
  fi
}

# ---------- 1) 复制插件包 ----------

SRC_VERSION=""
if [ -f "$ASSETS_DIR/purge/package.json" ]; then
  SRC_VERSION="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ASSETS_DIR/purge/package.json" 2>/dev/null | head -n 1)"
fi
[ -n "$SRC_VERSION" ] || SRC_VERSION="unknown"

copy_pkg() {
  mkdir -p "$TPREFIX/lib/node_modules" 2>/dev/null || { warn "无法创建 $TPREFIX/lib/node_modules"; return 1; }
  rm -rf "$PKG_ROOT.new" 2>/dev/null
  if ! cp -a "$ASSETS_DIR/purge" "$PKG_ROOT.new" 2>/dev/null; then
    rm -rf "$PKG_ROOT.new" 2>/dev/null
    cp -R "$ASSETS_DIR/purge" "$PKG_ROOT.new" 2>/dev/null || { warn "复制插件包失败"; return 1; }
  fi
  chmod +x "$PKG_ROOT.new/bin/dsh-purge.js" 2>/dev/null
  chmod -R u+rwX,go+rX "$PKG_ROOT.new" 2>/dev/null
  rm -rf "$PKG_ROOT.old" 2>/dev/null
  if [ -d "$PKG_ROOT" ]; then
    mv "$PKG_ROOT" "$PKG_ROOT.old" 2>/dev/null || { warn "无法移开旧版本，改为原地覆盖"; rm -rf "$PKG_ROOT" 2>/dev/null; }
  fi
  if ! mv "$PKG_ROOT.new" "$PKG_ROOT" 2>/dev/null; then
    warn "安装到 $PKG_ROOT 失败"
    [ -d "$PKG_ROOT.old" ] && mv "$PKG_ROOT.old" "$PKG_ROOT" 2>/dev/null
    return 1
  fi
  rm -rf "$PKG_ROOT.old" 2>/dev/null
  return 0
}

if [ "$FORCE" -eq 0 ] && [ -f "$PKG_ROOT/package.json" ] && [ -f "$PKG_ROOT/bin/dsh-purge.js" ] \
   && [ "$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$PKG_ROOT/package.json" 2>/dev/null | head -n 1)" = "$SRC_VERSION" ]; then
  say "插件包已是 $SRC_VERSION，跳过复制"
  log "pkg skip (already $SRC_VERSION)"
else
  if copy_pkg; then
    say "插件包已安装到 $PKG_ROOT ($SRC_VERSION)"
    log "pkg installed $SRC_VERSION -> $PKG_ROOT"
  fi
fi

# ---------- 2) 注入提示词 ----------

SRC_PROMPT="$ASSETS_DIR/prompt-inject.md"
DST_PROMPT="$DSH_HOME_DIR/prompt-inject.md"
if [ -f "$SRC_PROMPT" ]; then
  if [ -f "$DST_PROMPT" ] && cmp -s "$SRC_PROMPT" "$DST_PROMPT" 2>/dev/null; then
    say "prompt-inject.md 未变化，跳过"
    log "prompt skip (identical)"
  else
    if [ -f "$DST_PROMPT" ]; then
      cp -f "$DST_PROMPT" "$DST_PROMPT.bak" 2>/dev/null && log "prompt backup -> $DST_PROMPT.bak"
    fi
    if cp -f "$SRC_PROMPT" "$DST_PROMPT" 2>/dev/null; then
      say "prompt-inject.md 已写入 $DST_PROMPT"
      log "prompt installed -> $DST_PROMPT"
    else
      warn "写入 $DST_PROMPT 失败"
      log "WARN prompt write failed"
    fi
  fi
else
  warn "assets 中缺少 prompt-inject.md，跳过"
  log "WARN prompt-inject.md missing"
fi

# ---------- 3) 环境变量 + 宿主插件根探测 ----------

# 这三个变量按约定强制设定：不吃宿主的继承值，避免 APK 启动环境里
# 已有 DSH_PROFILE=desktop / DSH_PURGE_RESTART=<payload> 把 web 清洗打到错的分支。
export DSH_HOME="$DSH_HOME_DIR"
export DSH_PROFILE="${PURGE_PROFILE:-web}"
export DSH_PURGE_RESTART="0"

if [ -z "${DSH_BASE:-}" ]; then
  for cand in \
    "$TPREFIX/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai" \
    "$TPREFIX/lib/node_modules/@deepseek-ai" \
    "$TPREFIX/lib/node_modules/dsh/node_modules/@deepseek-ai" \
    "$TPREFIX/lib/node_modules/dsh/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai" \
    "$TPREFIX/lib/node_modules/dsh/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai" \
    "$THOME/node_modules/@deepseek-ai"
  do
    if [ -d "$cand/dsh-agent-instructions/lib" ]; then
      export DSH_BASE="$cand"
      break
    fi
  done
fi
if [ -z "${DSH_BASE:-}" ]; then
  found="$(find "$TPREFIX/lib/node_modules" -maxdepth 6 -type d -name dsh-agent-instructions 2>/dev/null | head -1)"
  [ -n "$found" ] && export DSH_BASE="${found%/dsh-agent-instructions}"
fi
[ -n "${DSH_BASE:-}" ] || warn "未探测到 DSH_BASE（插件根），--apply 可能以 exit 1 结束，已容错"
log "env DSH_HOME=$DSH_HOME DSH_PROFILE=$DSH_PROFILE DSH_BASE=${DSH_BASE:-<unset>} DSH_PURGE_RESTART=$DSH_PURGE_RESTART"

# ---------- 4) --apply ----------

PURGE_BIN="$PKG_ROOT/bin/dsh-purge.js"
if [ -z "$NODE_BIN" ] || [ ! -f "$PURGE_BIN" ]; then
  warn "缺少 node 或 $PURGE_BIN，跳过 --apply / --status"
  log "WARN skip apply (node=$NODE_BIN bin=$PURGE_BIN)"
else
  if [ "$FORCE" -eq 0 ] && [ -f "$APPLY_STAMP" ] && [ "$(cat "$APPLY_STAMP" 2>/dev/null)" = "$SRC_VERSION" ]; then
    say "已应用过 $SRC_VERSION，跳过 --apply（--force 可强制重跑）"
    log "apply skip (stamped $SRC_VERSION)"
  else
    stamp_log
    log "cmd: $PURGE_BIN --apply"
    if run_node "$PURGE_BIN" --apply >>"$LOG" 2>&1; then
      printf '%s' "$SRC_VERSION" >"$APPLY_STAMP" 2>/dev/null
      say "--apply 完成，日志：$LOG"
    else
      warn "--apply 未成功（宿主可能未定位），已容错，详情见 $LOG"
      log "WARN apply failed"
    fi
  fi

  # ---------- 5) --status（每次都追加，便于事后排查） ----------
  stamp_log
  log "cmd: $PURGE_BIN --status"
  if ! run_node "$PURGE_BIN" --status >>"$LOG" 2>&1; then
    warn "--status 执行失败（不阻塞启动）"
    log "WARN status failed"
  fi
fi

say "完成（任何失败都不会阻塞 DSH 启动）"
exit 0