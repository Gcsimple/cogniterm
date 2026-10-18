#!/usr/bin/env bash
#
# run-tests.sh —— CogniTerm 全量测试入口（5 个本地包 + App 目标）。
#
# 用法：scripts/run-tests.sh
#
# 为什么 App 测试不走 `xcodebuild test` 直跑：
#   本仓库的 Agent 开发环境（WorkBuddy 沙箱）里，hosted app 测试跑不通——
#   测试运行器与 app host 之间要建 Mach 连接，沙箱对 mach-register /
#   mach-lookup 一律拒绝（同环境里 `ps` 同样被禁，即是佐证），表现为
#   "The test runner hung before establishing connection"（白等 78 分钟）。
#   且该沙箱连 `dangerouslyDisableSandbox` 与 `launchctl asuser` 都绕不出去
#   （实测 restrictive seatbelt profile 仍被 sandbox_apply EPERM 拒绝）。
#   因此 App 测试改用「编译测试 bundle + xcrun xctest 独立运行」：
#     1. xcodebuild test 只当编译器用（看门狗：测试 bundle 构建完成即停）
#     2. CogniTerm.debug.dylib 挪进测试 bundle（二进制自带 @loader_path rpath）
#     3. xcrun xctest 直接跑 bundle，不需要 app host
#   在无沙箱的常规机器（CI / 本地 Xcode）上 `xcodebuild test` 仍然有效，
#   本脚本产出的测试结果与之一致。
#
# 依赖的机器级修复（幂等，随脚本自动落实）：
#   - com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox：
#     SwiftPM 解析 Package.swift manifest 时会在 sandbox-exec 里编译 manifest，
#     沙箱内必失败（sandbox_apply: Operation not permitted）。
#   - 工程级 OTHER_SWIFT_FLAGS=-disable-sandbox：Swift 宏插件服务
#     （swift-plugin-server）同样跑在 sandbox-exec 里，不开这个所有
#     @State/@Observable 宏都会报 "malformed response"。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$REPO/.build/xcode"
APP="$DERIVED/Build/Products/Debug/CogniTerm.app"
TESTS="$APP/Contents/PlugIns/CogniTermTests.xctest"
LOG="$REPO/.build/xcodebuild-test.log"
cd "$REPO"

# ---- 机器级修复（幂等）--------------------------------------------------
if [ "$(defaults read com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox 2>/dev/null || echo 0)" != "1" ]; then
  echo "==> [0/3] 写入 Xcode 默认项：关闭 manifest 沙箱（沙箱内解析包依赖必需）"
  defaults write com.apple.dt.Xcode IDEPackageSupportDisableManifestSandbox -bool YES
fi

# ---- [1/3] 本地包测试 ---------------------------------------------------
echo "==> [1/3] 包测试（swift test --disable-sandbox）"
for pkg in AcpClient Persistence PolicyEngine SessionLogReader TerminalCore; do
  echo "--- Packages/$pkg"
  if ! (cd "Packages/$pkg" && swift test --disable-sandbox); then
    echo "!! Packages/$pkg 测试失败" >&2
    exit 1
  fi
done

# ---- [2/3] 编译 App 测试 bundle（看门狗）--------------------------------
echo "==> [2/3] 构建 App 测试 bundle（编译完成即停，规避沙箱内 hosted 测试挂起）"
# 上一次挂死的测试会遗留 app host 实例；不清掉的话新启动会把实例移交给它、
# 自己以 0 退出（"Early unexpected exit"），连挂死都装不像。
killall CogniTerm 2>/dev/null || true
mkdir -p "$REPO/.build"
rm -f "$LOG"
# OTHER_SWIFT_FLAGS 必须走命令行：工程级设置到不了 SPM 包目标，
# 包里的 SwiftData 宏（@Model）会死在 swift-plugin-server 沙箱上。
# 命令行传参会整体覆盖工程值，故显式带 -disable-sandbox。
xcodebuild -project "$REPO/App/CogniTerm.xcodeproj" -scheme CogniTerm -configuration Debug \
  -derivedDataPath "$DERIVED" OTHER_SWIFT_FLAGS="-disable-sandbox" test >"$LOG" 2>&1 &
