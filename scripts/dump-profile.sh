#!/usr/bin/env bash
#
# dump-profile.sh —— 真跑一次 dsh，验证 agentic core 覆盖层能被接受。
#
# 用法：scripts/dump-profile.sh [profile名，默认 acp]
#
# 为什么需要它：CogniTermTests 里的 CoreProfilePatchTests 只做文本断言
# （防误关核心能力），证明不了 dsh 真的吃得下这份 yml。YAML 缩进错、
# id 拼错、插件名不存在，都只会在 --dump-config 时才暴露。
#
# 产出：<DSH_HOME>/../dump-<profile>.yml 与打印启用/禁用统计。
# 对比基线（不带 --patch）即可看出收编前后差异。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-acp}"
RUNTIME="${DSH_RUNTIME_DIR:-$REPO/App/Resources/runtime}"
NODE="$RUNTIME/node-darwin-arm64/bin/node"
CLI="$RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js"
PATCH="$REPO/App/Resources/patches/cogniterm-core.patch.yml"
OUT_DIR="$REPO/.build"

[ -x "$NODE" ] || { echo "!! 找不到 vendored node：${NODE}（先跑 scripts/vendor-runtime.sh）" >&2; exit 1; }
[ -f "$CLI" ]  || { echo "!! 找不到 dsh CLI：$CLI" >&2; exit 1; }
[ -f "$PATCH" ] || { echo "!! 找不到收编 patch：$PATCH" >&2; exit 1; }

export DSH_HOME="${DSH_HOME:-$HOME/Library/Application Support/CogniTerm/dsh-home}"
mkdir -p "$OUT_DIR"

echo "==> 基线（profile=${PROFILE}，不带收编 patch）"
"$NODE" "$CLI" --profile "$PROFILE" --dump-config > "$OUT_DIR/dump-baseline.yml" 2>&1 \
  || { echo "!! 基线 dump 失败" >&2; cat "$OUT_DIR/dump-baseline.yml" >&2; exit 1; }

echo "==> 收编后（叠加 cogniterm-core.patch.yml）"
"$NODE" "$CLI" --profile "$PROFILE" --patch "$PATCH" --dump-config > "$OUT_DIR/dump-cogniterm.yml" 2>&1 \
  || { echo "!! 收编 patch 合成失败，dsh 报错原文：" >&2; cat "$OUT_DIR/dump-cogniterm.yml" >&2; exit 1; }

python3 - "$OUT_DIR/dump-baseline.yml" "$OUT_DIR/dump-cogniterm.yml" <<'PY'
import re, sys

def parse(path):
    entries, cur = [], None
    for line in open(path, encoding='utf-8').read().split('\n'):
        m = re.match(r'^- id: (\S+)', line)
        if m:
            if cur: entries.append(cur)
            cur = {'id': m.group(1), 'name': '', 'disabled': False}
            continue
        if cur is None: continue
        m = re.match(r'^  name: (\S+)', line)
        if m and not cur['name']:
            cur['name'] = m.group(1).strip("'"); continue
        m = re.match(r'^  disabled: (.*)', line)
        if m and not cur['disabled']:
            cur['disabled'] = m.group(1).strip() != 'false'
    if cur: entries.append(cur)
    return {e['id']: e for e in entries}

base = parse(sys.argv[1]); new = parse(sys.argv[2])
live = lambda d: sum(1 for e in d.values() if not e['disabled'])
print(f"基线：{len(base)} 条 / 启用 {live(base)}")
print(f"收编：{len(new)} 条 / 启用 {live(new)}")
print()
print("本次关闭：")
for k, v in base.items():
    if not v['disabled'] and new.get(k, {}).get('disabled'):
        print(f"  - {k}  ({v['name']})")
print()
lost = [k for k, v in base.items() if not v['disabled'] and k not in new]
if lost:
    print("!! 有插件条目丢失（可能是 id 拼错）：", lost); sys.exit(1)
print("核心能力自检：")
core = ['agent-loop', 'tools', 'system-prompt', 'llm-deepseek', 'acp-app-startup',
        'session', 'session-persistence-jsonl', 'sandbox', 'sandbox-policy',
        'approval', 'permission', 'tool-fs', 'skill', 'tool-skill',
        'token-meter', 'compaction-basic']
bad = [k for k in core if not (new.get(k) and not new[k]['disabled'])]
if bad:
    print("  !! 被误关：", bad); sys.exit(1)
print(f"  {len(core)} 项全部在位")
PY

echo
echo "产物：$OUT_DIR/dump-baseline.yml / $OUT_DIR/dump-cogniterm.yml"