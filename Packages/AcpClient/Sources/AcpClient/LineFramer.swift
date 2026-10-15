import Foundation

/// 按 ACP/JSON-RPC over stdio 规约切帧：一帧 = 一行以 `\n` 结尾的 UTF-8 JSON（容忍 `\r\n`）。
/// 非线程安全：约定只在传输层的读取回调上下文中调用。
public final class LineFramer {
    private var buffer = Data()

    public init() {}

    public func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let end = newlineIndex
            var line = buffer.subdata(in: buffer.startIndex..<end)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { frames.append(line) }
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return frames
    }

    /// 尚未成帧的残余字节（连接关闭时若有内容可作为诊断，不产生半帧事件）。
    public var leftover: Data { buffer }
}
