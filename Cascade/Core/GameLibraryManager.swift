import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - GameEntry

struct GameEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var discID: String
    var region: String
    var fileName: String
    var fileSize: Int64
    var addedDate: Date
    var lastPlayedDate: Date?
    var isFavorite: Bool
    var collectionID: UUID?

    /// Resolves the current sandbox URL dynamically (Documents/games first, fallback to legacy Application Support/OREO-PS2/Games).
    var fileURL: URL {
        let primaryURL = GameLibraryManager.gamesDirectoryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: primaryURL.path) {
            return primaryURL
        }
        let legacyURL = GameLibraryManager.legacyGamesDirectoryURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }
        return primaryURL
    }

    /// Alias compatibility for views and state controllers expecting `game.url`
    var url: URL { fileURL }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var regionBadge: String {
        switch region.uppercased() {
        case "NTSC-U", "USA", "US":
            return "NTSC-U"
        case "PAL", "EUR", "EU":
            return "PAL"
        case "NTSC-J", "JPN", "JP":
            return "NTSC-J"
        default:
            return region.isEmpty ? "PS2" : region
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        discID: String = "UNKNOWN",
        region: String = "PS2",
        fileName: String,
        fileSize: Int64 = 0,
        addedDate: Date = Date(),
        lastPlayedDate: Date? = nil,
        isFavorite: Bool = false,
        collectionID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.discID = discID
        self.region = region
        self.fileName = fileName
        self.fileSize = fileSize
        self.addedDate = addedDate
        self.lastPlayedDate = lastPlayedDate
        self.isFavorite = isFavorite
        self.collectionID = collectionID
    }

    init(url: URL) {
        let extractedID = GameLibraryManager.extractDiscID(from: url)
        let resolvedRegion = GameLibraryManager.region(for: extractedID)
        let cleanStem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = GameLibraryManager.titleLookup[extractedID] ?? (cleanStem.isEmpty ? "PlayStation 2 Disc" : cleanStem)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0

        self.init(
            title: resolvedTitle,
            discID: extractedID,
            region: resolvedRegion,
            fileName: url.lastPathComponent,
            fileSize: size
        )
    }
}

// MARK: - GameCollection

struct GameCollection: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var colorIndex: Int
    var createdDate: Date

    init(
        id: UUID = UUID(),
        name: String,
        colorIndex: Int = 0,
        createdDate: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.createdDate = createdDate
    }

    static let palette: [Color] = [
        Color(red: 0.22, green: 0.52, blue: 0.96), // Cascade Blue
        Color(red: 0.16, green: 0.72, blue: 0.56), // Emerald
        Color(red: 0.92, green: 0.45, blue: 0.24), // Sunset Orange
        Color(red: 0.64, green: 0.36, blue: 0.92), // Royal Violet
        Color(red: 0.88, green: 0.28, blue: 0.46), // Crimson Rose
        Color(red: 0.18, green: 0.68, blue: 0.78)  // Cyan Teal
    ]

    var accentColor: Color {
        Self.palette[abs(colorIndex) % Self.palette.count]
    }
}

// MARK: - Import Error

enum GameImportError: LocalizedError, Sendable {
    case securityScopeDenied(String)
    case unsupportedFormat(String)
    case missingBinFiles(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .securityScopeDenied(let name):
            return "Izin akses keamanan iOS ditolak untuk file \(name)."
        case .unsupportedFormat(let ext):
            return "Format file '.\(ext)' tidak didukung. Gunakan ISO, BIN/CUE, atau CHD."
        case .missingBinFiles(let cueName):
            return "File .bin pasangan untuk '\(cueName)' tidak ditemukan. Pilih file .cue dan .bin secara bersamaan."
        case .copyFailed(let reason):
            return "Gagal menyalin file ke library: \(reason)"
        }
    }
}

// MARK: - GameLibraryManager

@MainActor
final class GameLibraryManager: ObservableObject {
    @Published var games: [GameEntry] = []
    @Published var collections: [GameCollection] = []
    @Published var detectedBIOSFiles: [URL] = []
    @Published var isImporting: Bool = false
    @Published var importStatusMessage: String = ""
    @Published var lastImportError: String?

