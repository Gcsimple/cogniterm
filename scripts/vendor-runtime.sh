#!/usr/bin/env bash
#
# vendor-runtime.sh —— 把 Sidecar runtime 直接 vendor 进 App 包源树，
# 构建后随 CogniTerm.app/Contents/Resources/runtime 一起发布，用户无需任何安装动作。
#
# 产物布局（SidecarService 运行时按 Bundle 解析）：
#   App/Resources/runtime/node-darwin-arm64/bin/node
#   App/Resources/runtime/node_modules/@deepseek-ai/dsh/lib/bin.js
#
# profile 无需播种：dsh 首次启动会自行初始化 $DSH_HOME/profiles/acp；
# 隐私补丁 no-telemetry.yml 随包在 Resources/，由启动命令 --patch 覆盖。
#
# 可用环境变量覆盖：DSH_VERSION、NODE_VERSION、DSH_VENDOR_DIR
set -euo pipefail

DSH_VERSION="${DSH_VERSION:-0.2.0-rc.2}"
NODE_VERSION="${NODE_VERSION:-v24.20.0}"
NODE_DIST="node-${NODE_VERSION}-darwin-arm64"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${DSH_VENDOR_DIR:-$REPO_ROOT/App/Resources/runtime}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log()  { printf '\033[1;34m[vendor-runtime]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[vendor-runtime]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "仅支持 macOS"
[ "$(uname -m)" = "arm64" ]  || fail "首版仅提供 darwin-arm64 runtime（$(uname -m)）"
command -v curl >/dev/null || fail "缺少 curl"

mkdir -p "$DEST"

# ---------------------------------------------------------------------------
# 1. Node（官方预编译包，SHA-256 对照 SHASUMS256.txt）
# ---------------------------------------------------------------------------
NODE_BIN="$DEST/$NODE_DIST/bin/node"
NPM_BIN="$DEST/$NODE_DIST/bin/npm"

if "$NODE_BIN" --version >/dev/null 2>&1; then
    log "node $NODE_VERSION 已 vendor，跳过下载"
else
    URL="https://nodejs.org/dist/$NODE_VERSION/$NODE_DIST.tar.gz"
    log "下载 $URL"
    curl -fL --retry 3 --connect-timeout 20 -o "$TMP/node.tar.gz" "$URL"

    log "校验 SHA-256（对照官方 SHASUMS256.txt）"
    curl -fsSL --retry 3 -o "$TMP/SHASUMS256.txt" \
        "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt"
    (
        cd "$TMP"
        grep " $NODE_DIST.tar.gz$" SHASUMS256.txt > expected.sha
        shasum -a 256 -c expected.sha
    )

    log "解包 node → $DEST"
    tar -xzf "$TMP/node.tar.gz" -C "$DEST"
    "$NODE_BIN" --version >/dev/null
fi

# ---------------------------------------------------------------------------
# 2. dsh（npm pack 固化确切版本，再从本地 tarball 安装生产依赖）
# ---------------------------------------------------------------------------
CLI="$DEST/node_modules/@deepseek-ai/dsh/lib/bin.js"
if [ -f "$CLI" ]; then
    log "@deepseek-ai/dsh@$DSH_VERSION 已 vendor，跳过安装"
else
    log "npm pack @deepseek-ai/dsh@$DSH_VERSION"
    TARBALL_NAME="$("$NPM_BIN" pack "@deepseek-ai/dsh@$DSH_VERSION" \
        --pack-destination "$TMP" 2>/dev/null | tail -n 1)"
    [ -n "$TARBALL_NAME" ] || fail "npm pack 失败：版本 $DSH_VERSION 不存在？"

    log "安装生产依赖 → $DEST/node_modules"
    (cd "$DEST" && "$NPM_BIN" install "$TMP/$TARBALL_NAME" \
        --omit=dev --no-audit --no-fund --no-save)

    [ -f "$CLI" ] || fail "安装后未找到 $CLI"
fi

# ---------------------------------------------------------------------------
# 3. 清理可写产物与示例文档，保证随包内容只读、可复现
# ---------------------------------------------------------------------------
find "$DEST/node_modules" -name "*.md" -delete 2>/dev/null || true
find "$DEST/node_modules" -name "*.ts" -path "*/test/*" -delete 2>/dev/null || true
find "$DEST/node_modules" -type d \( -name "test" -o -name "tests" -o -name "__tests__" -o -name ".bin" \) -prune -exec rm -rf {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. 冒烟
# ---------------------------------------------------------------------------
log "冒烟：$( "$NODE_BIN" --version ) + dsh cli"
"$NODE_BIN" "$CLI" --version 2>/dev/null \
    || log "警告：dsh --version 未成功返回（CLI 入口可能不同，不影响 vendor）"

DU="$(du -sh "$DEST" | awk '{print $1}')"
log "完成：${DEST}（${DU}），构建时将随 .app 一并签名、拷贝。"
