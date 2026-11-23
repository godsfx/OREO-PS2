import Foundation

// MARK: - CDVD Drive Controller
// Handles streaming ISO 9660 disc reading, BIN/CUE parsing, PS2 executable loading,
// and NTSC/PAL region detection without loading multi-GB images into RAM.

public final class CDVD {

    // MARK: - State

    enum DriveState { case idle, seeking, reading, paused }
    var driveState: DriveState = .idle

    var discURL:   URL?
    var isoData:   Data?
    var chdReader: CHDReader?
    private var discHandle: FileHandle?

    // Sector geometry — ISO: 2048 bytes/sector, raw BIN: 2352 bytes/sector
    private var sectorSize: Int   = 2048
    private var dataOffset: Int   = 0

    // ISO 9660 cached fields
    var pvd: PrimaryVolumeDescriptor?
    var discID: String = ""
    var discRegion: DiscRegion = .unknown

    // MARK: - Registers

    var status:  UInt8 = 0x40
    var error:   UInt8 = 0x00
    var iStat:   UInt8 = 0x00
    var iMask:   UInt8 = 0x00
    var command: UInt8 = 0x00
    var result:  [UInt8] = Array(repeating: 0, count: 16)
    var resultPtr: Int = 0
    var resultLen: Int = 0
    var seekTarget: UInt32 = 0

    deinit {
        _ = try? discHandle?.close()
    }

    private func openStream(_ url: URL) throws {
        _ = try? discHandle?.close()
        discHandle = nil
        chdReader  = nil
        isoData    = Data() // non-nil sentinel for legacy nil checks
        discHandle = try FileHandle(forReadingFrom: url)
    }

    private func readDiscBytes(at offset: UInt64, length: Int) -> Data? {
        guard length > 0 else { return nil }
        let capped = min(length, 16 * 1024 * 1024)
        if let chd = chdReader {
            return try? chd.readBytes(at: offset, length: capped)
        }
        if let handle = discHandle {
            do {
                let endPos = try handle.seekToEnd()
                guard offset < endPos else { return nil }
                try handle.seek(toOffset: offset)
                let avail = Int(min(UInt64(capped), endPos - offset))
                guard avail > 0 else { return nil }
                return try handle.read(upToCount: avail)
            } catch {
                return nil
            }
        }
        if let data = isoData, !data.isEmpty {
            guard offset < UInt64(data.count) else { return nil }
            let start = Int(offset)
            let avail = min(capped, data.count - start)
            guard avail > 0 else { return nil }
            return Data(data[start..<(start + avail)])
        }
        return nil
    }

    // MARK: - Disc Loading

    /// Load a CHD v5 disc image with uncached memory mapping so iOS Jetsam can evict clean pages.
    func loadCHD(url: URL) throws {
        _ = try? discHandle?.close()
        discHandle = nil
        let data   = try Data(contentsOf: url, options: [.mappedIfSafe, .uncached])
        chdReader  = try CHDReader(data: data)
        isoData    = Data()
        discURL    = url
        sectorSize = 2048
        dataOffset = 0
        parseISO9660()
        driveState = .idle
    }

    func loadISO(url: URL) throws {
        try openStream(url)
        discURL    = url
        sectorSize = 2048
        dataOffset = 0
        parseISO9660()
        driveState = .idle
    }

    /// Load a BIN/CUE disc image via FileHandle streaming.
    func loadCUE(url: URL) throws {
        let cueText = (try? String(contentsOf: url, encoding: .utf8))
            ?? (try? String(contentsOf: url, encoding: .ascii))
            ?? ""
        var binFilename: String?

        for line in cueText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("FILE") {
                let parts = trimmed.components(separatedBy: "\"")
                if parts.count >= 2 { binFilename = parts[1]; break }
            }
        }

        guard let binFilename, !binFilename.isEmpty else {
            throw EmulatorError.discLoadFailed("No BIN file referenced in CUE sheet")
        }

