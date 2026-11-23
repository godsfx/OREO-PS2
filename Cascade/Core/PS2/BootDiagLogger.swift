import Foundation

// MARK: - Temporary Boot & ISO Diagnostic Logger
// Writes detailed step-by-step boot, CDVD/ISO, SIF, DMAC, EE/IOP PC & register telemetry
// to a shareable temporary log file in Documents/Logs/ and /tmp/ so stalls can be diagnosed.

public final class BootDiagLogger: @unchecked Sendable {

    public static let shared = BootDiagLogger()

    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private(set) var currentLogURL: URL?
    private var startTime: UInt64 = DispatchTime.now().uptimeNanoseconds
    private var lineCount: Int = 0
    private let maxLines: Int = 12_000

    private init() {}

    @discardableResult
    public func startSession(gameTitle: String, discURL: URL?) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        closeLocked()
        startTime = DispatchTime.now().uptimeNanoseconds
        lineCount = 0

        let fm = FileManager.default
        let docsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let logsDir = docsDir.appendingPathComponent("Logs", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = fmt.string(from: Date())
        let safeTitle = gameTitle
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
            .prefix(40)
        let fileName = "oreo_ps2_boot_\(safeTitle)_\(stamp).log"
        let fileURL = logsDir.appendingPathComponent(fileName)

        fm.createFile(atPath: fileURL.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: fileURL)
        currentLogURL = fileURL

        // Also mirror latest log path in tmp for quick access
        let latestLink = fm.temporaryDirectory.appendingPathComponent("oreo_ps2_latest_boot.log")
        try? fm.removeItem(at: latestLink)
        try? fm.createSymbolicLink(at: latestLink, withDestinationURL: fileURL)

        writeLocked("=== OREO-PS2 BOOT & ISO DIAGNOSTIC LOG ===")
        writeLocked("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        writeLocked("Game: \(gameTitle)")
        writeLocked("Disc Path: \(discURL?.path ?? "none")")
        writeLocked("Log File: \(fileURL.path)")
        writeLocked("==========================================")
        return fileURL
    }

    public func log(_ category: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard lineCount < maxLines else { return }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000.0
        let prefix = String(format: "[+%09.2f ms][%@]", elapsedMs, category)
        writeLocked("\(prefix) \(message)")
        lineCount += 1
        if lineCount == maxLines {
            writeLocked("[LOG] Max line cap (\(maxLines)) reached; further events suppressed.")
        }
    }

    public func logHex(_ category: String, _ label: String, addr: UInt32, val: UInt32) {
        log(category, "\(label) addr=0x\(String(addr, radix: 16, uppercase: true)) val=0x\(String(val, radix: 16, uppercase: true))")
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.synchronize()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        if let fh = fileHandle {
            try? fh.synchronize()
            try? fh.close()
        }
        fileHandle = nil
    }

    private func writeLocked(_ text: String) {
        let line = text + "\n"
        print(text)
        if let data = line.data(using: .utf8), let fh = fileHandle {
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        }
    }
}
