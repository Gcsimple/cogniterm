#!/usr/bin/env bash
#
# build-app.sh —— CogniTerm 唯一构建/启动入口。
#
# 用法：
#   scripts/build-app.sh           # 构建 + 硬校验 + 注册到 LaunchServices
#   scripts/build-app.sh --open    # 上面全做，并启动 app
#   scripts/build-app.sh --check   # 不构建，仅校验现有产物是否可用
#
# ── 这个脚本存在的唯一理由 ──────────────────────────────────────────────
# 2026-10-16 的真实事故：明明修好了 -32603（sidecar 继承临时代理 → TRANSPORT
# → 退避重试 5 次 → ACP -32603），用户却依旧每跑必错。根因不是代码，是**产物**：
#
#   .build/xcode2/Build/Products/Debug/CogniTerm.app   ← 09:44，无 core patch、无修复
#   .build/xcode/Build/Products/Debug/CogniTerm.app    ← 14:29，含修复
#
# 两份 app 的 CFBundleIdentifier 都是 com.cogniterm.app，而 LaunchServices 对同一
# bundle id 只认一个「首选」——它压在先落盘的那份（xcode2）上。于是无论从 Finder
# 双击、Spotlight、还是 `open -b com.cogniterm.app` 启动，跑的都是旧代码。
# 更隐蔽的是 xcode2 那份**连 App/Resources/patches/cogniterm-core.patch.yml 都没有**
# （它构建于收编工作之前），启动时会走 SidecarService 的降级分支
# 「未找到 cogniterm-core.patch.yml，以 dsh 默认 profile 启动」——收编整体失效，
# 但 UI 上只在诊断里留一行字，看起来"能跑"，于是被当成"修复无效"。
#
# 结论：**构建产物路径必须唯一，且启动入口必须收敛到唯一一份**。
# 本脚本用五条硬校验保证这一点，任一不过直接 exit 1，宁可不启动也不让你跑旧代码。
#
# 2026-10-16 晚补充：现在有了**正式安装位置** `/Applications/CogniTerm.app`
# （由 scripts/install-app.sh 搬运，见校验 5）。开发产物 `.build/xcode/...` 从此
# 只是中间产物，不再注册进 LaunchServices —— 消除双副本歧义的根本办法就是
# "Finder 只认一份"，而不是"让两份都注册、再指望顺序"。但已安装副本若存在，
# 它必须与本次构建逐位一致，否则用户双击启动的就是旧代码。
#
# ── 依赖的机器级修复（幂等，随脚本自动落实）────────────────────────────
# 同 scripts/run-tests.sh：沙箱环境里 SwiftPM 解析 manifest、Swift 宏插件服务都要
# 关闭 sandbox-exec，否则分别报 sandbox_apply EPERM 与
# "swift-plugin-server produced malformed response"。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$REPO/.build/xcode"
APP="$DERIVED/Build/Products/Debug/CogniTerm.app"
BUNDLE_ID="com.cogniterm.app"
PATCH_IN_BUNDLE="$APP/Contents/Resources/cogniterm-core.patch.yml"
PATCH_SOURCE="$REPO/App/Resources/patches/cogniterm-core.patch.yml"
LOG="$REPO/.build/xcodebuild-build.log"
LSR="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

MODE="build"
case "${1:-}" in
  --open)  MODE="open" ;;
  --check) MODE="check" ;;
  "")      MODE="build" ;;
  *) echo "用法: scripts/build-app.sh [--open|--check]" >&2; exit 2 ;;
esac

cd "$REPO"

# ── 校验 1：全仓不得存在第二份 CogniTerm.app ────────────────────────────
# 同 bundle id 的第二份产物是事故根源，必须在构建前就拦下（构建前拦比构建后拦
# 更早，能避免"白构建一轮"）。
scan_duplicates() {
  local dup
  dup="$(find "$REPO" -maxdepth 6 -name "CogniTerm.app" -not -path "$APP" 2>/dev/null || true)"
  if [ -n "$dup" ]; then
    echo "!! 仓库内存在第二份 CogniTerm.app（与唯一产物同 bundle id，会抢 LaunchServices 解析）：" >&2
    echo "$dup" | sed 's/^/     /' >&2
    echo "   请删除后重跑。本仓库只允许 $APP 这一份产物。" >&2
    exit 1
  fi
}
scan_duplicates

