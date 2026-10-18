#!/usr/bin/env bash
#
# install-app.sh —— 把当前构建产物安装到 /Applications（用户的正式启动入口）。
#
# 用法：
#   scripts/install-app.sh              # 构建 + 硬校验 + 安装 + 注册
#   scripts/install-app.sh --no-build   # 跳过构建，用现有产物直接装（刚跑过 build 时用）
#
# ── 为什么不并进 build-app.sh ───────────────────────────────────────────
# 「构建」高频、「安装」低频，而且两者对 LaunchServices 的期望相反：
#   - 开发产物 .build/xcode/... 是中间产物，**不该**出现在 Launchpad / Spotlight；
#   - 已安装副本才是用户双击的入口，必须是 LS 里唯一的 CogniTerm.app。
# 2026-10-16 的双副本事故（两份 com.cogniterm.app 同时被注册，LS 只认先落盘的
# 那份，于是"修好了但还是跑旧代码"）正是"两份都注册"的后果。所以：
#   build-app.sh 负责构建 + 校验（并在 --check 下断言已安装副本未过期）；
#   本脚本负责搬运 + 注册，且**只把已安装副本注册进 LS**。
#
# ── 本机环境约束（必须前台执行 + dangerouslyDisableSandbox）─────────────
# /Applications 在工作区外，沙箱里写不进去（ditto 会莫名失败）。
# /Applications 属主 root:admin 且组可写，本机用户在 admin 组 → **不需要 sudo**。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$REPO/.build/xcode"
APP="$DERIVED/Build/Products/Debug/CogniTerm.app"
INSTALLED="/Applications/CogniTerm.app"
PATCH_REL="Contents/Resources/cogniterm-core.patch.yml"
PATCH_SOURCE="$REPO/App/Resources/patches/cogniterm-core.patch.yml"
LSR="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

DO_BUILD=1
case "${1:-}" in
  "")           ;;
  --no-build)   DO_BUILD=0 ;;
  *) echo "用法: scripts/install-app.sh [--no-build]" >&2; exit 2 ;;
esac

cd "$REPO"

# ── [1/6] 构建 + 硬校验 ─────────────────────────────────────────────────
# 注意这里**不能用 `build-app.sh --check`**：--check 会断言"已安装副本与本份
# 一致"，而本脚本的常规流程恰恰是「先构建出更新的产物、再覆盖旧安装」，
# 那个断言在覆盖之前必然为假。--no-build 分支自己做最小校验。
if [ "$DO_BUILD" = "1" ]; then
  echo "==> [1/6] 构建并硬校验（scripts/build-app.sh）"
  "$REPO/scripts/build-app.sh"
else
  echo "==> [1/6] --no-build：跳过构建，最小校验现有产物"
  [ -d "$APP" ] || { echo "!! 未找到产物：${APP}（先跑 scripts/build-app.sh）" >&2; exit 1; }
  [ -f "$APP/Contents/MacOS/CogniTerm.debug.dylib" ] || { echo "!! 产物不完整（缺 dylib）" >&2; exit 1; }
  [ -f "$APP/$PATCH_REL" ] || { echo "!! 产物内缺 core patch，拒绝安装（收编会整体失效）" >&2; exit 1; }
  cmp -s "$PATCH_SOURCE" "$APP/$PATCH_REL" || { echo "!! 产物内 core patch 与源文件不一致，先重新构建" >&2; exit 1; }
  echo "    产物完整、core patch 与源文件一致"
fi

# ── [2/6] 旧副本移入废纸篓（可逆，不用 rm）─────────────────────────────
if [ -e "$INSTALLED" ]; then
  STAMP="$(date '+%Y%m%d-%H%M%S')"
  TRASH="$HOME/.Trash/CogniTerm.app.$STAMP"
  echo "==> [2/6] 旧副本移入废纸篓：$TRASH"
  mv "$INSTALLED" "$TRASH"
else
  echo "==> [2/6] /Applications 下无旧副本"
fi

# ── [3/6] 拷贝到 /Applications ──────────────────────────────────────────
echo "==> [3/6] 拷贝到 ${INSTALLED}（$(du -sh "$APP" | cut -f1)）"
ditto "$APP" "$INSTALLED"

# ── [4/6] 清掉文件层留下的 .BC.* 临时副本 ───────────────────────────────
# 本机 brokered 文件层在做 copy 时会在目标留下 .BC.T_* / .BC.D_*，**内容是原文件
# 的完整拷贝**：不清的话 bundle 虚胖（实测 431M → 861M）且破坏签名封条，
# 表现为 codesign 报 sealed resource missing、二进制被静默杀掉（零输出）。
BC_COUNT="$(find "$INSTALLED" -name '.BC.*' | wc -l | tr -d ' ')"
if [ "$BC_COUNT" != "0" ]; then
  echo "==> [4/6] 清除 $BC_COUNT 个 .BC.* 临时副本"
  find "$INSTALLED" -name '.BC.*' -delete
