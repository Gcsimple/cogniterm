import Foundation
import SessionLogReader

/// 读取 dsh 的会话轨迹（`session.v<N>.jsonl.zstd`）并归约成可回放状态。
///
/// 为什么需要它：dsh 的轨迹是 **zstd 多帧**（每次追加一个新帧），而
///   - `zlib.zstdDecompressSync` 只解第一帧（实测 11KB 的会话只出 169 字节）；
///   - macOS 的 libcompression 没有 zstd（`compression.h` 里只有 LZ4/ZLIB/LZMA/
///     BROTLI/LZFSE/LZBITMAP/LZRAVEN/LZMESH），所以 Swift 侧没有系统解码器；
///   - 我们自己 ship 了 node（sidecar 运行时），Node 22+ 的 zlib 带
///     `zstdDecompressSync`。
///
/// 于是：内嵌一段几十行的帧切分脚本（`decoderScript`），用内置 node 跑一次，
/// 每帧单独解压后拼起来。脚本与 `tools/session-decode.js` 同源；开发期用 homebrew
/// 的 `zstd` 作为外部判据逐字节比对过 123 个真实会话（0 处不一致）。
enum SessionArchive {

    enum Failure: LocalizedError {
        case nodeMissing(String)
        case decodeFailed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .nodeMissing(let path):
                return "找不到内置运行环境（\(path)），无法读取会话轨迹"
            case .decodeFailed(let message):
                return "会话轨迹解码失败：\(message)"
            case .empty:
                return "这个会话没有可显示的轨迹内容"
            }
        }
    }

    /// 解压成明文 JSONL。
    ///
    /// 解析放在子进程里做，因为 zstd 帧切分比"读一个文件"复杂得多，
    /// 而 node 恰好是我们已经随包分发的唯一运行时。
    static func plainJSONL(at url: URL) throws -> Data {
        let node = try nodeExecutable()
        let script = try installedDecoderScript()

        let process = Process()
        process.executableURL = node
        process.arguments = [script.path, url.path]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // 先读完再 waitUntilExit：大会话（几十 MB 解压后）会把 pipe 写满，
        // 顺序反了就是死锁。
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errData.prefix(400), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.decodeFailed(message.isEmpty ? "exit \(process.terminationStatus)" : message)
        }
        guard !data.isEmpty else { throw Failure.empty }
        return data
    }

    /// 解压 + 归约，直接给回放视图用。
    static func replayState(at url: URL) throws -> SessionViewState {
        let data = try plainJSONL(at: url)
        let events = JSONLFile.parseAll(data: data, decoder: .acp)
        guard !events.isEmpty else { throw Failure.empty }
        return SessionReducer.reduceAll(events: events)
    }

    // MARK: - 内置运行时与脚本

    private static func nodeExecutable() throws -> URL {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime/node-darwin-arm64/bin/node"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime/node-x64/bin/node"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw Failure.nodeMissing(candidates[0].path)
    }

    /// 把内嵌脚本落到 Application Support 再执行（不用 `node -e`：脚本里的引号与
    /// 换行在 argv 上很容易被 shell / 沙箱层改坏，落成文件最稳）。
    ///
    /// 写入是幂等的：内容没变就不重写。脚本损坏（被截断/手改）时自动重写，
    /// 因为它是我们自己的产物、不含用户数据。
    private static func installedDecoderScript() throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CogniTerm", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session-decode.js")

        let expected = Data(decoderScript.utf8)
        if (try? Data(contentsOf: url)) != expected {
            try expected.write(to: url, options: .atomic)
        }
        return url
    }

    // MARK: - 解码脚本

    /// 与 `tools/session-decode.js` 同源（那份用于开发期验证）。
    ///
    /// 用裸字符串（`#"""`）而不是普通多行字符串：脚本里全是 `\n` 与 `'\0'`
    /// 这类转义，普通字符串会把它们提前吃掉。
    static let decoderScript = #"""
    'use strict';
    const fs = require('fs');
    const zlib = require('zlib');
    const MAGIC = 0xFD2FB528;

    function frameBounds(buf) {
      const out = [];
      let p = 0;
      while (p + 4 <= buf.length) {
        if (buf.readUInt32LE(p) !== MAGIC) break;
        const start = p;
        p += 4;
        if (p >= buf.length) break;
        const fhd = buf[p++];
        const fcsFlag = fhd >> 6;
        const singleSegment = (fhd >> 5) & 1;
        const checksumFlag = (fhd >> 2) & 1;
        const dictFlag = fhd & 3;
        if (!singleSegment) { if (p >= buf.length) break; p += 1; }
        p += [0, 1, 2, 4][dictFlag] || 0;
        p += [singleSegment ? 1 : 0, 2, 4, 8][fcsFlag];
        let ok = false;
        while (p + 3 <= buf.length) {
          const header = buf[p] | (buf[p + 1] << 8) | (buf[p + 2] << 16);
          p += 3;
          const last = header & 1;
          const type = (header >> 1) & 3;
          const size = header >>> 3;
          if (type === 3) return out;
          p += type === 1 ? 1 : size;
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
      try { parts.push(zlib.zstdDecompressSync(buf)); } catch (e) {}
    }
    process.stdout.write(Buffer.concat(parts));
    """#
}
