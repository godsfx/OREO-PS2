import Darwin
import SwiftUI
import UIKit

// MARK: - Main Emulator View (full-screen game display + on-screen controller)

struct EmulatorView: View {
    @EnvironmentObject var emulatorState: EmulatorState
    @EnvironmentObject var cheatManager: CheatManager
    @State private var showMenu = false
    @State private var menuOpacity: Double = 0
    @State private var controllerVisible = true
    @State private var lastTap = Date()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // Game output
                gameOutput

                // Gradient vignette for controller readability
                if controllerVisible {
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.7)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: geo.size.height * 0.45)
                    }
                    .ignoresSafeArea()
                }

                // On-screen controller
                if controllerVisible {
                    OnScreenControllerView()
                        .ignoresSafeArea()
                }

                // Swipe gesture zone (top of screen)
                VStack {
                    swipeTarget
                    Spacer()
                }
                .ignoresSafeArea()

                // Debug Overlay HUD (top-left, toggled in Settings -> Diagnostics)
                VStack {
                    HStack {
                        DebugOverlayHUD()
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, 44)
                .padding(.leading, 12)
                .ignoresSafeArea(edges: .horizontal)

                // In-game menu overlay
                if showMenu {
                    EmulatorMenuView(isPresented: $showMenu)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .statusBarHidden(!showMenu)
        .persistentSystemOverlays(.hidden)
    }

    private var gameOutput: some View {
        Group {
            if let frame = emulatorState.frameImage {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loadingState
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text(emulatorState.currentGame?.title ?? "Starting…")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))
        }
    }

    private var swipeTarget: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 60)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        if value.translation.height > 30 {
                            emulatorState.pause()
                            withAnimation(.spring(response: 0.3)) { showMenu = true }
                        }
                    }
            )
    }
}

// MARK: - Emulator Menu (in-game pause menu)

struct EmulatorMenuView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var emulatorState: EmulatorState
    @EnvironmentObject var cheatManager: CheatManager
    @State private var showSaveSlots = false
    @State private var showLoadSlots = false
    @State private var showCheats    = false

    var body: some View {
        ZStack {
            // Backdrop
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { isPresented = false }
                    emulatorState.resume()
                }

            // Menu card (iOS 26 Liquid Glass style)
            VStack(spacing: 0) {
                menuHeader
                Divider().background(.white.opacity(0.15))
                menuItems
            }
            .frame(width: 300)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 10)
        }
    }

    private var menuHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 32))
                .foregroundStyle(Color.cascadeBlue.gradient)
                .modifier(PulseIfAvailable())

            Text(emulatorState.currentGame?.title ?? "Cascade")
                .font(.headline)
                .lineLimit(1)

            if emulatorState.status == .running {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("\(Int(emulatorState.fps)) FPS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 20)
    }

    private var menuItems: some View {
        VStack(spacing: 0) {
            menuButton(icon: "play.fill", label: "Resume", color: .green) {
                withAnimation { isPresented = false }
                emulatorState.resume()
            }

            Divider().background(.white.opacity(0.08)).padding(.horizontal, 16)

            menuButton(icon: "square.and.arrow.down.fill", label: "Save State", color: .cascadeBlue) {
                showSaveSlots = true
            }

            Divider().background(.white.opacity(0.08)).padding(.horizontal, 16)

            menuButton(icon: "square.and.arrow.up.fill", label: "Load State", color: .cascadeBlue) {
                showLoadSlots = true
            }

            Divider().background(.white.opacity(0.08)).padding(.horizontal, 16)

            menuButton(icon: "camera.fill", label: "Screenshot", color: .purple) {
                takeScreenshot()
            }

            Divider().background(.white.opacity(0.08)).padding(.horizontal, 16)

            menuButton(icon: "wand.and.stars", label: "Cheats", color: .orange) {
                showCheats = true
            }

            Divider().background(.white.opacity(0.08)).padding(.horizontal, 16)

            menuButton(icon: "xmark.circle.fill", label: "Exit to Library", color: .red) {
                withAnimation { isPresented = false }
                emulatorState.stop()
            }
        }
        .sheet(isPresented: $showSaveSlots) { SaveStateSheet(mode: .save, isPresented: $showSaveSlots) }
        .sheet(isPresented: $showLoadSlots) { SaveStateSheet(mode: .load, isPresented: $showLoadSlots) }
        .sheet(isPresented: $showCheats) {
            InGameCheatSheet(isPresented: $showCheats)
        }
    }

    private func menuButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28)
                Text(label)
                    .font(.body.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func takeScreenshot() {
        guard let image = emulatorState.frameImage else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { isPresented = false }
    }
}