else
  echo "==> [4/6] 无 .BC.* 临时副本"
fi
SRC_N="$(find "$APP" | wc -l | tr -d ' ')"
DST_N="$(find "$INSTALLED" | wc -l | tr -d ' ')"
if [ "$SRC_N" != "$DST_N" ]; then
  echo "!! 拷贝不完整：源 $SRC_N 项 / 目标 $DST_N 项" >&2
  exit 1
fi
echo "    文件项数一致：$DST_N"

# ── [5/6] 三重校验 ──────────────────────────────────────────────────────
echo "==> [5/6] 校验安装结果"
xattr -dr com.apple.quarantine "$INSTALLED" 2>/dev/null || true
# 5a. 代码本体必须是同一份：比对 dylib 的 sha256（比 mtime / 体积可靠得多）
DEV_SUM="$(shasum -a 256 "$APP/Contents/MacOS/CogniTerm.debug.dylib" | cut -d' ' -f1)"
INS_SUM="$(shasum -a 256 "$INSTALLED/Contents/MacOS/CogniTerm.debug.dylib" | cut -d' ' -f1)"
if [ "$DEV_SUM" != "$INS_SUM" ]; then
  echo "!! 安装副本与本份代码不一致（dylib sha256 不同）：$APP -> $INSTALLED" >&2
  exit 1
fi
# 5b. core patch 必须字节一致 —— 丢失它是**静默降级**（收编整体失效但 UI 照常能跑）
if ! cmp -s "$APP/$PATCH_REL" "$INSTALLED/$PATCH_REL"; then
  echo "!! 安装副本内 core patch 与本份不一致" >&2
  exit 1
fi
# 5c. 签名可读。本产物是 linker-signed / adhoc（Sealed Resources=none），
#     本地拷贝不带 quarantine 属性 → Gatekeeper 不拦，spctl 会 reject 属预期。
if ! codesign -dv "$INSTALLED" >/dev/null 2>&1; then
  echo "!! 签名无法读取（安装后二进制可能被静默杀掉）" >&2
  exit 1
fi
echo "    dylib sha256 : ${INS_SUM:0:16}…（与本份一致）"
echo "    core patch   : 字节一致"
echo "    签名         : $(codesign -dv "$INSTALLED" 2>&1 | grep -E '^Signature=' || echo 'adhoc')"

# ── [6/6] 注册 LaunchServices：只认已安装副本 ───────────────────────────
echo "==> [6/6] 注册 LaunchServices"
# 开发产物是中间产物，从 LS 注销（这才是消除了双副本歧义的那一步）
"$LSR" -u "$APP" 2>/dev/null || true
# 再清掉**其他任何**已注册副本：主要是 [2/6] 刚移进废纸篓的那份（移文件不会注销
# LS 记录），也含早期在 /private/tmp 试构建留下的死路径。同 bundle id 多注册时
# LS 只取一个"首选"（可能压在先落盘的旧那份上）→ 从 Finder 启动跑的是旧代码。
#
# ⚠️ 必须按**路径结尾**匹配，不能写 `grep CogniTerm\.app`：bundle 内的
#    `…/CogniTerm.app/Contents/Resources/runtime/node_modules/@deepseek-ai/
#     libreoffice-kit-darwin-arm64/program/LibreOfficeDev.app` 也含这个子串，
#    会把这个无关的外来 app 一起注销掉。
while IFS= read -r other; do
  [ -n "$other" ] || continue
  case "$other" in
    "$APP" | "$INSTALLED") continue ;;
  esac
  echo "    注销其他副本：$other"
  "$LSR" -u "$other" 2>/dev/null || true
done <<< "$("$LSR" -dump 2>/dev/null \
            | sed -n 's/^ *path: *\(.*\) (0x[0-9a-f]*)$/\1/p' \
            | grep -E '/CogniTerm\.app$' || true)"
# 最后注册已安装副本：LS 对同 bundle id 取「最近注册」的那份作为首选
"$LSR" -f "$INSTALLED" 2>/dev/null || true

echo
echo "==> 安装完成"
echo "    $INSTALLED"
echo "    bundle id : com.cogniterm.app"
echo "    启动      : Launchpad / Spotlight 搜 “CogniTerm”，或 open -b com.cogniterm.app"
