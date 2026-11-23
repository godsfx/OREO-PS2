import Foundation

final class BootDiagLogger: @unchecked Sendable {
    static let shared = BootDiagLogger()

    private let queue = DispatchQueue(label: "com.oreo.ps2.bootdiaglogger")
    private var fileHandle: FileHandle?
    private var currentLogURL: URL?

    private init() {}

    @discardableResult
    func startSession(gameTitle: String, discURL: URL) -> URL? {
        queue.sync {
            closeUnlocked()

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("BootDiagLogs", isDirectory: true)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let formatter = ISO8601DateFormatter()
            let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let safeTitle = gameTitle.replacingOccurrences(of: "/", with: "_")
            let logURL = tempDir.appendingPathComponent("boot-\(safeTitle)-\(stamp).log")

            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: logURL)
            currentLogURL = logURL

            let header = "=== BOOT DIAG SESSION | game=\(gameTitle) | disc=\(discURL.lastPathComponent) ===\n"
            writeUnlocked(header)
            return logURL
        }
    }

    func log(_ tag: String, _ message: String) {
        queue.async {
            let line = "[\(Self.timestamp())] [\(tag)] \(message)\n"
            self.writeUnlocked(line)
        }
    }

    func logHex(_ tag: String, _ label: String, addr: UInt32, val: UInt32) {
        let hexAddr = String(addr, radix: 16, uppercase: true)
        let hexVal = String(val, radix: 16, uppercase: true)
        log(tag, "\(label) addr=0x\(hexAddr) val=0x\(hexVal)")
    }

    func flush() {
        queue.sync {
            try? fileHandle?.synchronize()
        }
    }

    func close() {
        queue.sync {
            closeUnlocked()
        }
    }

    private func writeUnlocked(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let handle = fileHandle {
            handle.write(data)
        } else {
            NSLog("%@", text)
        }
    }

    private func closeUnlocked() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
