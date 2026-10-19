// dsh 会话轨迹解压（zstd 多帧）→ 明文 JSONL 到 stdout。
//
// 为什么需要这个脚本：dsh 把会话写成 session.v<N>.jsonl.zstd，且**每次追加一个新帧**。
// zlib.zstdDecompressSync 只解第一帧（实测：11KB 的会话只出 169 字节 = 1 行），
// macOS 的 libcompression 又没有 zstd（compression.h 里只有 LZ4/ZLIB/LZMA/BROTLI/LZFSE），
// 所以只能自己按 zstd 帧格式切分，再逐帧解。
//
// 帧格式（RFC 8878）：
//   magic(4) | frame_header_descriptor(1) | [window_descriptor] | [dict_id] | [content_size] | blocks… | [checksum]
//   block: header(3, LE: last_bit | type(2) | size(21)) + payload
//     type 0=raw(size 字节) 1=RLE(1 字节) 2=compressed(size 字节) 3=reserved
// 我们只负责**找边界**，解码交给 node 内置 zstd——校验和字段存在时要在末块后再跳 4 字节。
'use strict';
const fs = require('fs');
const zlib = require('zlib');

const MAGIC = 0xFD2FB528;

/** 返回 [start, end) 帧区间列表；遇到坏数据就停在最后一个完整帧。 */
function frameBounds(buf) {
  const out = [];
  let p = 0;
  while (p + 4 <= buf.length) {
    if (buf.readUInt32LE(p) !== MAGIC) {
      // 首帧之前不应有垃圾；后续帧之间也不应有。遇到就停。
      break;
    }
    const start = p;
    p += 4;
    if (p >= buf.length) break;
    const fhd = buf[p++];
    const fcsFlag = fhd >> 6;          // 0,1,2,3
    const singleSegment = (fhd >> 5) & 1;
    const checksumFlag = (fhd >> 2) & 1;
    const dictFlag = fhd & 3;          // 0,1,2,3
    if (!singleSegment) {
      if (p >= buf.length) break;
      p += 1;                          // window descriptor
    }
    p += [0, 1, 2, 4][dictFlag] || 0;  // dictionary id
    p += [singleSegment ? 1 : 0, 2, 4, 8][fcsFlag];  // frame content size

    let ok = false;
    while (p + 3 <= buf.length) {
      const header = buf[p] | (buf[p + 1] << 8) | (buf[p + 2] << 16);
      p += 3;
      const last = header & 1;
      const type = (header >> 1) & 3;
      const size = header >>> 3;
      if (type === 3) return out;       // reserved，损坏
      p += type === 1 ? 1 : size;       // RLE 只占 1 字节
      if (p > buf.length) return out;
      if (last) { ok = true; break; }
    }
    if (!ok) break;
    if (checksumFlag) p += 4;
    if (p > buf.length) break;
    out.push([start, p]);
  }
  return out;
}

function main() {
  const file = process.argv[2];
  if (!file) { process.stderr.write('usage: session-decode.js <session.v*.jsonl.zstd>\n'); process.exit(2); }
  let buf;
  try { buf = fs.readFileSync(file); } catch (e) { process.stderr.write(String(e.message) + '\n'); process.exit(3); }

  const frames = frameBounds(buf);
  const parts = [];
  for (const [s, e] of frames) {
    try { parts.push(zlib.zstdDecompressSync(buf.subarray(s, e))); }
    catch (err) { process.stderr.write('frame decode failed at ' + s + ': ' + err.message + '\n'); break; }
  }
  if (frames.length === 0) {
    // 单帧文件（或格式未知）：退回一次性解压，别把能读的读成空。
    try { parts.push(zlib.zstdDecompressSync(buf)); } catch (e) { /* 交给上层判空 */ }
  }
  process.stdout.write(Buffer.concat(parts));
}

if (require.main === module) main();
module.exports = { frameBounds };