XBPID=$!
# 编译完成的信号（冷/热缓存走的步骤不同，故多信号判定）：
#   冷构建末段有 RegisterExecutionPolicyException；热缓存会跳过注册类步骤，
#   只以最后的 SDKExplicitPrecompiledModules prune 收尾。
# 出现任一信号即视为编译完成——再往后就是必挂的 hosted 测试连接阶段。
DONE_RE='RegisterExecutionPolicyException.*CogniTermTests|PruneExplicitPrecompiledModules .*SDKExplicitPrecompiledModules'
FAIL_RE='\*\* BUILD FAILED \*\*|Testing failed|\*\* TEST FAILED \*\*'
for _ in $(seq 1 240); do
  kill -0 "$XBPID" 2>/dev/null || break
  grep -qE "$DONE_RE" "$LOG" 2>/dev/null && break
  grep -qE "$FAIL_RE" "$LOG" 2>/dev/null && break
  sleep 5
done
# 给末尾的 Touch/Validate 留一点余量再收工
sleep 3
kill "$XBPID" 2>/dev/null || true
wait "$XBPID" 2>/dev/null || true

# ⚠️ 失败判定必须排在完成判定之前：编译失败的日志里同样会出现
#    PruneExplicitPrecompiledModules 这类"完成信号"（实测如此），先查 DONE
#    会把编译错误放过去。本脚本里 xcodebuild 只当编译器用，任何
#    BUILD FAILED / TEST FAILED / Testing failed 都是真失败。
#    曾经的真实事故：新增测试文件有编译错误，看门狗照常收工，随后拿上一轮
#    遗留的旧 bundle 跑 xcrun xctest → 13 个旧测试全绿 → EXIT=0，
#    新测试根本没被编译，失败被完全掩盖。
if grep -qE "$FAIL_RE" "$LOG"; then
  echo "!! 构建/编译失败（xcodebuild 在此仅作编译器用），错误摘要：" >&2
  grep -E "error:" "$LOG" | head -20 >&2
  exit 1
fi
if ! grep -qE "$DONE_RE" "$LOG"; then
  echo "!! 未能判定编译完成（既无完成信号也无失败信号），查看 $LOG" >&2
  tail -20 "$LOG" >&2
  exit 1
fi
# 陈旧 bundle 防护：不变量是「测试 bundle 必须比它的**所有输入**新」。
BUNDLE_BIN="$TESTS/Contents/MacOS/CogniTermTests"
if [ ! -x "$BUNDLE_BIN" ]; then
  echo "!! 未找到测试可执行文件：$BUNDLE_BIN" >&2
  exit 1
fi
# 不拿「本次构建开始时刻」当基准——增量构建一个文件都没重链接时，产物自然
# 不拿「本次构建开始时刻」当基准——增量构建一个文件都没重链接时，产物自然
# 早于本次调用却完全正确，那样会误报（build-app.sh 实测踩过）。
# 而"编译失败被放过"这种事故仍然拦得住：那个改过的源文件必然比旧 bundle 新。
STALE_INPUT="$(find "$REPO/App" "$REPO/Packages" -type f \
    \( -name '*.swift' -o -name '*.yml' -o -name '*.yaml' -o -name '*.plist' \
       -o -name '*.sb' -o -name '*.pbxproj' \) \
    -not -path "*/.build/*" -not -path "*/Resources/runtime/*" \
    -newer "$BUNDLE_BIN" -print -quit 2>/dev/null || true)"
if [ -n "$STALE_INPUT" ]; then
  echo "!! 测试 bundle 比输入旧（陈旧产物），拒绝运行：$BUNDLE_BIN" >&2
  echo "   bundle mtime : $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$BUNDLE_BIN")" >&2
  echo "   更新的输入   : $STALE_INPUT" >&2
  exit 1
fi

# ---- [3/3] 独立运行 App 测试 -------------------------------------------
echo "==> [3/3] 独立运行 App 测试（xcrun xctest，无 app host）"
# 测试二进制按 @loader_path 找 app 模块；把 dylib 放到同级目录即可命中
cp "$APP/Contents/MacOS/CogniTerm.debug.dylib" "$TESTS/Contents/MacOS/"
xcrun xctest "$TESTS"
