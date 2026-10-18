#!/bin/bash
# CogniTerm sidecar 沙箱网络探针
# 复现 SidecarService 注入的 sandbox-exec 命令行，用 curl 做一次 HTTPS 请求，
# 把 curl 的原始 stderr / 退出码 / HTTP 码全部落盘，用来判定 TRANSPORT 的真因。
#
# 用法：ctprobe.sh [输出文件]
# 判定：无沙箱应得 HTTP 401（请求到得了服务端，只是没带 key）；
#       有沙箱若拿到别的结果（非 401），差异部分就是沙箱造成的。

OUT="${1:-/tmp/ctprobe.out}"
APP="/Applications/CogniTerm.app"
SB="$APP/Contents/Resources/sidecar.sb"
RUNTIME="$APP/Contents/Resources/runtime"
HOME_DIR="$HOME"
URL="https://api.deepseek.com/v1/models"

exec > "$OUT" 2>&1

echo "=== CogniTerm sidecar 沙箱网络探针 ==="
echo "时间      : $(date '+%F %T')"
echo "app       : $APP"
echo "profile   : $SB"
echo "url       : $URL"
echo "shell pid : $$"
echo

if [ ! -f "$SB" ]; then
  echo "!! 找不到 sandbox profile：$SB"
  echo "EXIT=90"
  exit 90
fi

# ---------------------------------------------------------------- 基线（无沙箱）
echo "--- [基线] 无沙箱 curl --------------------------------"
BASE_ERR="$(/usr/bin/curl -sS -m 15 -o /dev/null -w '%{http_code}' "$URL" 2>&1)"
BASE_RC=$?
echo "http_code : $BASE_ERR"
echo "exit_code : $BASE_RC"
echo

# ---------------------------------------------------------------- 沙箱内
echo "--- [沙箱] 同 profile + 同 -D 注入 ---------------------"
SBX_OUT="$(
  /usr/bin/sandbox-exec -f "$SB" \
    -D "WORKSPACE_ROOT=$HOME_DIR" \
    -D "HOME_DIR=$HOME_DIR" \
    -D "HOME_SSH=$HOME_DIR/.ssh" \
    -D "HOME_GNUPG=$HOME_DIR/.gnupg" \
    -D "HOME_KEYCHAINS=$HOME_DIR/Library/Keychains" \
    -D "AWS_CREDS=$HOME_DIR/.aws/credentials" \
    -D "NETRC=$HOME_DIR/.netrc" \
    -D "NPM_CACHE_DIR=$HOME_DIR/.npm" \
    -D "USER_CACHE_DIR=$HOME_DIR/.cache" \
    -D "USER_LOGS_DIR=$HOME_DIR/Library/Logs" \
    -D "APP_SUPPORT_COGNITERM=$HOME_DIR/Library/Application Support/CogniTerm" \
    -D "RUNTIME_DIR=$RUNTIME" \
    -D "APP_BUNDLE=$APP" \
    /usr/bin/curl -sS -m 15 -o /dev/null -w '%{http_code}' "$URL" 2>&1
)"
SBX_RC=$?
echo "http_code : $SBX_OUT"
echo "exit_code : $SBX_RC"
echo

# ---------------------------------------------------------------- 分项定位
echo "--- [分项] 沙箱内逐步定位 -----------------------------"
run_in_sandbox() {
  /usr/bin/sandbox-exec -f "$SB" \
    -D "WORKSPACE_ROOT=$HOME_DIR" -D "HOME_DIR=$HOME_DIR" \
    -D "HOME_SSH=$HOME_DIR/.ssh" -D "HOME_GNUPG=$HOME_DIR/.gnupg" \
    -D "HOME_KEYCHAINS=$HOME_DIR/Library/Keychains" \
    -D "AWS_CREDS=$HOME_DIR/.aws/credentials" -D "NETRC=$HOME_DIR/.netrc" \
    -D "NPM_CACHE_DIR=$HOME_DIR/.npm" -D "USER_CACHE_DIR=$HOME_DIR/.cache" \
    -D "USER_LOGS_DIR=$HOME_DIR/Library/Logs" \
    -D "APP_SUPPORT_COGNITERM=$HOME_DIR/Library/Application Support/CogniTerm" \
    -D "RUNTIME_DIR=$RUNTIME" -D "APP_BUNDLE=$APP" \
    "$@" 2>&1
}
echo "[1] DNS 解析 (dscacheutil):"
run_in_sandbox /usr/bin/dscacheutil -q host -a name api.deepseek.com | /usr/bin/head -6
echo "    exit=$?"
echo
echo "[2] TCP 连通 (nc -z 443):"
run_in_sandbox /usr/bin/nc -z -G 5 api.deepseek.com 443; echo "    exit=$?"
echo
echo "[3] 纯 IP 直连 (curl --resolve 用 1.1.1.1 跳过 DNS 不适用; 用 -k 跳过证书):"
run_in_sandbox /usr/bin/curl -sS -k -m 15 -o /dev/null -w '%{http_code}' "$URL"; echo "    exit=$?"
echo
echo "[4] 看 dsh 自带 node 在沙箱内能否 require('dns') 解析:"
run_in_sandbox "$RUNTIME/node-darwin-arm64/bin/node" -e '
  const dns=require("dns");
  dns.lookup("api.deepseek.com",(e,a)=>{ console.log("lookup:", e ? (e.code+": "+e.message) : a); process.exit(0) });
' ; echo "    exit=$?"
echo
echo "[5] 沙箱内 fetch 一次（走 undici，与 dsh 同一条路）:"
run_in_sandbox "$RUNTIME/node-darwin-arm64/bin/node" -e '
  fetch("https://api.deepseek.com/v1/models").then(r=>{console.log("status:",r.status);process.exit(0)})
    .catch(e=>{ console.log("error:", e.constructor.name, e.message);
                let c=e.cause, i=0; while(c && i<5){ console.log("  cause"+(i++)+":", c.constructor?.name, c.code||"", c.message||c); c=c.cause }
                process.exit(0) });
' ; echo "    exit=$?"
echo
echo "=== 探针结束 ==="