        let normalized = binFilename.replacingOccurrences(of: "\\", with: "/")
        let baseName = URL(fileURLWithPath: normalized).lastPathComponent
        let binURL = url.deletingLastPathComponent().appendingPathComponent(baseName.isEmpty ? normalized : baseName)
        let binSize = (try? FileManager.default.attributesOfItem(atPath: binURL.path)[.size] as? UInt64) ?? 0
        BootDiagLogger.shared.log("CDVD", "CUE parsed: cue=\(url.lastPathComponent) -> bin=\(binURL.lastPathComponent) exists=\(FileManager.default.fileExists(atPath: binURL.path)) size=\(binSize)")
        guard FileManager.default.fileExists(atPath: binURL.path) else {
            throw EmulatorError.discLoadFailed("Referenced BIN file not found: \(baseName)")
        }
        try openStream(binURL)
        discURL    = url
        sectorSize = 2352
        dataOffset = 24
        parseISO9660()
        driveState = .idle
    }

    /// Auto-detect BIN without CUE via FileHandle probe.
    func loadBIN(url: URL) throws {
        try openStream(url)
        discURL = url
        let pvdOffsetRaw = UInt64(16 * 2352 + 24)
        if let probe = readDiscBytes(at: pvdOffsetRaw, length: 1), probe.first == 0x01 {
            sectorSize = 2352
            dataOffset = 24
        } else {
            sectorSize = 2048
            dataOffset = 0
        }
        parseISO9660()
        driveState = .idle
    }

    // MARK: - ISO 9660 Parsing

    private func parseISO9660() {
        let pvdOffset = UInt64(16 * sectorSize + dataOffset)
        guard let pvdData = readDiscBytes(at: pvdOffset, length: 2048),
              pvdData.count >= 882 else {
            BootDiagLogger.shared.log("CDVD", "ISO9660 PVD read failed at offset=\(pvdOffset) sectorSize=\(sectorSize) dataOffset=\(dataOffset)")
            return
        }

        let sig = String(bytes: pvdData.prefix(6), encoding: .ascii) ?? "?"
        pvd        = PrimaryVolumeDescriptor(data: pvdData[pvdData.startIndex...])
        discID     = readDiscID()
        discRegion = detectRegion()
        BootDiagLogger.shared.log("CDVD", "ISO9660 PVD OK | type=0x\(String(pvdData.first ?? 0, radix: 16)) sig=\(sig) rootLBA=\(pvd?.rootDirectoryLBA ?? 0) rootSize=\(pvd?.rootDirectorySize ?? 0) discID=\(discID) region=\(discRegion.rawValue)")
    }

    private func readDiscID() -> String {
        if let cnfData = readFile(path: "SYSTEM.CNF") {
            let text = String(data: cnfData, encoding: .ascii) ?? ""
            for line in text.components(separatedBy: .newlines) {
                if line.uppercased().hasPrefix("BOOT2") {
                    let parts = line.components(separatedBy: "\\")
                    if let last = parts.last {
                        let cleaned = last.components(separatedBy: ";").first ?? last
                        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        }
        return ""
    }

    private func detectRegion() -> DiscRegion {
        let id = discID.uppercased()
        if id.hasPrefix("SLUS") || id.hasPrefix("SCUS") { return .ntscU }
        if id.hasPrefix("SLES") || id.hasPrefix("SCES") { return .pal   }
        if id.hasPrefix("SLPS") || id.hasPrefix("SCPS") || id.hasPrefix("SLPM") { return .ntscJ }
        return .unknown
    }

    // MARK: - ISO 9660 File Reading

    func readFile(path: String, data: Data) -> Data? {
        return readFile(path: path)
    }

    func readFile(path: String) -> Data? {
        guard let pvd = pvd else { return nil }
        let components = path.split(separator: "/").map(String.init)
        var dirLBA  = pvd.rootDirectoryLBA
        var dirSize = pvd.rootDirectorySize

        for (idx, component) in components.enumerated() {
            let isLast  = idx == components.count - 1
            let dirData = readSectors(lba: dirLBA, size: dirSize)
            var offset  = 0
            while offset < dirData.count {
                let recLen = Int(dirData[offset])
                guard recLen > 0 else { break }
                let nameLen = Int(dirData[offset + 32])
                guard offset + 33 + nameLen <= dirData.count else { break }
                var entryName = String(bytes: dirData[(offset + 33)..<(offset + 33 + nameLen)],
                                       encoding: .ascii) ?? ""
                if let semi = entryName.firstIndex(of: ";") { entryName = String(entryName[..<semi]) }
                if entryName.uppercased() == component.uppercased() {
                    let lba  = dirData.withUnsafeBytes { $0.load(fromByteOffset: offset + 2,  as: UInt32.self).littleEndian }
                    let size = dirData.withUnsafeBytes { $0.load(fromByteOffset: offset + 10, as: UInt32.self).littleEndian }
                    if isLast { return readSectors(lba: lba, size: size) }
                    dirLBA = lba; dirSize = size
                    break
                }
                offset += recLen
            }
        }
        return nil
    }

    private func readSectors(lba: UInt32, size: UInt32) -> Data {
        if sectorSize == 2048 {
            return readDiscBytes(at: UInt64(lba) * 2048, length: Int(size)) ?? Data()
        } else {
            let sectorCount = (Int(size) + 2047) / 2048
            var result = Data(capacity: Int(size))
            for i in 0..<sectorCount {
                let sectorStart = UInt64((Int(lba) + i) * sectorSize + dataOffset)
                let bytesLeft   = Int(size) - i * 2048
                let copyLen     = min(2048, bytesLeft)
                guard let chunk = readDiscBytes(at: sectorStart, length: copyLen),
                      chunk.count == copyLen else { break }
                result.append(chunk)
            }
            return result
        }
    }

    // MARK: - IOP I/O

    func readIO(offset: UInt32) -> UInt32 {
        switch offset {
        case 0: return UInt32(status)
        case 1: return UInt32(error)
        case 2:
            guard resultLen > 0, resultPtr < result.count else { return 0 }
            let val = UInt32(result[resultPtr])
            resultPtr += 1
            if resultPtr >= resultLen { status |= 0x40 }
            return val
        case 3: return UInt32(iStat)
        case 4: return UInt32(iMask)
        default: return 0
        }
    }

    func writeIO(offset: UInt32, value: UInt32) {
        switch offset {
        case 0: command = UInt8(value & 0xFF); processCommand()
        case 3: iStat &= ~UInt8(value & 0xFF)
        case 4: iMask = UInt8(value & 0xFF)
        default: break
        }
    }

    private func processCommand() {
        BootDiagLogger.shared.log("CDVD-IO", "Command 0x\(String(command, radix: 16, uppercase: true))")
        switch command {
        case 0x15:
            let now = Date(); let cal = Calendar.current
            result[0] = 0
            result[1] = toBCD(cal.component(.second, from: now))
            result[2] = toBCD(cal.component(.minute, from: now))
            result[3] = toBCD(cal.component(.hour,   from: now))
            result[4] = toBCD(cal.component(.day,    from: now))
            result[5] = toBCD(cal.component(.month,  from: now))
            result[6] = toBCD(cal.component(.year,   from: now) % 100)
            resultLen = 8; resultPtr = 0
        case 0x40:
            result[0] = 0; result[1] = 0x14
            resultLen = 2; resultPtr = 0
        default:
            result[0] = 0; resultLen = 1; resultPtr = 0
        }
        status &= ~0x40
        iStat |= 0x01
    }

    private func toBCD(_ value: Int) -> UInt8 { UInt8(((value / 10) << 4) | (value % 10)) }
}

// MARK: - ISO 9660 PVD

struct PrimaryVolumeDescriptor {
    var rootDirectoryLBA:  UInt32
    var rootDirectorySize: UInt32
    var volumeSpaceSize:   UInt32
    var logicalBlockSize:  UInt16

    init?(data: Data.SubSequence) {
        guard data.count >= 170 else { return nil }
        let bytes = Data(data)
        rootDirectoryLBA  = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 158, as: UInt32.self).littleEndian }
        rootDirectorySize = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 166, as: UInt32.self).littleEndian }
        volumeSpaceSize   = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80,  as: UInt32.self).littleEndian }
        logicalBlockSize  = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 128, as: UInt16.self).littleEndian }
    }
}

// MARK: - Region

enum DiscRegion: String { case ntscU = "NTSC-U", ntscJ = "NTSC-J", pal = "PAL", unknown = "Unknown" }
