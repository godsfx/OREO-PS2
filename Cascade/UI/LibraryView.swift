import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - UIKit Document Picker Presenter (Bypasses iOS 16 SwiftUI .fileImporter Bugs)

@MainActor
final class DocumentPickerPresenter: NSObject, ObservableObject, UIDocumentPickerDelegate {
    enum PickerMode {
        case game
        case bios
    }

    private var onPick: (([URL]) -> Void)?
    private var isPresenting = false

    func present(mode: PickerMode, onPick: @escaping ([URL]) -> Void) {
        guard !isPresenting else { return }
        self.onPick = onPick

        let contentTypes: [UTType]
        let allowsMultiple: Bool

        switch mode {
        case .game:
            let customExtensions = ["iso", "bin", "cue", "chd", "cso", "gz"]
            let customTypes = customExtensions.compactMap { UTType(filenameExtension: $0) }
            contentTypes = customTypes.isEmpty ? [.data, .item] : customTypes + [.data]
            allowsMultiple = true
        case .bios:
            let biosExtensions = ["bin", "rom", "nvm", "mec"]
            let customTypes = biosExtensions.compactMap { UTType(filenameExtension: $0) }
            contentTypes = customTypes.isEmpty ? [.data, .item] : customTypes + [.data]
            allowsMultiple = true
        }

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = allowsMultiple
        picker.shouldShowFileExtensions = true

        guard let topController = Self.topViewController() else {
            self.onPick = nil
            return
        }

        isPresenting = true
        DispatchQueue.main.async {
            topController.present(picker, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        isPresenting = false
        let callback = onPick
        onPick = nil
        callback?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        isPresenting = false
        onPick = nil
    }

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return nil
        }

        var current: UIViewController? = root
        while let presented = current?.presentedViewController {
            current = presented
        }
        return current
    }
}

// MARK: - LibraryView

struct LibraryView: View {
    @EnvironmentObject var emulatorState: EmulatorState
    @EnvironmentObject var libraryManager: GameLibraryManager
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var documentPicker = DocumentPickerPresenter()

    @State private var searchText: String = ""
    @State private var selectedFilter: LibraryFilter = .all
    @State private var selectedCollectionID: UUID?
    @State private var showBIOSRequiredAlert: Bool = false
    @State private var showNewCollectionSheet: Bool = false
    @State private var newCollectionName: String = ""
    @State private var newCollectionColorIndex: Int = 0
    @State private var gameToRename: GameEntry?
    @State private var renameText: String = ""

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All Games"
        case favorites = "Favorites"
        case recent = "Recent"

