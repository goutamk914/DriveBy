//  SampleFileWriter.swift — Driveby
//  Append-only JSONL writer. One sample per line, flushed to disk every 5 s
//  ("a crash at minute 40 must not lose minutes 0–39"). Thread-safe: GPS (main
//  thread), IMU (motion queue), vision (video queue) and OBD (BLE queue) all append.

import Foundation

final class SampleFileWriter: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "driveby.samplewriter", qos: .utility)
    private var handle: FileHandle?
    private var buffer = Data()
    private var timer: DispatchSourceTimer?
    private(set) var linesWritten = 0
    private var closed = false

    init(url: URL) throws {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
        buffer.reserveCapacity(256 * 1024)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.flushLocked(sync: true) }
        t.resume()
        timer = t
    }

    func append(_ line: String) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.buffer.append(contentsOf: line.utf8)
            self.buffer.append(0x0A)
            self.linesWritten += 1
            if self.buffer.count > 512 * 1024 { self.flushLocked(sync: false) }
        }
    }

    func flush() { queue.sync { flushLocked(sync: true) } }

    /// Flushes, fsyncs and closes. Safe to call more than once.
    func close() {
        queue.sync {
            guard !closed else { return }
            flushLocked(sync: true)
            timer?.cancel(); timer = nil
            try? handle?.close(); handle = nil
            closed = true
        }
    }

    private func flushLocked(sync: Bool) {
        guard let handle, !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: buffer)
            if sync { try handle.synchronize() }
        } catch {
            // Disk full or file protection: keep buffering is pointless; drop and keep the app alive.
        }
        buffer.removeAll(keepingCapacity: true)
    }

    deinit { timer?.cancel() }
}