    nonisolated static let supportedGameExtensions: Set<String> = ["iso", "bin", "cue", "chd", "gz", "cso"]
    nonisolated static let supportedBIOSExtensions: Set<String> = ["bin", "rom", "nvm", "mec"]

    nonisolated static let biosPlaceholderFileName = "put your bios here.txt"
    nonisolated static let gamesPlaceholderFileName = "put your iso here.txt"

    // MARK: - Public Sandbox Directories (Visible in iOS Files App: On My iPhone -> OREO-PS2)

    nonisolated static var documentsDirectoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    nonisolated static var biosDirectoryURL: URL {
        documentsDirectoryURL.appendingPathComponent("bios", isDirectory: true)
    }

    nonisolated static var gamesDirectoryURL: URL {
        documentsDirectoryURL.appendingPathComponent("games", isDirectory: true)
    }

    // MARK: - Internal Metadata & Legacy Fallback Directories

    nonisolated static var appSupportDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("OREO-PS2", isDirectory: true)
    }

    nonisolated static var legacyGamesDirectoryURL: URL {
        appSupportDirectoryURL.appendingPathComponent("Games", isDirectory: true)
    }

    nonisolated static var legacyBIOSDirectoryURL: URL {
        appSupportDirectoryURL.appendingPathComponent("BIOS", isDirectory: true)
    }

    private nonisolated static var libraryIndexURL: URL {
        appSupportDirectoryURL.appendingPathComponent("library.json")
    }

    private nonisolated static var collectionsIndexURL: URL {
        appSupportDirectoryURL.appendingPathComponent("collections.json")
    }

    init() {
        Self.ensureDirectoriesExist()
        loadLibrary()
        rescanFolders()
    }

    // MARK: - Directory Setup & Empty Marker Files

    nonisolated static func ensureDirectoriesExist() {
        let fm = FileManager.default
        try? fm.createDirectory(at: documentsDirectoryURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: biosDirectoryURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: gamesDirectoryURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: appSupportDirectoryURL, withIntermediateDirectories: true)

        let biosMarkerURL = biosDirectoryURL.appendingPathComponent(biosPlaceholderFileName)
        if !fm.fileExists(atPath: biosMarkerURL.path) {
            fm.createFile(atPath: biosMarkerURL.path, contents: Data(), attributes: nil)
        }

        let gamesMarkerURL = gamesDirectoryURL.appendingPathComponent(gamesPlaceholderFileName)
        if !fm.fileExists(atPath: gamesMarkerURL.path) {
            fm.createFile(atPath: gamesMarkerURL.path, contents: Data(), attributes: nil)
        }
    }

    // MARK: - Automatic Folder Scanner (Reads Manual & Imported BIOS + Game Files)

    /// Scans `Documents/bios` and `Documents/games` (plus legacy folders) so files dropped via iOS Files app are detected automatically.
    func rescanFolders() {
        Self.ensureDirectoriesExist()

        let scannedBIOS = Self.scanBIOSFilesOnDisk()
        self.detectedBIOSFiles = scannedBIOS

        let scannedGameURLs = Self.scanGameFilesOnDisk()
        var updatedGames = games.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        var knownLowerNames = Set(updatedGames.map { $0.fileName.lowercased() })

        var didChange = (updatedGames.count != games.count)

        for fileURL in scannedGameURLs {
            let key = fileURL.lastPathComponent.lowercased()
            if !knownLowerNames.contains(key) {
                let entry = GameEntry(url: fileURL)
                updatedGames.insert(entry, at: 0)
                knownLowerNames.insert(key)
                didChange = true
            }
        }

        if didChange {
            self.games = updatedGames
            saveLibrary()
        }
    }

    /// Scans for valid PS2 BIOS dumps while ignoring `put your bios here.txt`.
    nonisolated static func scanBIOSFilesOnDisk() -> [URL] {
        ensureDirectoriesExist()
        let fm = FileManager.default
        let searchDirs = [biosDirectoryURL, documentsDirectoryURL, legacyBIOSDirectoryURL]
        var found: [URL] = []
        var seenNames: Set<String> = []

        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in items {
                let name = url.lastPathComponent
                let lowerName = name.lowercased()

                // Ignore empty marker .txt files
                if lowerName == biosPlaceholderFileName || lowerName == gamesPlaceholderFileName || lowerName.hasSuffix(".txt") {
                    continue
                }

                let ext = url.pathExtension.lowercased()
                guard supportedBIOSExtensions.contains(ext) else { continue }

                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }

                // PS2 BIOS ROMs are typically 512 KB or 4 MB (nvm/mec companion files are smaller)
                let size = values?.fileSize ?? 0
                let isCompanion = (ext == "nvm" || ext == "mec")
                guard isCompanion || size >= 256_000 else { continue }

                if !seenNames.contains(lowerName) {
                    seenNames.insert(lowerName)
                    found.append(url)
                }
            }
        }

        // Prioritize primary BIOS ROM (.bin/.rom >= 256 KB) first, especially scph* files
        return found.sorted { lhs, rhs in
            let lName = lhs.lastPathComponent.lowercased()
            let rName = rhs.lastPathComponent.lowercased()
            let lIsMain = (lhs.pathExtension.lowercased() == "bin" || lhs.pathExtension.lowercased() == "rom")
            let rIsMain = (rhs.pathExtension.lowercased() == "bin" || rhs.pathExtension.lowercased() == "rom")
            if lIsMain != rIsMain { return lIsMain && !rIsMain }
            let lScph = lName.contains("scph")
            let rScph = rName.contains("scph")
            if lScph != rScph { return lScph && !rScph }
            return lName < rName
        }
    }

    /// Scans `Documents/games` (and legacy folder) for ISO, CHD, CSO, GZ, and BIN/CUE images while ignoring `put your iso here.txt`.
    nonisolated static func scanGameFilesOnDisk() -> [URL] {
        ensureDirectoriesExist()
        let fm = FileManager.default
        let searchDirs = [gamesDirectoryURL, legacyGamesDirectoryURL]
        var allCandidates: [URL] = []
        var seenNames: Set<String> = []

        for dir in searchDirs {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in items {
                let lowerName = url.lastPathComponent.lowercased()
                if lowerName == gamesPlaceholderFileName || lowerName == biosPlaceholderFileName || lowerName.hasSuffix(".txt") {
                    continue
                }

                let ext = url.pathExtension.lowercased()
                guard supportedGameExtensions.contains(ext) else { continue }

                let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isRegular else { continue }

                if !seenNames.contains(lowerName) {
                    seenNames.insert(lowerName)
                    allCandidates.append(url)
                }
            }
        }

        // Collect all .bin filenames referenced by .cue sheets so multi-track .bin files are not listed as duplicate games
        var referencedBins: Set<String> = []
        for url in allCandidates where url.pathExtension.lowercased() == "cue" {
            for binName in parseBinFilenames(inCueAt: url) {
                referencedBins.insert(binName.lowercased())
            }
        }

        return allCandidates.filter { url in
            if url.pathExtension.lowercased() == "bin" {
                return !referencedBins.contains(url.lastPathComponent.lowercased())
            }
            return true
        }
    }

    /// Copies a BIOS file into `Documents/bios` if it came from an external picker location, or stages a temporary copy if already inside `Documents/bios` so `EmulatorState.importBIOS(from:)` never collides with itself.
    nonisolated static func prepareBIOSForEmulator(from sourceURL: URL) throws -> (url: URL, isTemporary: Bool) {
        ensureDirectoriesExist()
        let fm = FileManager.default
        let destURL = biosDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)

        if sourceURL.standardizedFileURL == destURL.standardizedFileURL {
            let tempURL = fm.temporaryDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if fm.fileExists(atPath: tempURL.path) {
                try? fm.removeItem(at: tempURL)
            }
            try fm.copyItem(at: sourceURL, to: tempURL)
            return (tempURL, true)
        } else {
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }
            try coordinatedCopy(from: sourceURL, to: destURL)
            return (destURL, false)
        }
    }

    // MARK: - Persistence

    func loadLibrary() {
        Self.ensureDirectoriesExist()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: Self.libraryIndexURL),
           let decoded = try? decoder.decode([GameEntry].self, from: data) {
            self.games = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        }

        if let colData = try? Data(contentsOf: Self.collectionsIndexURL),
           let decodedCols = try? decoder.decode([GameCollection].self, from: colData) {
            self.collections = decodedCols
        }
    }

    func saveLibrary() {
        Self.ensureDirectoriesExist()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(games) {
            try? data.write(to: Self.libraryIndexURL, options: .atomic)
        }
        if let colData = try? encoder.encode(collections) {
            try? colData.write(to: Self.collectionsIndexURL, options: .atomic)
        }
    }

    // MARK: - Game Library Mutations

    func toggleFavorite(_ game: GameEntry) {
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[idx].isFavorite.toggle()
        saveLibrary()
    }

    func markPlayed(_ game: GameEntry) {
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[idx].lastPlayedDate = Date()
        saveLibrary()
    }

    func updateLastPlayed(_ game: GameEntry) {
        markPlayed(game)
    }

    func renameGame(_ game: GameEntry, newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[idx].title = trimmed
        saveLibrary()
    }

    func assignGame(_ game: GameEntry, to collection: GameCollection?) {
        guard let idx = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[idx].collectionID = collection?.id
        saveLibrary()
    }

    func isGame(_ game: GameEntry, in collection: GameCollection) -> Bool {
        if let current = games.first(where: { $0.id == game.id }) {
            return current.collectionID == collection.id
        }
        return game.collectionID == collection.id
    }

    func deleteGame(_ game: GameEntry) {
        let url = game.fileURL
        try? FileManager.default.removeItem(at: url)

        if url.pathExtension.lowercased() == "cue" {
            let referencedBins = Self.parseBinFilenames(inCueAt: url)
            for binName in referencedBins {
                let binURL = Self.gamesDirectoryURL.appendingPathComponent(binName)
                try? FileManager.default.removeItem(at: binURL)
            }
        }

        games.removeAll { $0.id == game.id }
        saveLibrary()
    }

    @discardableResult
    func createCollection(name: String, colorIndex: Int = 0) -> GameCollection? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collection = GameCollection(name: trimmed, colorIndex: colorIndex)
        collections.append(collection)
        saveLibrary()
        return collection
    }

    func deleteCollection(_ collection: GameCollection) {
        for index in games.indices where games[index].collectionID == collection.id {
            games[index].collectionID = nil
        }
        collections.removeAll { $0.id == collection.id }
        saveLibrary()
    }

    // MARK: - Async Import Pipeline (Swift 6 Safe)

    func importGames(from pickedURLs: [URL]) async {
        guard !pickedURLs.isEmpty else { return }
        isImporting = true
        lastImportError = nil
        importStatusMessage = "Menyalin game ke folder games..."

        defer {
            isImporting = false
            importStatusMessage = ""
        }

        do {
            let importedEntries = try await Task.detached(priority: .userInitiated) {
                try Self.processPickedURLs(pickedURLs)
            }.value

            for entry in importedEntries {
                if let existingIdx = games.firstIndex(where: { $0.fileName.lowercased() == entry.fileName.lowercased() }) {
                    games[existingIdx] = entry
                } else {
                    games.insert(entry, at: 0)
                }
            }
            saveLibrary()
        } catch {
            lastImportError = error.localizedDescription
        }
    }

    // MARK: - Nonisolated File Operations

    private nonisolated static func processPickedURLs(_ urls: [URL]) throws -> [GameEntry] {
        ensureDirectoriesExist()

        var accessedURLs: [URL] = []
        for url in urls {
            if url.startAccessingSecurityScopedResource() {
                accessedURLs.append(url)
            }
        }
        defer {
            for url in accessedURLs {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let cueURLs = urls.filter { $0.pathExtension.lowercased() == "cue" }
        let binURLs = urls.filter { $0.pathExtension.lowercased() == "bin" }
        let directDiscURLs = urls.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "iso" || ext == "chd" || ext == "gz" || ext == "cso"
        }

        var results: [GameEntry] = []

        var consumedBinNames: Set<String> = []
        for cueURL in cueURLs {
            let entry = try copyCUE(cueURL: cueURL, availableBins: binURLs)
            results.append(entry)
            for binName in parseBinFilenames(inCueAt: entry.fileURL) {
                consumedBinNames.insert(binName.lowercased())
            }
        }

        for binURL in binURLs where !consumedBinNames.contains(binURL.lastPathComponent.lowercased()) {
            let destURL = try copyISO(from: binURL)
            results.append(GameEntry(url: destURL))
        }

        for discURL in directDiscURLs {
            let ext = discURL.pathExtension.lowercased()
            guard supportedGameExtensions.contains(ext) else {
                throw GameImportError.unsupportedFormat(ext)
            }
            let destURL = try copyISO(from: discURL)
            results.append(GameEntry(url: destURL))
        }

        if results.isEmpty, let first = urls.first {
            throw GameImportError.unsupportedFormat(first.pathExtension)
        }

        return results
    }

    nonisolated static func copyISO(from sourceURL: URL) throws -> URL {
        ensureDirectoriesExist()
        let destURL = gamesDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent)
        if sourceURL.standardizedFileURL != destURL.standardizedFileURL {
            try coordinatedCopy(from: sourceURL, to: destURL)
        }
        return destURL
    }

    nonisolated static func copyCUE(cueURL: URL, availableBins: [URL]) throws -> GameEntry {
        ensureDirectoriesExist()
        let destCueURL = gamesDirectoryURL.appendingPathComponent(cueURL.lastPathComponent)
        if cueURL.standardizedFileURL != destCueURL.standardizedFileURL {
            try coordinatedCopy(from: cueURL, to: destCueURL)
        }

        let expectedBins = parseBinFilenames(inCueAt: destCueURL)
        let sourceDir = cueURL.deletingLastPathComponent()

        for expectedBinName in expectedBins {
            let destBinURL = gamesDirectoryURL.appendingPathComponent(expectedBinName)

            if let matchedPickedBin = availableBins.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare(expectedBinName) == .orderedSame
            }) {
                if matchedPickedBin.standardizedFileURL != destBinURL.standardizedFileURL {
                    try coordinatedCopy(from: matchedPickedBin, to: destBinURL)
                }
            } else {
                let siblingURL = sourceDir.appendingPathComponent(expectedBinName)
                if FileManager.default.fileExists(atPath: siblingURL.path) {
                    if siblingURL.standardizedFileURL != destBinURL.standardizedFileURL {
                        try coordinatedCopy(from: siblingURL, to: destBinURL)
                    }
                } else if !FileManager.default.fileExists(atPath: destBinURL.path) {
                    throw GameImportError.missingBinFiles(cueURL.lastPathComponent)
                }
            }
        }

        return GameEntry(url: destCueURL)
    }

    nonisolated static func coordinatedCopy(from sourceURL: URL, to destinationURL: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinatorError) { coordinatedURL in
            do {
                let fm = FileManager.default
                if fm.fileExists(atPath: destinationURL.path) {
                    try fm.removeItem(at: destinationURL)
                }
                try fm.copyItem(at: coordinatedURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let coordinatorError {
            throw GameImportError.copyFailed(coordinatorError.localizedDescription)
        }
        if let copyError {
            throw GameImportError.copyFailed(copyError.localizedDescription)
        }
    }

    nonisolated static func parseBinFilenames(inCueAt cueURL: URL) -> [String] {
        guard let content = (try? String(contentsOf: cueURL, encoding: .utf8))
            ?? (try? String(contentsOf: cueURL, encoding: .ascii)) else {
            return []
        }

        var bins: [String] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.uppercased().hasPrefix("FILE ") else { continue }
            if let firstQuote = trimmed.firstIndex(of: "\""),
               let lastQuote = trimmed[trimmed.index(after: firstQuote)...].firstIndex(of: "\"") {
                let rawName = String(trimmed[trimmed.index(after: firstQuote)..<lastQuote])
                let fileName = URL(fileURLWithPath: rawName).lastPathComponent
                if !fileName.isEmpty {
                    bins.append(fileName)
                }
            }
        }
        return bins
    }

    // MARK: - Disc ID & Title Metadata Lookup

    nonisolated static func extractDiscID(from url: URL) -> String {
        let pattern = #"(SLUS|SCUS|SLES|SCES|SLPM|SLPS|SCPS|SLAJ|SCAJ|SLKA|SCKA)[-_]?(\d{3})\.?(\d{2})"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)

        let filename = url.lastPathComponent
        if let match = regex?.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
           let prefixRange = Range(match.range(at: 1), in: filename),
           let part1Range = Range(match.range(at: 2), in: filename),
           let part2Range = Range(match.range(at: 3), in: filename) {
            return "\(filename[prefixRange].uppercased())-\(filename[part1Range])\(filename[part2Range])"
        }

        let ext = url.pathExtension.lowercased()
        if (ext == "iso" || ext == "bin"),
           let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let headerData = try? handle.read(upToCount: 524_288),
               let ascii = String(data: headerData, encoding: .ascii) {
                if let match = regex?.firstMatch(in: ascii, range: NSRange(ascii.startIndex..., in: ascii)),
                   let prefixRange = Range(match.range(at: 1), in: ascii),
                   let part1Range = Range(match.range(at: 2), in: ascii),
                   let part2Range = Range(match.range(at: 3), in: ascii) {
                    return "\(ascii[prefixRange].uppercased())-\(ascii[part1Range])\(ascii[part2Range])"
                }
            }
        }

        return "PS2-DISC"
    }

    nonisolated static func region(for discID: String) -> String {
        let upper = discID.uppercased()
        if upper.hasPrefix("SLUS") || upper.hasPrefix("SCUS") {
            return "NTSC-U"
        } else if upper.hasPrefix("SLES") || upper.hasPrefix("SCES") {
            return "PAL"
        } else if upper.hasPrefix("SLPM") || upper.hasPrefix("SLPS") || upper.hasPrefix("SCPS")
                    || upper.hasPrefix("SLAJ") || upper.hasPrefix("SCAJ") {
            return "NTSC-J"
        } else if upper.hasPrefix("SLKA") || upper.hasPrefix("SCKA") {
            return "NTSC-K"
        }
        return "PS2"
    }

    nonisolated static let titleLookup: [String: String] = [
        "SLUS-20062": "Crazy Taxi",
        "SLUS-20202": "Grand Theft Auto III",
        "SLUS-20552": "Grand Theft Auto: Vice City",
        "SLUS-20946": "Grand Theft Auto: San Andreas",
        "SLUS-20312": "Final Fantasy X",
        "SLUS-20672": "Final Fantasy X-2",
        "SLUS-20963": "Final Fantasy XII",
        "SLUS-20370": "Kingdom Hearts",
        "SLUS-21005": "Kingdom Hearts II",
        "SCUS-97328": "Gran Turismo 4",
        "SCUS-97102": "Gran Turismo 3: A-Spec",
        "SCUS-97399": "God of War",
        "SCUS-97481": "God of War II",
        "SCUS-97472": "Shadow of the Colossus",
        "SLUS-20144": "Metal Gear Solid 2: Sons of Liberty",
        "SLUS-20915": "Metal Gear Solid 3: Snake Eater",
        "SLUS-20216": "Devil May Cry",
        "SLUS-20964": "Devil May Cry 3: Dante's Awakening",
        "SLUS-21113": "Resident Evil 4",
        "SLUS-20454": "Tekken 4",
        "SLUS-21059": "Tekken 5",
        "SLUS-21678": "Persona 4",
        "SLUS-21621": "Persona 3 FES",
        "SLUS-20751": "Need for Speed: Underground",
        "SLUS-21065": "Need for Speed: Underground 2",
        "SLUS-21267": "Need for Speed: Most Wanted",
        "SLUS-20851": "Burnout 3: Takedown",
        "SLUS-21171": "Bully",
        "SLUS-20787": "Dragon Ball Z: Budokai Tenkaichi 3",
        "SLUS-21441": "Okami"
    ]
}
