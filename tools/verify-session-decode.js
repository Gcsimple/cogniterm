// 用 homebrew 的 zstd 作为**外部判据**，验证自研多帧切分器的输出与之一致。
// 这个脚本只在开发期跑（zstd 不是分发依赖）：node tools/verify-session-decode.js
'use strict';
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { frameBounds } = require('./session-decode.js');

const ZSTD = '/opt/homebrew/bin/zstd';
const home = path.join(process.env.HOME, 'Library/Application Support/CogniTerm/dsh-home');
const sessionsDir = path.join(home, 'sessions');

function walk(dir, acc) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, acc);
    else if (/^session\.v\d+\.jsonl\.zstd$/.test(e.name)) acc.push(p);
  }
  return acc;
}

const files = walk(sessionsDir, []);
let ok = 0, bad = 0, nonzero = 0;
for (const f of files) {
  const mine = execFileSync(process.execPath, [path.join(__dirname, 'session-decode.js'), f]);
  const oracle = execFileSync(ZSTD, ['-dc', f]);
  const same = mine.equals(oracle);
  const lines = mine.toString('utf8').split('\n').filter(Boolean).length;
  if (lines > 1) nonzero++;
  if (same) ok++; else {
    bad++;
    console.log('MISMATCH', f, 'mine', mine.length, 'oracle', oracle.length, 'frames', frameBounds(fs.readFileSync(f)).length);
  }
}
console.log(`总计 ${files.length} 个会话文件：一致 ${ok}，不一致 ${bad}（其中多行会话 ${nonzero}）`);
