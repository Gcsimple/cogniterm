#!/usr/bin/env bash
#
# make-release.sh —— 打一个可直接上传到 GitHub Releases 的分发包。
#
# 用法：
#   scripts/make-release.sh              # Release 构建 + 打包 + 打印校验值
#   scripts/make-release.sh --no-build   # 只打包现有 Release 产物
#
# 与 build-app.sh 的分工：那个脚本是**开发入口**（Debug、装到 /Applications、
# 注册 LaunchServices、校验唯一副本）；这个脚本只负责**产出可分发物**，不碰
# /Applications，也不注册 LS —— 否则开发机上会出现第二份同 bundle id 的副本，
# 正是 build-app.sh 开头那段事故的复现路径。
#
# 产物：
#   dist/CogniTerm-<version>-macos-arm64.zip
#   dist/CogniTerm-<version>-macos-arm64.zip.sha256
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$REPO/.build/xcode-release"
APP="$DERIVED/Build/Products/Release/CogniTerm.app"
LOG="$REPO/.build/xcodebuild-release.log"
DIST="$REPO/dist"
BUNDLE_ID="com.cogniterm.app"

MODE="build"
case "${1:-}" in
  --no-build) MODE="pack" ;;
  "")         MODE="build" ;;
  *) echo "用法: scripts/make-release.sh [--no-build]" >&2; exit 2 ;;
esac

cd "$REPO"

# ── 版本号从工程里读，避免打出来的包和 tag 对不上 ────────────────────────
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$REPO/App/CogniTerm.xcodeproj/project.pbxproj" 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
  VERSION="$(awk -F'= ' '/MARKETING_VERSION = /{gsub(/;/,"",$2); print $2; exit}' \
    "$REPO/App/CogniTerm.xcodeproj/project.pbxproj")"
fi
ZIP="$DIST/CogniTerm-${VERSION}-macos-arm64.zip"

if [ "$MODE" = "build" ]; then
  echo "==> 构建 CogniTerm.app（Release，derivedData=${DERIVED}）"
  mkdir -p "$REPO/.build"
  rm -f "$LOG"
  # 同 build-app.sh：-disable-sandbox 必须走命令行，工程级设置到不了 SPM 包目标，
  # 包里的 SwiftData 宏会死在 swift-plugin-server 的沙箱上。
  if ! xcodebuild -project "$REPO/App/CogniTerm.xcodeproj" -scheme CogniTerm \
      -configuration Release -derivedDataPath "$DERIVED" \
      OTHER_SWIFT_FLAGS="-disable-sandbox" build >"$LOG" 2>&1; then
    echo "!! 构建失败，错误摘要：" >&2
    grep -E "error:" "$LOG" | head -20 >&2
    exit 1
  fi
  if grep -qE "\*\* BUILD FAILED \*\*" "$LOG"; then
    echo "!! xcodebuild 报告 BUILD FAILED（退出码却是 0），摘要：" >&2
    grep -E "error:" "$LOG" | head -20 >&2
    exit 1
  fi
fi

[ -d "$APP" ] || { echo "!! 找不到 Release 产物：$APP" >&2; exit 1; }

# ── 分发前必须自己签一次 ────────────────────────────────────────────────
# 工程里是 CODE_SIGNING_ALLOWED = NO（开发期不需要签名，Xcode 什么都不做），
# 但这样一来 bundle 只有一个链接器给主可执行文件打的 ad-hoc 签名，**没有 seal**：
#   codesign --verify → "code has no resources but signature indicates they must be present"
# 本机不隔离所以能跑；用户从浏览器下载后带 quarantine，会直接报「已损坏」。
# 所以这里对整个 bundle 做一次 ad-hoc 签名（含嵌套的 node 与 dylibs）。
echo "==> 清理扩展属性并做 ad-hoc 签名"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep --strict "$APP" \
  || { echo "!! 签名自检失败：用户装上去会报「已损坏」" >&2; exit 1; }

# ── 分发前的硬校验：缺一样，用户装上去就是一个打不开的壳 ───────────────────
echo "==> 校验产物"
test -f "$APP/Contents/Resources/cogniterm-core.patch.yml" \
  || { echo "!! core patch 没进包：sidecar 会以 dsh 默认 profile 启动，收编整体失效" >&2; exit 1; }
test -x "$APP/Contents/Resources/runtime/node-darwin-arm64/bin/node" \
  || { echo "!! 内置 node 没进包：agent 起不来" >&2; exit 1; }
test -d "$APP/Contents/Resources/runtime/node_modules/@deepseek-ai/dsh" \
  || { echo "!! dsh 运行时没进包" >&2; exit 1; }

GOT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[ "$GOT_ID" = "$BUNDLE_ID" ] || { echo "!! bundle id 是 ${GOT_ID}，期望 ${BUNDLE_ID}" >&2; exit 1; }

GOT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$GOT_VERSION" = "$VERSION" ] \
  || { echo "!! 包内版本 $GOT_VERSION 与工程版本 $VERSION 不一致" >&2; exit 1; }

codesign --verify --deep --strict "$APP" 2>/dev/null \
  || { echo "!! 签名校验失败（ad-hoc 也要能自洽）" >&2; exit 1; }

# ── 打包：ditto 而不是 zip(1)，它保留扩展属性与权限位 ──────────────────────
mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256"
echo "==> 打包 $(basename "$ZIP")"
ditto -c -k --keepParent "$APP" "$ZIP"
( cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

SIZE="$(du -h "$ZIP" | awk '{print $1}')"
SHA="$(awk '{print $1}' "$ZIP.sha256")"

echo
echo "==> 完成"
echo "    版本   : ${VERSION}"
echo "    产物   : ${ZIP}（${SIZE}）"
echo "    sha256 : ${SHA}"
echo "    签名   : $(codesign -dv "$APP" 2>&1 | awk -F'=' '/Signature/{print $2}')（ad-hoc）"
echo
echo "上传（仓库已配好凭据时）："
echo "    gh release create v${VERSION} \"${ZIP}\" --title \"v${VERSION}\""
