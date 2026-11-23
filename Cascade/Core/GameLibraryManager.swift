import Foundation
import SwiftUI
import UIKit
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
    var totalPlayTime: TimeInterval
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

    /// Alias compatibility for views expecting `game.lastPlayed`
    var lastPlayed: Date? {
        get { lastPlayedDate }
        set { lastPlayedDate = newValue }
    }

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
        case "NTSC-K", "KOR", "KR":
            return "NTSC-K"
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
        totalPlayTime: TimeInterval = 0,
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
        self.totalPlayTime = totalPlayTime
        self.isFavorite = isFavorite
        self.collectionID = collectionID
    }

    enum CodingKeys: String, CodingKey {
        case id, title, discID, region, fileName, fileSize, addedDate, lastPlayedDate, totalPlayTime, isFavorite, collectionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        discID = try c.decodeIfPresent(String.self, forKey: .discID) ?? "PS2-DISC"
        region = try c.decodeIfPresent(String.self, forKey: .region) ?? "PS2"
        fileName = try c.decode(String.self, forKey: .fileName)
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        addedDate = try c.decodeIfPresent(Date.self, forKey: .addedDate) ?? Date()
        lastPlayedDate = try c.decodeIfPresent(Date.self, forKey: .lastPlayedDate)
        totalPlayTime = try c.decodeIfPresent(TimeInterval.self, forKey: .totalPlayTime) ?? 0
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        collectionID = try c.decodeIfPresent(UUID.self, forKey: .collectionID)
    }

    init(url: URL) {
        let extractedID = GameLibraryManager.extractDiscID(from: url)
        let resolvedRegion = GameLibraryManager.region(for: extractedID)
        let cleanStem = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = GameLibraryManager.titleLookup[extractedID] ?? (cleanStem.isEmpty ? "PlayStation 2 Disc" : cleanStem)
        let size = GameLibraryManager.computeDiscTotalSize(at: url)

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

    var color: Color { accentColor }
    var icon: String { "folder.fill" }
    var systemImage: String { "folder.fill" }
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

// MARK: - GameCoverCache (Automatic Box-Art Downloader + Disk/Memory Cache)

@MainActor
final class GameCoverCache: ObservableObject {
    static let shared = GameCoverCache()

    @Published private(set) var revision: Int = 0

    private let memoryCache = NSCache<NSString, UIImage>()
    private var inFlightKeys: Set<String> = []
    private var failedKeys: Set<String> = []

    nonisolated static var coversDirectoryURL: URL {
        GameLibraryManager.appSupportDirectoryURL.appendingPathComponent("Covers", isDirectory: true)
    }

    private init() {
        memoryCache.countLimit = 120
        try? FileManager.default.createDirectory(at: Self.coversDirectoryURL, withIntermediateDirectories: true)
    }

    func coverImage(for game: GameEntry) -> UIImage? {
        let customKey = "custom_\(game.id.uuidString)" as NSString
        if let cached = memoryCache.object(forKey: customKey) {
            return cached
        }
        let customURL = Self.customCoverURL(for: game.id)
        if let img = UIImage(contentsOfFile: customURL.path) {
            memoryCache.setObject(img, forKey: customKey)
            return img
        }

        // Check sidecar image placed in Documents/games (e.g. GameTitle.jpg / SLUS-20062.png)
        let sidecarKey = "sidecar_\(game.fileName.lowercased())" as NSString
        if let cachedSidecar = memoryCache.object(forKey: sidecarKey) {
            return cachedSidecar
        }
        if let sidecarURL = Self.findSidecarCoverURL(for: game),
           let sidecarImg = UIImage(contentsOfFile: sidecarURL.path) {
            memoryCache.setObject(sidecarImg, forKey: sidecarKey)
            return sidecarImg
        }

        let serial = Self.normalizedSerial(game.discID)
        guard !serial.isEmpty else { return nil }

        let serialKey = serial as NSString
        if let cached = memoryCache.object(forKey: serialKey) {
            return cached
        }

        let diskURL = Self.serialCoverURL(for: serial)
        if let diskImg = UIImage(contentsOfFile: diskURL.path) {
            memoryCache.setObject(diskImg, forKey: serialKey)
            return diskImg
        }

        return nil
    }

    func hasCustomCover(for game: GameEntry) -> Bool {
        FileManager.default.fileExists(atPath: Self.customCoverURL(for: game.id).path)
    }

    func setCustomCover(_ image: UIImage, for game: GameEntry) {
        try? FileManager.default.createDirectory(at: Self.coversDirectoryURL, withIntermediateDirectories: true)
        let resized = Self.downscaleImage(image, maxDimension: 600)
        if let jpegData = resized.jpegData(compressionQuality: 0.86) {
            let dest = Self.customCoverURL(for: game.id)
            try? jpegData.write(to: dest, options: .atomic)
            memoryCache.setObject(resized, forKey: "custom_\(game.id.uuidString)" as NSString)
            revision &+= 1
        }
    }

    func removeCustomCover(for game: GameEntry) {
        let dest = Self.customCoverURL(for: game.id)
        try? FileManager.default.removeItem(at: dest)
        memoryCache.removeObject(forKey: "custom_\(game.id.uuidString)" as NSString)
        revision &+= 1
    }

    func fetchCoverIfNeeded(for game: GameEntry) {
        if coverImage(for: game) != nil { return }
        let serial = Self.normalizedSerial(game.discID)
        guard !serial.isEmpty else { return }
        guard !inFlightKeys.contains(serial), !failedKeys.contains(serial) else { return }

        inFlightKeys.insert(serial)

        Task { [weak self] in
            let fetched = await Self.downloadCoverFromRepositories(serial: serial)
            guard let self else { return }
            self.inFlightKeys.remove(serial)
            if let image = fetched {
                self.memoryCache.setObject(image, forKey: serial as NSString)
                self.revision &+= 1
            } else {
                self.failedKeys.insert(serial)
            }
        }
    }

    private nonisolated static func downloadCoverFromRepositories(serial: String) async -> UIImage? {
        let candidateURLs: [URL] = [
            URL(string: "https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/default/\(serial).jpg"),
            URL(string: "https://raw.githubusercontent.com/xlenore/ps2-covers/main/covers/3d/\(serial).png")
        ].compactMap { $0 }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)

        for url in candidateURLs {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      data.count > 1024,
                      let rawImage = UIImage(data: data) else {
                    continue
                }
                let scaled = downscaleImage(rawImage, maxDimension: 512)
                try? FileManager.default.createDirectory(at: coversDirectoryURL, withIntermediateDirectories: true)
                if let jpegData = scaled.jpegData(compressionQuality: 0.85) {
                    try? jpegData.write(to: serialCoverURL(for: serial), options: .atomic)
                }
                return scaled
            } catch {
                continue
            }
        }
        return nil
    }

    private nonisolated static func downscaleImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let targetSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    nonisolated static func normalizedSerial(_ discID: String) -> String {
        let trimmed = discID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.range(of: #"^[A-Z]{4}-\d{5}$"#, options: .regularExpression) != nil else {
            return ""
        }
        return trimmed
    }

    nonisolated static func serialCoverURL(for serial: String) -> URL {
        coversDirectoryURL.appendingPathComponent("\(serial).jpg")
    }

    nonisolated static func customCoverURL(for gameID: UUID) -> URL {
        coversDirectoryURL.appendingPathComponent("custom_\(gameID.uuidString).jpg")
    }

    nonisolated static func findSidecarCoverURL(for game: GameEntry) -> URL? {
        let fm = FileManager.default
        let stem = URL(fileURLWithPath: game.fileName).deletingPathExtension().lastPathComponent
        let serial = normalizedSerial(game.discID)
        let imageExts = ["jpg", "jpeg", "png", "webp"]
        let dirs = [GameLibraryManager.gamesDirectoryURL, GameLibraryManager.legacyGamesDirectoryURL]

        for dir in dirs {
            for ext in imageExts {
                let byStem = dir.appendingPathComponent("\(stem).\(ext)")
                if fm.fileExists(atPath: byStem.path) { return byStem }
                if !serial.isEmpty {
                    let bySerial = dir.appendingPathComponent("\(serial).\(ext)")
                    if fm.fileExists(atPath: bySerial.path) { return bySerial }
                }
            }
        }
        return nil
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

    func rescanFolders() {
        Self.ensureDirectoriesExist()

        let scannedBIOS = Self.scanBIOSFilesOnDisk()
        self.detectedBIOSFiles = scannedBIOS

        let scannedGameURLs = Self.scanGameFilesOnDisk()
        var updatedGames = Self.deduplicateCueBinEntries(
            in: games.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        )
        var didChange = (updatedGames.count != games.count)

        // Refresh metadata for existing entries that still have placeholder discID or cue-only fileSize
        for idx in updatedGames.indices {
            let entry = updatedGames[idx]
            let url = entry.fileURL
            if entry.discID == "PS2-DISC" || entry.discID == "UNKNOWN" {
                let extracted = Self.extractDiscID(from: url)
                if extracted != "PS2-DISC" {
                    updatedGames[idx].discID = extracted
                    updatedGames[idx].region = Self.region(for: extracted)
                    if let mappedTitle = Self.titleLookup[extracted] {
                        updatedGames[idx].title = mappedTitle
                    }
                    didChange = true
                }
            }
            let totalSize = Self.computeDiscTotalSize(at: url)
            if totalSize > 0 && updatedGames[idx].fileSize != totalSize {
                updatedGames[idx].fileSize = totalSize
                didChange = true
            }
        }

        var knownLowerNames = Set(updatedGames.map { $0.fileName.lowercased() })

        for fileURL in scannedGameURLs {
            let key = fileURL.lastPathComponent.lowercased()
            if !knownLowerNames.contains(key) {
                let entry = GameEntry(url: fileURL)
                updatedGames.insert(entry, at: 0)
                knownLowerNames.insert(key)
                didChange = true
            }
        }

        let finalGames = Self.deduplicateCueBinEntries(in: updatedGames)
        if finalGames.count != updatedGames.count {
            didChange = true
        }

        if didChange {
            self.games = finalGames
            saveLibrary()
        }

        for game in self.games {
            GameCoverCache.shared.fetchCoverIfNeeded(for: game)
        }
    }

    /// Ensures any `.bin` file paired with a `.cue` sheet (either by CUE `FILE` reference or matching filename stem)
    /// is never shown as a duplicate entry alongside the `.cue` entry.
    nonisolated static func deduplicateCueBinEntries(in entries: [GameEntry]) -> [GameEntry] {
        var referencedBins: Set<String> = []
        var cueStems: Set<String> = []

        var allCueURLs: [URL] = entries
            .filter { URL(fileURLWithPath: $0.fileName).pathExtension.lowercased() == "cue" }
            .map { $0.fileURL }

        let fm = FileManager.default
        for dir in [gamesDirectoryURL, legacyGamesDirectoryURL] {
            if let diskItems = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for url in diskItems where url.pathExtension.lowercased() == "cue" {
                    allCueURLs.append(url)
                }
            }
        }

        for cueURL in allCueURLs {
            let stem = cueURL.deletingPathExtension().lastPathComponent.lowercased()
            if !stem.isEmpty {
                cueStems.insert(stem)
            }
            for binName in parseBinFilenames(inCueAt: cueURL) {
                referencedBins.insert(binName.lowercased())
            }
        }

        var seenFileNames: Set<String> = []
        var filtered: [GameEntry] = []

        for entry in entries {
            let lowerName = entry.fileName.lowercased()
            guard !seenFileNames.contains(lowerName) else { continue }

            let url = URL(fileURLWithPath: entry.fileName)
            if url.pathExtension.lowercased() == "bin" {
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                if referencedBins.contains(lowerName) || cueStems.contains(stem) {
                    continue
                }
            }

            seenFileNames.insert(lowerName)
            filtered.append(entry)
        }

        return filtered
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

                if lowerName == biosPlaceholderFileName || lowerName == gamesPlaceholderFileName || lowerName.hasSuffix(".txt") {
                    continue
                }

                let ext = url.pathExtension.lowercased()
                guard supportedBIOSExtensions.contains(ext) else { continue }

                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true else { continue }

                let size = values?.fileSize ?? 0
                let isCompanion = (ext == "nvm" || ext == "mec")
                guard isCompanion || size >= 256_000 else { continue }

                if !seenNames.contains(lowerName) {
                    seenNames.insert(lowerName)
                    found.append(url)
                }
            }
        }

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

        var referencedBins: Set<String> = []
        var cueStems: Set<String> = []
        for url in allCandidates where url.pathExtension.lowercased() == "cue" {
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if !stem.isEmpty {
                cueStems.insert(stem)
            }
            for binName in parseBinFilenames(inCueAt: url) {
                referencedBins.insert(binName.lowercased())
            }
        }

        return allCandidates.filter { url in
            if url.pathExtension.lowercased() == "bin" {
                let lowerName = url.lastPathComponent.lowercased()
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                return !referencedBins.contains(lowerName) && !cueStems.contains(stem)
            }
            return true
        }
    }

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
            let existing = decoded.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
            self.games = Self.deduplicateCueBinEntries(in: existing)
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

    func toggleGame(_ game: GameEntry, in collection: GameCollection) {
        if isGame(game, in: collection) {
            assignGame(game, to: nil)
        } else {
            assignGame(game, to: collection)
        }
    }

    func toggle(_ game: GameEntry, in collection: GameCollection) {
        toggleGame(game, in: collection)
    }

    func addGame(_ game: GameEntry, to collection: GameCollection) {
        assignGame(game, to: collection)
    }

    func removeGame(_ game: GameEntry, from collection: GameCollection) {
        if isGame(game, in: collection) {
            assignGame(game, to: nil)
        }
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
            let matchingStemBin = Self.gamesDirectoryURL
                .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("bin")
            try? FileManager.default.removeItem(at: matchingStemBin)
        }

        GameCoverCache.shared.removeCustomCover(for: game)
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
            games = Self.deduplicateCueBinEntries(in: games)
            saveLibrary()

            for entry in games {
                GameCoverCache.shared.fetchCoverIfNeeded(for: entry)
            }
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
        var cueStems: Set<String> = []
        for cueURL in cueURLs {
            let stem = cueURL.deletingPathExtension().lastPathComponent.lowercased()
            if !stem.isEmpty {
                cueStems.insert(stem)
            }
            let entry = try copyCUE(cueURL: cueURL, availableBins: binURLs)
            results.append(entry)
            for binName in parseBinFilenames(inCueAt: entry.fileURL) {
                consumedBinNames.insert(binName.lowercased())
            }
        }

        // Only treat a .bin as standalone if it is NOT referenced by any .cue and does not share a stem with a .cue
        for binURL in binURLs {
            let lowerBinName = binURL.lastPathComponent.lowercased()
            let binStem = binURL.deletingPathExtension().lastPathComponent.lowercased()
            if consumedBinNames.contains(lowerBinName) || cueStems.contains(binStem) {
                continue
            }
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

        var expectedBins = parseBinFilenames(inCueAt: destCueURL)
        let cueStem = cueURL.deletingPathExtension().lastPathComponent
        if expectedBins.isEmpty {
            expectedBins = ["\(cueStem).bin"]
        }

        let sourceDir = cueURL.deletingLastPathComponent()

        for expectedBinName in expectedBins {
            let destBinURL = gamesDirectoryURL.appendingPathComponent(expectedBinName)

            if let matchedPickedBin = availableBins.first(where: {
                $0.lastPathComponent.caseInsensitiveCompare(expectedBinName) == .orderedSame
            }) {
                if matchedPickedBin.standardizedFileURL != destBinURL.standardizedFileURL {
                    try coordinatedCopy(from: matchedPickedBin, to: destBinURL)
                }
            } else if availableBins.count == 1 && expectedBins.count == 1,
                      let singleBin = availableBins.first,
                      singleBin.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(cueStem) == .orderedSame {
                if singleBin.standardizedFileURL != destBinURL.standardizedFileURL {
                    try coordinatedCopy(from: singleBin, to: destBinURL)
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

    /// Parses `.bin` filenames from a `.cue` sheet (supports quoted paths, unquoted paths, tabs, and Windows `\` separators).
    nonisolated static func parseBinFilenames(inCueAt cueURL: URL) -> [String] {
        guard let content = (try? String(contentsOf: cueURL, encoding: .utf8))
            ?? (try? String(contentsOf: cueURL, encoding: .ascii)) else {
            return []
        }

        var bins: [String] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let upper = trimmed.uppercased()
            guard upper.hasPrefix("FILE ") || upper.hasPrefix("FILE\t") else { continue }

            let afterKeyword = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let rawPath: String
            if afterKeyword.hasPrefix("\"") {
                let inner = afterKeyword.dropFirst()
                if let endQuote = inner.firstIndex(of: "\"") {
                    rawPath = String(inner[..<endQuote])
                } else {
                    continue
                }
            } else {
                rawPath = afterKeyword.components(separatedBy: .whitespaces).first ?? ""
            }

            let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
            let fileName = URL(fileURLWithPath: normalized).lastPathComponent
            if !fileName.isEmpty {
                bins.append(fileName)
            }
        }
        return bins
    }

    /// Computes the total size in bytes of a disc entry (for `.cue`, sums the `.cue` plus all referenced `.bin` files).
    nonisolated static func computeDiscTotalSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        let baseSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        guard url.pathExtension.lowercased() == "cue" else {
            return baseSize
        }

        var total = baseSize
        let dir = url.deletingLastPathComponent()
        var binNames = parseBinFilenames(inCueAt: url)
        if binNames.isEmpty {
            binNames = ["\(url.deletingPathExtension().lastPathComponent).bin"]
        }

        var counted: Set<String> = []
        for binName in binNames {
            let key = binName.lowercased()
            guard !counted.contains(key) else { continue }
            counted.insert(key)

            let binURL = dir.appendingPathComponent(binName)
            if fm.fileExists(atPath: binURL.path),
               let sz = (try? binURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ Int64($0) }) {
                total += sz
            }
        }
        return total
    }

    // MARK: - Disc ID & Title Metadata Lookup

    nonisolated static func extractDiscID(from url: URL) -> String {
        let pattern = #"(SLUS|SCUS|SLES|SCES|SLPM|SLPS|SCPS|SLAJ|SCAJ|SLKA|SCKA)[-_]?(\d{3})\.?(\d{2})"#
        let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)

        func matchSerial(in text: String) -> String? {
            guard let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let prefixRange = Range(match.range(at: 1), in: text),
                  let part1Range = Range(match.range(at: 2), in: text),
                  let part2Range = Range(match.range(at: 3), in: text) else {
                return nil
            }
            return "\(text[prefixRange].uppercased())-\(text[part1Range])\(text[part2Range])"
        }

        if let serial = matchSerial(in: url.lastPathComponent) {
            return serial
        }

        let ext = url.pathExtension.lowercased()
        let targetURL: URL
        if ext == "cue" {
            let dir = url.deletingLastPathComponent()
            let bins = parseBinFilenames(inCueAt: url)
            if let firstBin = bins.first {
                targetURL = dir.appendingPathComponent(firstBin)
            } else {
                targetURL = dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).bin")
            }
        } else {
            targetURL = url
        }

        let targetExt = targetURL.pathExtension.lowercased()
        if (targetExt == "iso" || targetExt == "bin"),
           let handle = try? FileHandle(forReadingFrom: targetURL) {
            defer { try? handle.close() }

            if let serialFromCNF = readSerialFromISO9660(handle: handle, matchSerial: matchSerial) {
                return serialFromCNF
            }

            try? handle.seek(toOffset: 0)
            if let headerData = try? handle.read(upToCount: 524_288),
               let ascii = String(data: headerData, encoding: .ascii),
               let serial = matchSerial(in: ascii) {
                return serial
            }
        }

        return "PS2-DISC"
    }

    private nonisolated static func readSerialFromISO9660(
        handle: FileHandle,
        matchSerial: (String) -> String?
    ) -> String? {
        let geometries: [(sectorSize: UInt64, dataOffset: UInt64)] = [
            (2048, 0),
            (2352, 24),
            (2352, 16)
        ]

        for geom in geometries {
            let pvdPos = 16 * geom.sectorSize + geom.dataOffset
            guard (try? handle.seek(toOffset: pvdPos)) != nil,
                  let pvd = try? handle.read(upToCount: 2048),
                  pvd.count >= 170,
                  pvd[0] == 0x01,
                  String(bytes: pvd[1...5], encoding: .ascii) == "CD001" else {
                continue
            }

            let rootLBA = pvd.withUnsafeBytes { $0.load(fromByteOffset: 158, as: UInt32.self).littleEndian }
            let rootSize = min(UInt32(65536), pvd.withUnsafeBytes { $0.load(fromByteOffset: 166, as: UInt32.self).littleEndian })
            guard rootLBA > 0, rootSize > 0 else { continue }

            let rootPos = UInt64(rootLBA) * geom.sectorSize + geom.dataOffset
            guard (try? handle.seek(toOffset: rootPos)) != nil,
                  let dirData = try? handle.read(upToCount: Int(rootSize)) else {
                continue
            }

            var off = 0
            while off + 33 < dirData.count {
                let recLen = Int(dirData[off])
                guard recLen > 0, off + recLen <= dirData.count else { break }
                let nameLen = Int(dirData[off + 32])
                if off + 33 + nameLen <= dirData.count {
                    var name = String(bytes: dirData[(off + 33)..<(off + 33 + nameLen)], encoding: .ascii) ?? ""
                    if let semi = name.firstIndex(of: ";") {
                        name = String(name[..<semi])
                    }
                    if name.uppercased() == "SYSTEM.CNF" {
                        let cnfLBA = dirData.withUnsafeBytes { $0.load(fromByteOffset: off + 2, as: UInt32.self).littleEndian }
                        let cnfSize = min(4096, Int(dirData.withUnsafeBytes { $0.load(fromByteOffset: off + 10, as: UInt32.self).littleEndian }))
                        let cnfPos = UInt64(cnfLBA) * geom.sectorSize + geom.dataOffset
                        if (try? handle.seek(toOffset: cnfPos)) != nil,
                           let cnfData = try? handle.read(upToCount: cnfSize),
                           let cnfText = String(data: cnfData, encoding: .ascii),
                           let serial = matchSerial(cnfText) {
                            return serial
                        }
                    }
                }
                off += recLen
            }
        }
        return nil
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