        var id: String { rawValue }
    }

    private var filteredGames: [GameEntry] {
        var result = libraryManager.games

        if let collectionID = selectedCollectionID {
            result = result.filter { $0.collectionID == collectionID }
        }

        switch selectedFilter {
        case .all:
            break
        case .favorites:
            result = result.filter { $0.isFavorite }
        case .recent:
            result = result
                .filter { $0.lastPlayedDate != nil }
                .sorted { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                || $0.discID.localizedCaseInsensitiveContains(query)
                || $0.region.localizedCaseInsensitiveContains(query)
            }
        }

        return result
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 158, maximum: 210), spacing: 14)
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.07, blue: 0.12),
                        Color(red: 0.08, green: 0.11, blue: 0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusHeaderCard

                        if let lastPlayed = emulatorState.lastPlayedGame {
                            continuePlayingBanner(for: lastPlayed)
                        }

                        filterAndCollectionsBar

                        if filteredGames.isEmpty {
                            emptyStateView
                        } else {
                            LazyVGrid(columns: gridColumns, spacing: 14) {
                                ForEach(filteredGames) { game in
                                    GameCardView(
                                        game: game,
                                        collection: libraryManager.collections.first(where: { $0.id == game.collectionID }),
                                        onLaunch: { handleLaunch(game) },
                                        onToggleFavorite: {
                                            triggerHaptic(.light)
                                            libraryManager.toggleFavorite(game)
                                        },
                                        onRename: {
                                            gameToRename = game
                                            renameText = game.title
                                        },
                                        onAssignCollection: { collection in
                                            libraryManager.assignGame(game, to: collection)
                                        },
                                        onDelete: {
                                            triggerHaptic(.medium)
                                            libraryManager.deleteGame(game)
                                        },
                                        collections: libraryManager.collections
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .refreshable {
                    syncFoldersAndBIOS(forceReloadBIOS: !emulatorState.biosLoaded)
                }

                if libraryManager.isImporting {
                    importingOverlay
                }
            }
            .navigationTitle("OREO-PS2")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search title, SLUS/SLES ID, region...")
            .onAppear {
                syncFoldersAndBIOS(forceReloadBIOS: !emulatorState.biosLoaded)
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .active {
                    syncFoldersAndBIOS(forceReloadBIOS: !emulatorState.biosLoaded)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            triggerGameImport()
                        } label: {
                            Label("Import Game (ISO / BIN+CUE / CHD)", systemImage: "opticaldisc")
                        }

                        Button {
                            triggerBIOSImport()
                        } label: {
                            Label("Import PS2 BIOS", systemImage: "cpu")
                        }

                        Button {
                            triggerHaptic(.light)
                            syncFoldersAndBIOS(forceReloadBIOS: true)
                        } label: {
                            Label("Rescan Folders (bios & games)", systemImage: "arrow.clockwise")
                        }

                        Divider()

                        Button {
                            newCollectionName = ""
                            newCollectionColorIndex = libraryManager.collections.count % GameCollection.palette.count
                            showNewCollectionSheet = true
                        } label: {
                            Label("New Collection", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color(red: 0.30, green: 0.62, blue: 1.0))
                    }
                }
            }
            .alert("PS2 BIOS Required", isPresented: $showBIOSRequiredAlert) {
                Button("Import BIOS Now") {
                    triggerBIOSImport()
                }
                Button("Rescan Folder") {
                    syncFoldersAndBIOS(forceReloadBIOS: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Taruh file BIOS PS2 (scph10000.bin / scph39001.bin / scph70012.bin) ke folder 'On My iPhone → OREO-PS2 → bios' atau tap Import BIOS Now.")
            }
            .alert(
                "Import Error",
                isPresented: Binding(
                    get: { libraryManager.lastImportError != nil },
                    set: { if !$0 { libraryManager.lastImportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(libraryManager.lastImportError ?? "")
            }
            .alert("Rename Game", isPresented: Binding(
                get: { gameToRename != nil },
                set: { if !$0 { gameToRename = nil } }
            )) {
                TextField("Game Title", text: $renameText)
                Button("Save") {
                    if let target = gameToRename {
                        libraryManager.renameGame(target, newTitle: renameText)
                    }
                    gameToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    gameToRename = nil
                }
            }
            .sheet(isPresented: $showNewCollectionSheet) {
                newCollectionSheet
            }
        }
    }

    // MARK: - Subviews

    private var statusHeaderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(emulatorState.biosLoaded ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)

                Text(emulatorState.biosLoaded ? "BIOS Ready" : "BIOS Missing")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(emulatorState.executionMode) • \(emulatorState.jitBlockCount) blocks")
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }

            HStack {
                Text(emulatorState.status)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.68))
                    .lineLimit(1)

                Spacer()

                if !emulatorState.biosLoaded {
                    Button {
                        triggerBIOSImport()
                    } label: {
                        Label("Load BIOS", systemImage: "cpu")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.orange.opacity(0.24), in: Capsule())
                            .foregroundStyle(Color.orange)
                    }
                } else {
                    Button {
                        triggerHaptic(.light)
                        syncFoldersAndBIOS(forceReloadBIOS: false)
                    } label: {
                        Label("Scan", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.10), in: Capsule())
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private func continuePlayingBanner(for game: GameEntry) -> some View {
        Button {
            handleLaunch(game)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(red: 0.22, green: 0.52, blue: 0.96).opacity(0.25))
                        .frame(width: 46, height: 46)
                    Image(systemName: "play.fill")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.36, green: 0.68, blue: 1.0))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("CONTINUE PLAYING")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color(red: 0.36, green: 0.68, blue: 1.0))
                    Text(game.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(game.discID) • \(game.regionBadge)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Color.white.opacity(0.65))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(red: 0.14, green: 0.22, blue: 0.38).opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color(red: 0.30, green: 0.62, blue: 1.0).opacity(0.35), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var filterAndCollectionsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { filter in
                    let isSelected = (selectedCollectionID == nil && selectedFilter == filter)
                    Button {
                        triggerHaptic(.light)
                        selectedCollectionID = nil
                        selectedFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                isSelected
                                    ? Color(red: 0.22, green: 0.52, blue: 0.96)
                                    : Color.white.opacity(0.08),
                                in: Capsule()
                            )
                            .foregroundStyle(.white)
                    }
                }

                if !libraryManager.collections.isEmpty {
                    Divider()
                        .frame(height: 18)
                        .background(Color.white.opacity(0.2))

                    ForEach(libraryManager.collections) { collection in
                        let isSelected = (selectedCollectionID == collection.id)
                        Button {
                            triggerHaptic(.light)
                            selectedCollectionID = isSelected ? nil : collection.id
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(collection.accentColor)
                                    .frame(width: 8, height: 8)
                                Text(collection.name)
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                isSelected
                                    ? collection.accentColor.opacity(0.35)
                                    : Color.white.opacity(0.08),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? collection.accentColor : Color.clear, lineWidth: 1)
                            )
                            .foregroundStyle(.white)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                if selectedCollectionID == collection.id {
                                    selectedCollectionID = nil
                                }
                                libraryManager.deleteCollection(collection)
                            } label: {
                                Label("Delete Collection", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 46))
                .foregroundStyle(Color(red: 0.30, green: 0.62, blue: 1.0).opacity(0.85))

            Text(libraryManager.games.isEmpty ? "No PS2 Games Yet" : "No Matching Games")
                .font(.headline)
                .foregroundStyle(.white)

            Text(
                libraryManager.games.isEmpty
                    ? "Import file ISO/BIN+CUE/CHD atau taruh langsung di Files app: On My iPhone → OREO-PS2 → games."
                    : "Coba kata kunci atau filter koleksi lain."
            )
            .font(.subheadline)
            .foregroundStyle(Color.white.opacity(0.65))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            if libraryManager.games.isEmpty {
                HStack(spacing: 12) {
                    if !emulatorState.biosLoaded {
                        Button {
                            triggerBIOSImport()
                        } label: {
                            Label("Import BIOS", systemImage: "cpu")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.orange, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }

                    Button {
                        triggerGameImport()
                    } label: {
                        Label("Import Game", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(red: 0.22, green: 0.52, blue: 0.96), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)

                Text(libraryManager.importStatusMessage.isEmpty ? "Importing..." : libraryManager.importStatusMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Menyalin disc image dengan aman ke folder games...")
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.11, green: 0.15, blue: 0.24))
            )
        }
    }

    private var newCollectionSheet: some View {
        NavigationStack {
            Form {
                Section("Collection Name") {
                    TextField("e.g. RPG Classics, Racing", text: $newCollectionName)
                }

                Section("Badge Color") {
                    HStack(spacing: 14) {
                        ForEach(0..<GameCollection.palette.count, id: \.self) { idx in
                            Circle()
                                .fill(GameCollection.palette[idx])
                                .frame(width: 30, height: 30)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: newCollectionColorIndex == idx ? 2.5 : 0)
                                )
                                .onTapGesture {
                                    newCollectionColorIndex = idx
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showNewCollectionSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        libraryManager.createCollection(
                            name: newCollectionName,
                            colorIndex: newCollectionColorIndex
                        )
                        showNewCollectionSheet = false
                    }
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Folder Sync & Actions

    private func syncFoldersAndBIOS(forceReloadBIOS: Bool) {
        libraryManager.rescanFolders()

        guard forceReloadBIOS || !emulatorState.biosLoaded else { return }
        for biosURL in libraryManager.detectedBIOSFiles {
            if let prepared = try? GameLibraryManager.prepareBIOSForEmulator(from: biosURL) {
                emulatorState.importBIOS(from: prepared.url)
                if prepared.isTemporary {
                    try? FileManager.default.removeItem(at: prepared.url)
                }
            } else {
                emulatorState.importBIOS(from: biosURL)
            }
            if emulatorState.biosLoaded {
                break
            }
        }
    }

    private func triggerGameImport() {
        triggerHaptic(.light)
        syncFoldersAndBIOS(forceReloadBIOS: !emulatorState.biosLoaded)

        guard emulatorState.biosLoaded else {
            showBIOSRequiredAlert = true
            return
        }

        documentPicker.present(mode: .game) { urls in
            Task {
                await libraryManager.importGames(from: urls)
            }
        }
    }

    private func triggerBIOSImport() {
        triggerHaptic(.light)
        documentPicker.present(mode: .bios) { urls in
            for url in urls {
                if let prepared = try? GameLibraryManager.prepareBIOSForEmulator(from: url) {
                    emulatorState.importBIOS(from: prepared.url)
                    if prepared.isTemporary {
                        try? FileManager.default.removeItem(at: prepared.url)
                    }
                } else {
                    emulatorState.importBIOS(from: url)
                }
            }
            libraryManager.rescanFolders()
        }
    }

    private func handleLaunch(_ game: GameEntry) {
        triggerHaptic(.medium)
        syncFoldersAndBIOS(forceReloadBIOS: !emulatorState.biosLoaded)

        guard emulatorState.biosLoaded else {
            showBIOSRequiredAlert = true
            return
        }
        libraryManager.markPlayed(game)
        emulatorState.launch(game: game)
    }

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

// MARK: - GameCardView

struct GameCardView: View {
    let game: GameEntry
    let collection: GameCollection?
    let onLaunch: () -> Void
    let onToggleFavorite: () -> Void
    let onRename: () -> Void
    let onAssignCollection: (GameCollection?) -> Void
    let onDelete: () -> Void
    let collections: [GameCollection]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                (collection?.accentColor ?? Color(red: 0.20, green: 0.44, blue: 0.88)).opacity(0.45),
                                Color(red: 0.09, green: 0.12, blue: 0.20)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 112)
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "opticaldisc.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.white.opacity(0.88))

                            Text(game.discID)
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.white.opacity(0.82))
                        }
                    )

                Button(action: onToggleFavorite) {
                    Image(systemName: game.isFavorite ? "heart.fill" : "heart")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(game.isFavorite ? Color.pink : Color.white.opacity(0.8))
                        .padding(7)
                        .background(Color.black.opacity(0.35), in: Circle())
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(height: 38, alignment: .topLeading)

                HStack(spacing: 6) {
                    Text(game.regionBadge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .foregroundStyle(.white.opacity(0.9))

                    Text(game.formattedFileSize)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: onLaunch)
        .contextMenu {
            Button(action: onLaunch) {
                Label("Play Game", systemImage: "play.fill")
            }

            Button(action: onToggleFavorite) {
                Label(
                    game.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: game.isFavorite ? "heart.slash" : "heart"
                )
            }

            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }

            if !collections.isEmpty {
                Menu("Move to Collection") {
                    Button("None") {
                        onAssignCollection(nil)
                    }
                    ForEach(collections) { col in
                        Button(col.name) {
                            onAssignCollection(col)
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("Delete Game", systemImage: "trash")
            }
        }
    }
}
