#!/bin/bash
# sidecar.sb 真实沙箱端口级自检
#
# 为什么需要它（2026-10-16 踩坑后新增）：
#   - `scripts/dump-profile.sh` 验的是 **profile 合成**（yaml 层），验不了 sb；
#   - 本机 bash 工具跑在 WorkBuddy 沙箱内，**任何 restrictive profile 都无法用
#     sandbox-exec 应用**（sandbox_apply: Operation not permitted），所以在这里
#     "手敲一条 sandbox-exec 命令试试"永远得不到真结果；
#   - 但 **LaunchServices 启动的进程不在那个沙箱里**，可以用一个小 .app 当"宿主"，
#     由它去真实应用 seatbelt。本脚本就是这么干的（已在 macOS 27.0.1 实测可用）。
#
# 判据：沙箱内 curl 拿到与无沙箱一致的 HTTP 码（401，没带 key）即通过。
#       若沙箱内变成 curl(6) Could not resolve host / 000，说明 profile 把网络禁了
#       —— 此时 App 的 prompt 必然报 TRANSPORT（dsh 只说这一句，看不出真因）。
#
# 用法：scripts/probe-sandbox-network.sh [profile 路径] [目标 URL]
#       profile 默认取已安装 app 的 sidecar.sb，没有则回落到仓库源文件。
# 退出码：0 通过 / 1 失败 / 2 环境不可用（自检没能跑起来）

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-}"
URL="${2:-https://api.deepseek.com/v1/models}"

if [ -z "$PROFILE" ]; then
  if [ -f /Applications/CogniTerm.app/Contents/Resources/sidecar.sb ]; then
    PROFILE="/Applications/CogniTerm.app/Contents/Resources/sidecar.sb"
  else
    PROFILE="$REPO/App/Resources/sandbox/sidecar.sb"
  fi
fi
PROFILE="$(cd "$(dirname "$PROFILE")" && pwd)/$(basename "$PROFILE")"

if [ ! -f "$PROFILE" ]; then
  echo "!! 找不到 profile：${PROFILE}" >&2
  exit 2
fi

WORK="$(mktemp -d /tmp/ct-sbprobe.XXXXXX)"
OUT="$WORK/result.txt"
HOST="$WORK/CtSbProbe.app"
mkdir -p "$HOST/Contents/MacOS" "$HOST/Contents/Resources"

# ⚠️ 配置**不能**用环境变量传给宿主 app：LaunchServices 派生的进程拿到的是 launchd
#    给的一套干净环境，`VAR=x open app` 传不进去（2026-08-16 实测：marker 能写、
#    而依赖 $CT_* 的写法静默不产出任何文件）。改为写进 bundle 内、宿主用 $0 自定位。
CONF="$HOST/Contents/Resources/probe.conf"
: > "$CONF"
printf 'PROFILE\t%s\n' "$PROFILE" >> "$CONF"
printf 'URL\t%s\n' "$URL" >> "$CONF"
printf 'OUT\t%s\n' "$OUT" >> "$CONF"

# sb 里用到的每个 (param "X") 都要有值，否则 sandbox-exec 报未知参数。
# 用 tab 分隔一行一条，宿主逐行读回数组 —— 不能 printf %q 拼串：值里含空格会散架。
H="$HOME"
{
  echo "WORKSPACE_ROOT=$REPO"
  echo "HOME_DIR=$H"
  echo "HOME_SSH=$H/.ssh"
  echo "HOME_GNUPG=$H/.gnupg"
  echo "HOME_KEYCHAINS=$H/Library/Keychains"
  echo "AWS_CREDS=$H/.aws/credentials"
  echo "NETRC=$H/.netrc"
  echo "NPM_CACHE_DIR=$H/.npm"
  echo "USER_CACHE_DIR=$H/.cache"
  echo "USER_LOGS_DIR=$H/Library/Logs"
  echo "APP_SUPPORT_COGNITERM=$H/Library/Application Support/CogniTerm"
  echo "RUNTIME_DIR=/Applications/CogniTerm.app/Contents/Resources/runtime"
  echo "APP_BUNDLE=/Applications/CogniTerm.app"
} | while IFS= read -r line; do printf 'D\t%s\n' "$line"; done >> "$CONF"