# ── 构建 ────────────────────────────────────────────────────────────────
if [ "$MODE" != "check" ]; then
  if [ "$(defaults read com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox 2>/dev/null || echo 0)" != "1" ]; then
    echo "==> 写入 Xcode 默认项：关闭 manifest 沙箱（沙箱内解析包依赖必需）"
    defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
  fi

  mkdir -p "$REPO/.build"
  rm -f "$LOG"
  # ⚠️ 变量必须写成 ${VAR}：全角括号是多字节字符，bash 在部分 locale 下会把它
  #    当标识符继续吃进变量名，报 "DERIVED）: unbound variable"。
  echo "==> 构建 CogniTerm.app（Debug，derivedData=${DERIVED}）"
  # OTHER_SWIFT_FLAGS 必须走命令行且整体显式带 -disable-sandbox：工程级设置到不了
  # SPM 包目标，包里的 SwiftData 宏（@Model）会死在 swift-plugin-server 沙箱上。
  if ! xcodebuild -project "$REPO/App/CogniTerm.xcodeproj" -scheme CogniTerm \
      -configuration Debug -derivedDataPath "$DERIVED" \
      OTHER_SWIFT_FLAGS="-disable-sandbox" build >"$LOG" 2>&1; then
    echo "!! 构建失败，错误摘要：" >&2
    grep -E "error:" "$LOG" | head -20 >&2
    exit 1
  fi
  if grep -qE "\*\* BUILD FAILED \*\*" "$LOG"; then
    echo "!! xcodebuild 报告 BUILD FAILED，尽管退出码为 0，摘要：" >&2
    grep -E "error:" "$LOG" | head -20 >&2
    exit 1
  fi
else
  echo "==> --check：跳过构建，仅校验现有产物"
fi

# ── 校验 2：产物存在且可执行 ────────────────────────────────────────────
if [ ! -d "$APP" ]; then
  echo "!! 未找到产物：$APP" >&2
  exit 1
fi
for bin in "$APP/Contents/MacOS/CogniTerm" "$APP/Contents/MacOS/CogniTerm.debug.dylib"; do
  if [ ! -f "$bin" ]; then
    echo "!! 产物不完整，缺少：$bin" >&2
    exit 1
  fi
done

