import Foundation

/// 会话 JSONL 文件读取：一次性全量读 + 增量 tail（DispatchSource 监听 extend）。
public enum JSONLFile {
    /// 全量读取并解析；忽略空行与坏行。
    public static func readAll(at url: URL, decoder: JSONDecoder = .acp) throws -> [LogEvent] {
        let data = try Data(contentsOf: url)
        return parseAll(data: data, decoder: decoder)
    }

    /// 从内存数据解析。公开给需要在别的模块里先解码（如 zstd 多帧）再归约的调用方。
    public static func parseAll(data: Data, decoder: JSONDecoder = .acp) -> [LogEvent] {
        var events: [LogEvent] = []
        var seq = 0
        data.split(separator: 0x0A, omittingEmptySubsequences: true).forEach { line in
            if let event = JSONLLine.parse(Data(line), seq: seq, decoder: decoder) {
                events.append(event)
                seq += 1
            }
        }
        return events
    }
}

/// 监听单个 JSONL 文件的增长与轮转（改名/替换），把新行回调给上层。
public final class EventFileTailer {
    public var onEvents: (([LogEvent]) -> Void)?
    public var onRotation: (() -> Void)?
    public var onError: ((Error) -> Void)?

    private let url: URL
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.cogniterm.sessionlog.tailer")
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var fileID: (dev_t, ino_t)?
    private var partial = Data()
    private var seq: Int = 0
    private var offset: off_t = 0
    private var isReopening = false

    public init(url: URL, decoder: JSONDecoder = .acp) {
        self.url = url
        self.decoder = decoder
    }

    public func start(includingExisting: Bool = true) throws {
        try openFileDescriptor()
        if includingExisting {
            consumeReadable()
        } else {
            offset = lseek(fd, 0, SEEK_END)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if source.data.contains(.delete) || source.data.contains(.rename)
                || self.pathWasReplaced() {
                self.reopen()
                return
            }
            self.consumeReadable()
        }
        source.setCancelHandler { [weak self] in
            self?.handleSourceCancel()
        }
        self.source = source
        source.resume()
    }

    private func handleSourceCancel() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    public var consumedOffset: off_t { offset }

    // MARK: - private

    private func openFileDescriptor() throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        self.fd = fd
        var statInfo = stat()
        guard fstat(fd, &statInfo) == 0 else { throw POSIXError(.EIO) }
        self.fileID = (statInfo.st_dev, statInfo.st_ino)
        self.offset = 0
        self.partial.removeAll()
    }

    private func pathWasReplaced() -> Bool {
        var pathStat = stat()
        guard stat(url.path, &pathStat) == 0 else { return true }
        guard let current = fileID else { return true }
        return current.0 != pathStat.st_dev || current.1 != pathStat.st_ino
    }

    private func reopen(attempt: Int = 0) {
        if attempt == 0 {
            // 同一批 delete/rename 事件可能连续触发；去重。
            guard !isReopening else { return }
            isReopening = true
        }
        let oldSource = source
        source = nil
        oldSource?.setCancelHandler {
            // 显式捕获旧 fd：取消回调可能晚于新 fd 赋值，绝不能误关新 fd。
        }
        oldSource?.cancel()
        if fd >= 0 { close(fd); fd = -1 }
        if attempt == 0 { onRotation?() }
        do {
            isReopening = false
            try openFileDescriptor()
            let newSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .delete, .rename],
                queue: queue
            )
            newSource.setEventHandler { [weak self] in
                guard let self else { return }
                if newSource.data.contains(.delete) || newSource.data.contains(.rename)
                    || self.pathWasReplaced() {
                    self.reopen()
                    return
                }
                self.consumeReadable()
            }
            newSource.setCancelHandler { [weak self] in
                self?.handleSourceCancel()
            }
            self.source = newSource
            newSource.resume()
            consumeReadable()
        } catch {
            // 轮转与新文件创建之间可能有短暂窗口（move 后新文件尚未落盘），有限重试。
            isReopening = true
            if attempt < 5 {
                queue.asyncAfter(deadline: .now() + .milliseconds(100 * (attempt + 1))) { [weak self] in
                    self?.reopen(attempt: attempt + 1)
                }
            } else {
                onError?(error)
            }
        }
    }

    private func consumeReadable() {
        var buffer = Data()
        let chunkSize = 64 * 1024
        while true {
            var chunk = Data(count: chunkSize)
            let readCount = chunk.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress, chunkSize)
            }
            if readCount > 0 {
                buffer.append(chunk.prefix(readCount))
                offset += off_t(readCount)
                if readCount < chunkSize { break }
            } else {
                break
            }
        }
        guard !buffer.isEmpty || !partial.isEmpty else { return }
        partial.append(buffer)

        var lastNewline = -1
        var events: [LogEvent] = []
        for (index, byte) in partial.enumerated() where byte == 0x0A {
            lastNewline = index
        }
        guard lastNewline >= 0 else { return }

        let complete = partial.prefix(lastNewline)
        partial = Data(partial.suffix(from: lastNewline + 1))

        complete.split(separator: 0x0A, omittingEmptySubsequences: true).forEach { line in
            if let event = JSONLLine.parse(Data(line), seq: seq, decoder: decoder) {
                events.append(event)
                seq += 1
            }
        }
        if !events.isEmpty { onEvents?(events) }
    }
}