// MARK: - In-Game Cheat Sheet

struct InGameCheatSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var emulatorState: EmulatorState
    @EnvironmentObject var cheatManager: CheatManager

    private var discID: String {
        (emulatorState.currentGame?.discID ?? "").uppercased()
    }

    var body: some View {
        NavigationStack {
            Group {
                let cheats = cheatManager.cheats(for: discID)
                if cheats.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 44))
                            .foregroundStyle(.orange.gradient)
                        Text("No Cheats")
                            .font(.title3.bold())
                        Text("Add cheats from the game detail screen in your library.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(cheats) { cheat in
                        HStack(spacing: 14) {
                            Toggle("", isOn: Binding(
                                get: { cheat.enabled },
                                set: { _ in
                                    cheatManager.toggle(cheat, for: discID)
                                    emulatorState.setActiveCheats(
                                        cheatManager.cheats(for: discID))
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                }
                            ))
                            .labelsHidden()
                            .tint(.orange)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(cheat.name).font(.headline)
                                Text(cheat.code)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(
                            cheat.enabled
                                ? Color.orange.opacity(0.07)
                                : Color(.secondarySystemGroupedBackground)
                        )
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Cheats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .onAppear {
            emulatorState.setActiveCheats(cheatManager.cheats(for: discID))
        }
    }
}

// MARK: - Save/Load State Sheet

struct SaveStateSheet: View {
    enum Mode { case save, load }
    let mode: Mode
    @Binding var isPresented: Bool
    @EnvironmentObject var emulatorState: EmulatorState

    var body: some View {
        NavigationStack {
            List(0..<8) { slot in
                let date = emulatorState.stateDate(slot: slot)
                Button(action: {
                    mode == .save ? emulatorState.saveState(slot: slot) : emulatorState.loadState(slot: slot)
                    isPresented = false
                }) {
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(date != nil ? Color.cascadeBlue.opacity(0.15) : Color(.tertiarySystemFill))
                                .frame(width: 38, height: 38)
                            Image(systemName: date != nil ? "square.fill.on.square.fill" : "square.dashed")
                                .foregroundStyle(date != nil ? Color.cascadeBlue : Color.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Slot \(slot + 1)")
                                .font(.headline)
                            if let date {
                                Text(date, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Empty")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        if date != nil {
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .disabled(mode == .load && date == nil)
            }
            .navigationTitle(mode == .save ? "Save State" : "Load State")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}


// MARK: - Debug Overlay Configuration

enum DebugOverlayConfig {
    static let enabledKey = "oreo.debugOverlay.enabled"
}

// MARK: - Debug Telemetry Sampler

@MainActor
final class DebugTelemetryModel: ObservableObject {
    @Published var uiFPS: Double = 0
    @Published var frameTimeMs: Double = 0
    @Published var memoryMB: Double = 0
    @Published var elapsedSeconds: Int = 0

    private var startTime: CFTimeInterval = CACurrentMediaTime()
    private var lastSampleTime: CFTimeInterval = CACurrentMediaTime()
    private var frameCounter: Int = 0
    private var timer: Timer?

    func start() {
        stop()
        let now = CACurrentMediaTime()
        startTime = now
        lastSampleTime = now
        frameCounter = 0

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStats()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func recordTick() {
        frameCounter += 1
    }

    private func refreshStats() {
        let now = CACurrentMediaTime()
        let dt = now - lastSampleTime
        if dt > 0 {
            let currentFPS = Double(frameCounter) / dt
            uiFPS = currentFPS
            frameTimeMs = currentFPS > 0 ? (1000.0 / currentFPS) : 0
        }
        frameCounter = 0
        lastSampleTime = now
        elapsedSeconds = max(0, Int(now - startTime))
        memoryMB = Self.currentMemoryFootprintMB()
    }

    private static func currentMemoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }
}

// MARK: - Debug Overlay HUD

struct DebugOverlayHUD: View {
    @AppStorage(DebugOverlayConfig.enabledKey) private var isEnabled: Bool = false
    @EnvironmentObject var emulatorState: EmulatorState
    @StateObject private var telemetry = DebugTelemetryModel()
    @State private var isCollapsed: Bool = false
    @State private var copiedFeedback: Bool = false

    var body: some View {
        if isEnabled {
            VStack(alignment: .leading, spacing: 6) {
                headerBar

                if !isCollapsed {
                    Divider()
                        .background(Color.white.opacity(0.2))

                    metricsGrid
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.cascadeBlue.opacity(0.55), lineWidth: 1)
                    )
            )
            .onAppear { telemetry.start() }
            .onDisappear { telemetry.stop() }
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    Color.clear
                        .frame(width: 0, height: 0)
                        .onChange(of: context.date) { _ in
                            telemetry.recordTick()
                        }
                }
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(emulatorState.frameImage != nil ? Color.green : Color.orange)
                .frame(width: 7, height: 7)

            Text(String(format: "EMU %.0f | UI %.0f FPS", emulatorState.fps, telemetry.uiFPS))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(emulatorState.frameImage != nil ? .green : .orange)

            Text("• \(formatElapsed(telemetry.elapsedSeconds))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))

            Button {
                copyDiagnosticsToClipboard()
            } label: {
                Image(systemName: copiedFeedback ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundStyle(copiedFeedback ? .green : .white.opacity(0.8))
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isCollapsed.toggle()
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.cascadeBlue)
            }
            .buttonStyle(.plain)
        }
    }

    private var metricsGrid: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("STATUS", String(describing: emulatorState.status))
            row("GS OUT", gsFrameSummary)
            row("CPU/JIT", "\(String(describing: emulatorState.executionMode)) (\(emulatorState.jitBlockCount) blk • \(Int(emulatorState.jitHitRate * 100))%)")
            row("BIOS", emulatorState.biosLoaded ? "Loaded" : "MISSING")
            row("DISC ID", "\(emulatorState.currentGame?.discID ?? "-") [\(emulatorState.currentGame?.regionBadge ?? "-")]")
            row("FILE", emulatorState.currentGame?.fileName ?? "None")
            row("RAM", String(format: "%.1f MB", telemetry.memoryMB))
            row("RES", nativeResolutionText)
        }
        .allowsHitTesting(false)
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.cascadeBlue)
                .frame(width: 54, alignment: .leading)

            Text(value)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var gsFrameSummary: String {
        if let img = emulatorState.frameImage {
            return "Active (\(Int(img.size.width))x\(Int(img.size.height)))"
        }
        return "Nil (No GS frame)"
    }

    private var nativeResolutionText: String {
        let bounds = UIScreen.main.nativeBounds
        return "\(Int(bounds.width))x\(Int(bounds.height))"
    }

    private func formatElapsed(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func copyDiagnosticsToClipboard() {
        let report = [
            "OREO-PS2 Debug Telemetry",
            "Time: \(formatElapsed(telemetry.elapsedSeconds))",
            "Status: \(String(describing: emulatorState.status))",
            "GS Output: \(gsFrameSummary)",
            "EMU FPS: \(String(format: "%.1f", emulatorState.fps)) | UI FPS: \(String(format: "%.1f", telemetry.uiFPS))",
            "CPU/JIT: \(String(describing: emulatorState.executionMode)) (\(emulatorState.jitBlockCount) blocks, \(Int(emulatorState.jitHitRate * 100))% hit)",
            "BIOS: \(emulatorState.biosLoaded ? "Loaded" : "MISSING")",
            "Disc ID: \(emulatorState.currentGame?.discID ?? "-") [\(emulatorState.currentGame?.regionBadge ?? "-")]",
            "File: \(emulatorState.currentGame?.fileName ?? "None")",
            "RAM: \(String(format: "%.1f MB", telemetry.memoryMB))",
            "Resolution: \(nativeResolutionText)"
        ].joined(separator: "
")
        UIPasteboard.general.string = report
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedFeedback = false
        }
    }
}