# ── 校验 3：产物新鲜度（防"用旧 bundle 冒充新构建"）────────────────────
# 不变量是「产物必须比它的**所有输入**新」——不是「比这次构建的开始时刻新」。
# 后者是错的：增量构建时 xcodebuild 可能一个文件都不重链接（什么都没改），
# 产物自然早于本次调用，却完全正确。实测就这么误报过一次。
# 前者的判据还更准：编译失败时那个改过的源文件必然比旧产物新，一样拦得住
# （run-tests.sh 要防的正是这个：编译错误被放过 → 拿旧 bundle 跑出绿结果）。
#
# 2026-10-17 收窄输入集：只算**真正喂 dylib 的源文件**（*.swift / *.h / *.c）。
# 旧集把 *.yml / *.sb / *.plist / *.pbxproj 也算进去——这些是 bundle 资源或
# 工程描述，根本不进二进制，于是「只加一个资源文件」（如 sidecar-writable.sb）
# 时 pbxproj 比 dylib 新 → 整个校验误报 exit 1，而构建其实完全成功。
# 资源的新鲜度由校验 4 / 4b / 4c 的 cmp（bundle 内文件 vs 源文件）把关，
# 不比 dylib mtime 弱——cmp 是内容级判据，比时间戳更准。
if [ "$MODE" != "check" ]; then
  DYLIB="$APP/Contents/MacOS/CogniTerm.debug.dylib"
  STALE_INPUT="$(find "$REPO/App" "$REPO/Packages" -type f \
      \( -name '*.swift' -o -name '*.h' -o -name '*.c' \) \
      -not -path "*/.build/*" -not -path "*/Resources/runtime/*" \
      -newer "$DYLIB" -print -quit 2>/dev/null || true)"
  if [ -n "$STALE_INPUT" ]; then
    echo "!! 产物比输入旧（陈旧产物），拒绝注册/启动：$APP" >&2
    echo "   dylib mtime : $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$DYLIB")" >&2
    echo "   更新的输入  : $STALE_INPUT" >&2
    exit 1
  fi
fi

# ── 校验 4：core patch 真的进了 bundle，且内容与源文件一致 ──────────────
# 这是最容易被漏掉、后果最重的一条：xcode2 事故就是"app 能启动但收编 patch 缺失"。
# 只检查"有没有"不够，还必须查关键锚点——approval.policy 丢 !!js 前缀会让
# approval 插件激活失败，dump 看不出来，只有真启动才报 "N entries did not activate"。
if [ ! -f "$PATCH_IN_BUNDLE" ]; then
  echo "!! bundle 内缺少 cogniterm-core.patch.yml：$PATCH_IN_BUNDLE" >&2
  echo "   这会让 sidecar 以 dsh 默认 profile 启动，收编策略（审批/沙箱/模型绑定）整体失效。" >&2
  echo "   检查 App/Resources/patches/ 是否被加进了 Xcode 工程的 Resources 构建阶段。" >&2
  exit 1
fi
if ! cmp -s "$PATCH_SOURCE" "$PATCH_IN_BUNDLE"; then
  echo "!! bundle 内 patch 与源文件不一致（构建未把最新 patch 拷进去）：" >&2
  diff "$PATCH_SOURCE" "$PATCH_IN_BUNDLE" | head -20 >&2
  exit 1
fi
require_anchor() {
  if ! grep -qF -- "$1" "$PATCH_IN_BUNDLE"; then
    echo "!! bundle 内 patch 缺少关键锚点：$1" >&2
    echo "   （${2}）" >&2
    exit 1
  fi
}
require_anchor "policy: !!js >-"                       "approval.policy 必须带 !!js 前缀 + 折叠标量，否则表达式被当字面量、插件激活失败"
require_anchor "provider: deepseek-official"           "provider 必须固定为 runtime 里唯一存在的 provider"

# ── 校验 4b：sidecar.sb 进 bundle、与源一致、且放行 app bundle 自身 ──────
# 2026-10-16 装到 /Applications 后踩到的最贵一次：sb 的只读放行里只有
# (subpath (param "RUNTIME_DIR"))，而 dsh 的 `--patch` 文件位于 Contents/Resources
# **根**，不在 runtime/ 之下。开发期 app 落在 $HOME 内，会被 HOME 读放行顺带覆盖，
# 所以这个洞只在"装到 /Applications"后才暴露 —— 表现为 sidecar 反复崩溃，
# 而 App 侧只有一句"连续崩溃"，根本看不出是沙箱路径问题。
SB_IN_BUNDLE="$APP/Contents/Resources/sidecar.sb"
SB_SOURCE="$REPO/App/Resources/sandbox/sidecar.sb"
if [ ! -f "$SB_IN_BUNDLE" ]; then
  echo "!! bundle 内缺少 sidecar.sb：$SB_IN_BUNDLE" >&2
  echo "   SidecarService 会 fail-closed 拒绝在无外层沙箱的情况下启动 sidecar。" >&2
  exit 1
fi
if ! cmp -s "$SB_SOURCE" "$SB_IN_BUNDLE"; then
  echo "!! bundle 内 sidecar.sb 与源文件不一致（构建未把最新 sb 拷进去）：" >&2
  diff "$SB_SOURCE" "$SB_IN_BUNDLE" | head -20 >&2
  exit 1
fi
if ! grep -qF '(subpath (param "APP_BUNDLE"))' "$SB_IN_BUNDLE"; then
  echo '!! sidecar.sb 没有放行 app bundle 自身（(subpath (param "APP_BUNDLE"))）' >&2
  echo "   后果：装到 /Applications 后沙箱内的 dsh 读不到 --patch，sidecar 启动即失败。" >&2
  exit 1
fi

# ── 校验 4c：sidecar-writable.sb（workspace-write / 关闭档的外层墙）────────
# 2026-10-17 双档墙。writable 档是「内层 escalation 审批能落地」的前提：
# dsh 批准写工作区外路径后，外层静态单根墙再 EPERM 的话用户点「允许」毫无意义
# （实证：5 个会话 4 次手动中止，全败在 glob 扫 $HOME + 静态墙）。
# 判据：①进 bundle 且与源一致 ②放行 app bundle ③放开 HOME 写 ④凭据墙五条 deny 在。
SBW_IN_BUNDLE="$APP/Contents/Resources/sidecar-writable.sb"
SBW_SOURCE="$REPO/App/Resources/sandbox/sidecar-writable.sb"
if [ ! -f "$SBW_IN_BUNDLE" ]; then
  echo "!! bundle 内缺少 sidecar-writable.sb：$SBW_IN_BUNDLE" >&2
  echo "   workspace-write / 关闭档会 fail-closed 拒绝启动（profile 缺失）。" >&2
  exit 1
fi
if ! cmp -s "$SBW_SOURCE" "$SBW_IN_BUNDLE"; then
  echo "!! bundle 内 sidecar-writable.sb 与源文件不一致（构建未把最新 sb 拷进去）：" >&2
  diff "$SBW_SOURCE" "$SBW_IN_BUNDLE" | head -20 >&2
  exit 1
fi
if ! grep -qF '(subpath (param "APP_BUNDLE"))' "$SBW_IN_BUNDLE"; then
  echo '!! sidecar-writable.sb 没有放行 app bundle 自身' >&2
  exit 1
fi
if ! grep -qF '(subpath (param "HOME_DIR")))' "$SBW_IN_BUNDLE" \
   || ! grep -qE '^\(allow file-write\* file-ioctl$' "$SBW_IN_BUNDLE"; then
  echo '!! sidecar-writable.sb 缺少 HOME 写放行（(allow file-write* file-ioctl (subpath (param "HOME_DIR")))）' >&2
  echo "   后果：dsh 内层 escalation 审批通过的越界写仍被外层 EPERM（审批赢了墙没赢）。" >&2
  exit 1
fi
for anchor in HOME_SSH HOME_GNUPG HOME_KEYCHAINS AWS_CREDS NETRC; do
  if ! grep -qF "(param \"$anchor\")" "$SBW_IN_BUNDLE"; then
    echo "!! sidecar-writable.sb 的凭据墙缺少 $anchor：放开 HOME 写时凭据必须仍然 deny" >&2
    exit 1
  fi
done

# 模型绑定必须**恰好两处**：agent-default-model（别的入口的缺省值）+ acp（真控制点）。
# 只绑前者是空操作——dsh-acp 不消费 agentDefaultModel，会话模型由 acp 行的
# provider/model 决定（2026-10-16 实证：27 个会话日志里 request/header 的 model
# 恒为 acp 出货值，与设置页注入值不一致）。少一处就用不了选择器。
BIND_COUNT=$(grep -cF "!!js process.env.DSH_COGNITERM_MODEL" "$PATCH_IN_BUNDLE" || true)
if [ "$BIND_COUNT" -ne 2 ]; then
  echo "!! bundle 内 patch 的 DSH_COGNITERM_MODEL 绑定应为 2 处（agent-default-model + acp），实为 $BIND_COUNT" >&2
  echo "   只绑 agent-default-model 时设置页的模型选择器是空操作。" >&2
  exit 1
fi
# acp 行的 config 是整体替换而非深合并（实测：只写 model 时 provider 消失），
# 所以覆盖 acp 必须同时写回 provider。
# ⚠️ 模式用 -E "^- id: acp$" 而不是 -F "- id: acp"：后者以 `-` 开头会被 grep
#    当成选项（实测报 invalid option），且会误匹配 `- id: acp-app-startup`。
if ! grep -A4 -E "^\- id: acp$" "$PATCH_IN_BUNDLE" | grep -qF "provider: deepseek-official"; then
  echo "!! patch 覆盖 acp 行时丢失了 provider（整体替换语义），会话将无法解析路由" >&2
  exit 1
fi

# ── 校验 5：LaunchServices 与「已安装副本」──────────────────────────────
# 2026-10-16 晚修订。原语义是「LS 里只能有本份开发产物」——那是还没有正式安装
# 位置时的权宜之计，副作用是开发产物被注册进 Launchpad / Spotlight，
# 而这正是双副本事故的成因之一（两份 com.cogniterm.app 同时被注册时，
# LS 只认先落盘的，于是"修好了还是跑旧代码"）。
#
# 现在的语义：
#   - 开发产物 $APP 是中间产物，安装了正式副本之后就从 LS 注销；
#   - 已安装副本 $INSTALLED 若存在，**必须与本份产物逐位一致**，否则用户从
#     Finder 双击启动的就是旧代码 —— 这正是本脚本存在的全部理由，
#     不能因为"它装在别处"就放过；
#   - 除这两者之外的任何 CogniTerm.app 副本一律拒绝。
#
# 已安装副本过期时的处理分两种：`--check` 直接失败（跑 --check 就是要拿它启动），
# 普通构建只警告（标准流程是构建完紧接着跑 install-app.sh 覆盖它）。
INSTALLED="/Applications/CogniTerm.app"

if [ -d "$INSTALLED" ]; then
  INS_DYLIB="$INSTALLED/Contents/MacOS/CogniTerm.debug.dylib"
  DEV_DYLIB="$APP/Contents/MacOS/CogniTerm.debug.dylib"
  INS_STALE=""
  if [ ! -f "$INS_DYLIB" ]; then
    INS_STALE="已安装副本不完整（缺 CogniTerm.debug.dylib）"
  elif [ "$(shasum -a 256 "$DEV_DYLIB" | cut -d' ' -f1)" != "$(shasum -a 256 "$INS_DYLIB" | cut -d' ' -f1)" ]; then
    INS_STALE="已安装副本是旧代码（dylib 与本次构建不一致）"
  elif ! cmp -s "$PATCH_IN_BUNDLE" "$INSTALLED/Contents/Resources/cogniterm-core.patch.yml"; then
    INS_STALE="已安装副本内的 core patch 与本份不一致"
  fi
  if [ -n "$INS_STALE" ]; then
    if [ "$MODE" = "check" ]; then
      echo "!! $INS_STALE" >&2
      echo "   用户双击启动的正是 ${INSTALLED}，跑 --check 就是要拿它用，必须重装：" >&2
      echo "     scripts/install-app.sh --no-build" >&2
      exit 1
    fi
    echo "⚠️  $INS_STALE" >&2
    echo "   本次构建后请重装一次：scripts/install-app.sh --no-build" >&2
  fi
  # Finder / Launchpad 只认已安装副本
  "$LSR" -u "$APP" 2>/dev/null || true
  "$LSR" -f "$INSTALLED" 2>/dev/null || true
else
  # 尚未安装到 /Applications：开发产物就是唯一入口
  "$LSR" -f "$APP" 2>/dev/null || true
fi

LS_HITS="$("$LSR" -dump 2>/dev/null \
  | grep "path:.*CogniTerm\.app" \
  | grep -v "LibreOfficeDev" \
  | sed 's/^ *path: *//; s/ (0x[0-9a-f]*)$//' || true)"
LS_OTHER="$(printf '%s\n' "$LS_HITS" \
  | grep -v "^$APP$" \
  | grep -v "^$INSTALLED$" \
  | grep -v '^$' || true)"
if [ -n "$LS_OTHER" ]; then
  echo "!! LaunchServices 里还注册着别的 CogniTerm.app 副本（会抢解析）：" >&2
  echo "$LS_OTHER" | sed 's/^/     /' >&2
  echo "   逐条注销：$LSR -u <path>" >&2
  exit 1
fi

echo "==> 产物校验全部通过"
echo "    app        : $APP"
echo "    bundle id  : $BUNDLE_ID"
echo "    构建时间   : $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$APP/Contents/MacOS/CogniTerm.debug.dylib")"
if [ -d "$INSTALLED" ]; then
  if [ -n "${INS_STALE:-}" ]; then
    echo "    已安装副本 : ${INSTALLED}（⚠️ 已过期，见上方提示）"
  else
    echo "    已安装副本 : ${INSTALLED}（与本份一致，LS 首选）"
  fi
else
  echo "    LS 注册    : 仅本份开发产物（尚未安装到 /Applications）"
fi

if [ "$MODE" = "open" ]; then
  echo "==> 启动 app"
  open "$APP"
fi
