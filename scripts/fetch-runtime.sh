#!/usr/bin/env bash
#
# fetch-runtime.sh —— 为 CogniTerm 拉取并安装 Sidecar runtime（同包同版本）：
#   1. 官方 node darwin-arm64 预编译包（SHA-256 校验，对照 nodejs.org SHASUMS256.txt）
#   2. npm pack @deepseek-ai/dsh@0.2.0-rc.2 → 本地安装（仅生产依赖）
#   3. 安装 ACP profile 补丁（sandbox-policy / 关闭遥测，带 .bak 回滚）
#
# 安装后布局（SidecarService 按此查找）：
#   $DEST/node-darwin-arm64/bin/node
#   $DEST/node_modules/@deepseek-ai/dsh/lib/bin.js
#
# 可通过环境变量覆盖：DSH_RUNTIME_DIR、DSH_HOME、DSH_VERSION、NODE_VERSION
set -euo pipefail

DSH_VERSION="${DSH_VERSION:-0.2.0-rc.2}"
NODE_VERSION="${NODE_VERSION:-v24.20.0}"
NODE_DIST="node-${NODE_VERSION}-darwin-arm64"

APP_SUPPORT="$HOME/Library/Application Support/CogniTerm"
DEST="${DSH_RUNTIME_DIR:-$APP_SUPPORT/runtime}"
DSH_HOME="${DSH_HOME:-$APP_SUPPORT/dsh-home}"
PATCHES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/App/Resources/patches"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log()  { printf '\033[1;34m[fetch-runtime]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[fetch-runtime]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "仅支持 macOS"
[ "$(uname -m)" = "arm64" ]  || fail "首版仅提供 darwin-arm64 runtime（$(uname -m)）"
command -v curl >/dev/null || fail "缺少 curl"

mkdir -p "$DEST" "$DSH_HOME/profiles/acp"

# ---------------------------------------------------------------------------
# 1. Node
# ---------------------------------------------------------------------------
NODE_BIN="$DEST/$NODE_DIST/bin/node"
NPM_BIN="$DEST/$NODE_DIST/bin/npm"

if "$NODE_BIN" --version >/dev/null 2>&1; then
    log "node $NODE_VERSION 已存在，跳过下载"
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
    log "@deepseek-ai/dsh@$DSH_VERSION 已存在，跳过安装"
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
# 3. profile 补丁（已存在且内容不同时先备份）
# ---------------------------------------------------------------------------
log "安装 ACP profile 补丁 → $DSH_HOME/profiles/acp"
for p in acp.base.patch.yml no-telemetry.yml; do
    src="$PATCHES_DIR/$p"
    dst="$DSH_HOME/profiles/acp/$p"
    [ -f "$src" ] || fail "缺少打包资源：$src"
    if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
        cp "$dst" "$dst.bak"
        log "已备份旧版 $p → $p.bak"
    fi
    cp "$src" "$dst"
done

# ---------------------------------------------------------------------------
# 4. 冒烟
# ---------------------------------------------------------------------------
log "冒烟：node $(("$NODE_BIN" --version 2>/dev/null) || echo '?') + dsh"
"$NODE_BIN" "$CLI" --version 2>/dev/null || \
    log "警告：dsh --version 未成功返回（CLI 入口可能不同，不影响安装）"

cat <<EOF
$(log "完成")
  node : $NODE_BIN
  dsh  : $CLI
  home : $DSH_HOME
下一步：在 CogniTerm 设置中填入 DEEPSEEK_API_KEY，即可启动真实 Sidecar。
EOF