cat > "$HOST/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>CtSbProbe</string>
  <key>CFBundleIdentifier</key><string>local.cogniterm.sbprobe</string>
  <key>CFBundleName</key><string>CtSbProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

# 宿主 app 的可执行体：由 LaunchServices 派生（不在 WorkBuddy 沙箱内），
# 所以它调用的 sandbox-exec 能真正应用 profile。
cat > "$HOST/Contents/MacOS/CtSbProbe" <<'HOSTEOF'
#!/bin/bash
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SELF_DIR/../Resources/probe.conf"

SBARGS=(); CT_PROFILE=""; CT_URL=""; CT_OUT=""
while IFS=$'\t' read -r k v; do
  case "$k" in
    PROFILE) CT_PROFILE="$v" ;;
    URL)     CT_URL="$v" ;;
    OUT)     CT_OUT="$v" ;;
    D)       SBARGS+=("-D" "$v") ;;
  esac
done < "$CONF"

{
  echo "PROFILE|$CT_PROFILE"
  echo "URL|$CT_URL"
  echo "ND|${#SBARGS[@]}"

  base_out="$(/usr/bin/curl -sS -m 15 -o /dev/null -w '%{http_code}' "$CT_URL" 2>&1)"
  echo "BASE_RC|$?"
  echo "BASE|$(printf '%s' "$base_out" | tr '\n' ' ')"

  sbx_out="$(/usr/bin/sandbox-exec -f "$CT_PROFILE" "${SBARGS[@]}" \
             /usr/bin/curl -sS -m 15 -o /dev/null -w '%{http_code}' "$CT_URL" 2>&1)"
  echo "SBX_RC|$?"
  echo "SBX|$(printf '%s' "$sbx_out" | tr '\n' ' ')"
  echo "DONE"
} > "$CT_OUT" 2>&1
HOSTEOF
chmod +x "$HOST/Contents/MacOS/CtSbProbe"

if ! /usr/bin/codesign -s - --force "$HOST" >/dev/null 2>&1; then
  echo "!! 无法给宿主 app 签名（codesign 失败），自检不可用" >&2
  rm -rf "$WORK"; exit 2
fi

/usr/bin/open "$HOST" || { echo "!! 无法启动宿主 app" >&2; rm -rf "$WORK"; exit 2; }

for _ in $(seq 1 40); do
  if [ -f "$OUT" ] && /usr/bin/grep -q '^DONE$' "$OUT" 2>/dev/null; then break; fi
  /bin/sleep 0.5
done

echo "=== sidecar.sb 真实沙箱自检 ==="
echo "profile : $PROFILE"
echo "target  : $URL"
echo

if [ ! -f "$OUT" ]; then
  echo "!! 宿主 app 没有产出结果（自检环境不可用）" >&2
  echo "   宿主目录保留在 ${HOST} 供排查（可自行 open 一次看问题）" >&2
  exit 2
fi

# 取 "KEY|value" 行的 value。不能用 `$1=""; sub()`（会留下前导空格，导致 401 被判成异常）。
field() {
  /usr/bin/awk -v k="$1" '{ if (index($0, k "|") == 1) { print substr($0, length(k) + 2); exit } }' "$OUT"
}
BASE="$(field BASE)"
SBX="$(field SBX)"

echo "无沙箱基线 : ${BASE:-?}"
echo "沙箱内     : ${SBX:-?}"
echo

RC=0
case "$SBX" in
  200|400|401|403|404)
    echo "✅ 通过：沙箱内请求到达了服务端（HTTP ${SBX}，与基线同类）"
    ;;
  *"Could not resolve host"*|*"000"*|*"Couldn't connect"*|*"timed out"*|*"Operation not permitted"*)
    echo "❌ 失败：沙箱把网络挡掉了 —— $(printf '%s' "$SBX" | head -1)"
    echo "   这会让 App 的 prompt 报 TRANSPORT（dsh 只说这一句，看不出真因）。"
    echo "   先查 sidecar.sb 的网络块有没有 (remote ...) 过滤器：本机 macOS 实测，"
    echo "   带过滤器的 network-outbound 一条都不放行，必须写 (allow network-outbound)。"
    RC=1
    ;;
  *)
    echo "❌ 失败：沙箱内结果异常 —— $(printf '%s' "$SBX" | head -1)"
    RC=1
    ;;
esac

rm -rf "$WORK"
exit $RC
