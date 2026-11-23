import Foundation
import Metal

// MARK: - PS2 Emulator — Main Orchestrator

public final class PS2Emulator: @unchecked Sendable {

    // MARK: - Components

    let bus:   MemoryBus
    let ee:    EmotionEngine
    let iop:   IOProcessor
    let gs:    GraphicsSynthesizer
    let dmac:  DMAC
    let intc:  INTC
    let timer: EETimer
    let spu2:  SPU2
    let cdvd:  CDVD
    let pad:   PadManager
    let vu0:   VectorUnit
    let vu1:   VectorUnit
    let vif0:  VectorInterface
    let vif1:  VectorInterface

    // MARK: - JIT

    let jitCache = JITBlockCache()
    var executionMode: ExecutionMode = .jit {
        didSet { if executionMode == .jitless { jitCache.flush() } }
    }

    // MARK: - State

    enum State { case off, paused, running }
    private(set) var state: State = .off
    private var runThread: Thread?
    private var running = false
    private var lastPresentedGSGeneration: UInt64 = .max

    // MARK: - Timing

    var framesPerSecond: Double = 60

    private var clockMultiplier: Double {
        let saved = UserDefaults.standard.double(forKey: "eeClockMultiplier")
        return saved > 0.1 ? min(max(saved, 0.3), 2.5) : 1.0
    }

    private var targetFrameRate: Double {
        let limiter = UserDefaults.standard.string(forKey: "frameLimiter") ?? "60"
        switch limiter {
        case "30": return 30.0
        case "50": return 50.0
        case "0":  return 60.0
        default:   return framesPerSecond
        }
    }

    /// Balanced per-frame EE cycle budget for Swift execution on mobile ARM64,
    /// interleaved across 16 sub-slices per frame so DMA/Timers/VBlank/IRQs stay responsive.
    var eePerFrame: Int {
        Int(180_000.0 * clockMultiplier)
    }

    var iopPerFrame: Int {
        Int(36_000.0 * clockMultiplier)
    }

    // MARK: - BIOS

    private(set) var biosLoaded = false

    // MARK: - Callbacks

    var onFrameReady: ((Data, Int, Int) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Active Cheats
    nonisolated(unsafe) var activeCheats: [CheatCode] = []

    // MARK: - Init

    init() {
        bus   = MemoryBus()
        gs    = GraphicsSynthesizer()
        intc  = INTC()
        timer = EETimer()
        dmac  = DMAC()
        spu2  = SPU2()
        cdvd  = CDVD()
        pad   = PadManager()
        vu0   = VectorUnit(index: 0)
        vu1   = VectorUnit(index: 1)
        vif0  = VectorInterface(index: 0)
        vif1  = VectorInterface(index: 1)
        ee    = EmotionEngine(bus: bus)
        iop   = IOProcessor()

        bus.gs    = gs
        bus.dmac  = dmac
        bus.intc  = intc
        bus.timer = timer
        bus.iop   = iop
        bus.vif0  = vif0
        bus.vif1  = vif1

        dmac.bus  = bus
        dmac.intc = intc
        dmac.gs   = gs
        dmac.vif0 = vif0
        dmac.vif1 = vif1

        timer.intc = intc

        iop.bus    = bus
        iop.spu2   = spu2
        iop.cdvd   = cdvd
        iop.pad    = pad

        vif0.vu = vu0
        vif1.vu = vu1
        vif1.gs = gs

        ee.vu0 = vu0

        // Invalidate JIT cache whenever EE or DMA overwrites executable RAM
        bus.onRAMWrite = { [weak self] physAddr, size in
            guard let self, self.jitCache.blockCount > 0 else { return }
            self.jitCache.invalidate(from: physAddr, size: size)
        }

        vu1.onXGKICK = { [weak self] bytes, len in
            guard let self else { return }
            let qwords = len / 16
            var data: [UInt64] = []
            data.reserveCapacity(qwords * 2)
            var off = 0
            while off + 8 <= bytes.count {
                let lo = bytes.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt64.self).littleEndian }
                data.append(lo)
                off += 8
            }
            self.gs.processGIFPacket(data: data, qwordCount: data.count / 2, flag: 0)
        }
    }

    // MARK: - BIOS Loading

    func loadBIOS(data: Data) throws {
        guard bus.loadBIOS(data: data) else {
            throw EmulatorError.biosInvalid("BIOS file is too small or corrupted")
        }
        biosLoaded = true
        lastPresentedGSGeneration = .max
    }

    // MARK: - Disc Loading

    func loadDisc(url: URL) throws {
        guard biosLoaded else { throw EmulatorError.biosNotLoaded }
        switch url.pathExtension.lowercased() {
        case "cue": try cdvd.loadCUE(url: url)
        case "bin": try cdvd.loadBIN(url: url)
        case "chd": try cdvd.loadCHD(url: url)
        default:    try cdvd.loadISO(url: url)
        }
        framesPerSecond = cdvd.discRegion == .pal ? 50 : 60
        lastPresentedGSGeneration = .max
    }

    // MARK: - Run / Pause / Stop

    func start() {
        guard state == .paused || state == .off else { return }
        if state == .off {
            ee.reset()
            iop.reset()
            gs.reset()
            jitCache.flush()
            lastPresentedGSGeneration = .max
        }
        state = .running
        running = true
        runThread = Thread { [weak self] in self?.runLoop() }
        runThread?.name = "com.cascade.emulator"
        runThread?.qualityOfService = .userInteractive
        runThread?.start()
    }

    func pause() {
        state = .paused
        running = false
    }

    func stop() {
        running = false
        state = .off
        ee.reset()
        iop.reset()
        gs.reset()
        jitCache.flush()
        lastPresentedGSGeneration = .max
    }

    // MARK: - Run Loop

    private func runLoop() {
        var lastTime = DispatchTime.now().uptimeNanoseconds

        while running {
            autoreleasepool {
                let isUncapped = UserDefaults.standard.string(forKey: "frameLimiter") == "0"
                let nsPerFrame = isUncapped ? 1_000_000.0 : (1_000_000_000.0 / max(1.0, targetFrameRate))
                let now = DispatchTime.now().uptimeNanoseconds
                let elapsed = Double(now - lastTime)

                if elapsed >= nsPerFrame {
                    lastTime = now
                    executeFrame()
                } else {
                    let sleepUs = UInt32(min(5_000.0, (nsPerFrame - elapsed) / 2_000.0))
                    if sleepUs > 100 {
                        usleep(sleepUs)
                    }
                }
            }
        }
    }

    private func executeFrame() {
        let slices = 16
        let eeSlice = max(256, eePerFrame / slices)
        let iopSlice = max(64, iopPerFrame / slices)
        let timerTicksPerSlice = max(1, eeSlice / 64)

        for _ in 0..<slices {
            if !running { return }

            // Check pending EE hardware interrupts before executing slice
            if (intc.stat & intc.mask) != 0 {
                ee.checkAndDeliverInterrupt(intcPending: true)
            }

            switch executionMode {
            case .jit:     executeSliceJIT(cycles: eeSlice)
            case .jitless: ee.step(count: eeSlice)
            }

            iop.step(count: iopSlice)
            dmac.step()
            for _ in 0..<timerTicksPerSlice {
                timer.tick()
            }
        }

        applyActiveCheatsToRAM()
        signalVBlank()

        if (intc.stat & intc.mask) != 0 {
            ee.checkAndDeliverInterrupt(intcPending: true)
        }

        // Always emit heartbeat/frame callback so EMU FPS reflects loop speed even before GS draws
        let currentGen = gs.frameGeneration
        if currentGen != lastPresentedGSGeneration {
            lastPresentedGSGeneration = currentGen
            BootDiagLogger.shared.log("GS", "Frame generation updated -> \(currentGen) (\(gs.outputWidth)x\(gs.outputHeight)) bgcolor=0x\(String(gs.bgcolor, radix: 16))")
        }
        let frame = gs.getFrameBuffer()
        onFrameReady?(frame, gs.outputWidth, gs.outputHeight)
    }

    private func applyActiveCheatsToRAM() {
        for cheat in activeCheats where cheat.enabled {
            let parts = cheat.code.split(separator: " ")
            guard parts.count == 2,
                  let rawAddr = UInt32(parts[0], radix: 16),
                  let value   = UInt32(parts[1], radix: 16) else { continue }
            let addr = Int(rawAddr & 0x01FF_FFFF)
            let type = (rawAddr >> 28) & 0xF
            switch type {
            case 0:
                guard addr < bus.ram.count else { continue }
                bus.ram[addr] = UInt8(value & 0xFF)
            case 1:
                guard addr + 1 < bus.ram.count else { continue }
                bus.ram[addr]     = UInt8(value & 0xFF)
                bus.ram[addr + 1] = UInt8((value >> 8) & 0xFF)
            default:
                guard addr + 3 < bus.ram.count else { continue }
                bus.ram[addr]     = UInt8(value & 0xFF)
                bus.ram[addr + 1] = UInt8((value >> 8) & 0xFF)
                bus.ram[addr + 2] = UInt8((value >> 16) & 0xFF)
                bus.ram[addr + 3] = UInt8((value >> 24) & 0xFF)
            }
        }
    }

    // MARK: - JIT Execution (block recompiler)

    private var lastJITBlockSnapshot: Int = -1
    private var stallTickCount: Int = 0
    private var totalSlicesExecuted: Int = 0

    private func executeSliceJIT(cycles: Int) {
        var remaining = cycles
        var iterGuard = 0
        let maxIter = 65_536

        while remaining > 0 && iterGuard < maxIter {
            iterGuard += 1
            let pc = ee.pc

            if let block = jitCache.block(for: pc) {
                ee.executeBlock(block)
                remaining -= max(1, block.instructions.count)
            } else {
                let block = BlockCompiler.compile(at: pc, bus: bus)
                jitCache.insert(block)
                ee.executeBlock(block)
                remaining -= max(1, block.instructions.count)
            }
        }

        totalSlicesExecuted += 1
        let currentBlocks = jitCache.blockCount
        if currentBlocks == lastJITBlockSnapshot {
            stallTickCount += 1
            if stallTickCount == 160 || stallTickCount == 960 || stallTickCount % 3200 == 0 {
                dumpStallSnapshot(blocks: currentBlocks)
            }
        } else {
            if currentBlocks <= 64 || currentBlocks % 50 == 0 {
                BootDiagLogger.shared.log("JIT", "Block #\(currentBlocks) compiled at EE PC=0x\(String(ee.pc, radix: 16, uppercase: true)) | IOP PC=0x\(String(iop.pc, radix: 16, uppercase: true))")
            }
            lastJITBlockSnapshot = currentBlocks
            stallTickCount = 0
        }
    }

    private func dumpStallSnapshot(blocks: Int) {
        var words: [String] = []
        let basePC = ee.pc &- 16
        for i in 0..<12 {
            let addr = basePC &+ UInt32(i * 4)
            let op = bus.read32(address: addr)
            words.append(String(format: "0x%08X:%08X", addr, op))
        }
        var iopWords: [String] = []
        let iopBase = iop.pc &- 8
        for i in 0..<6 {
            let addr = iopBase &+ UInt32(i * 4)
            let op = iop.read32(address: addr)
            iopWords.append(String(format: "0x%08X:%08X", addr, op))
        }
        BootDiagLogger.shared.log(
            "STALL",
            "blocks=\(blocks) slices=\(totalSlicesExecuted) | EE_PC=0x\(String(ee.pc, radix: 16, uppercase: true)) COP0_SR=0x\(String(ee.cop0.status, radix: 16, uppercase: true)) | IOP_PC=0x\(String(iop.pc, radix: 16, uppercase: true)) IOP_ISTAT=0x\(String(iop.iStat, radix: 16, uppercase: true)) IOP_IMASK=0x\(String(iop.iMask, radix: 16, uppercase: true)) | INTC_STAT=0x\(String(intc.stat, radix: 16, uppercase: true)) INTC_MASK=0x\(String(intc.mask, radix: 16, uppercase: true)) | SIF_MSCOM=0x\(String(bus.sifMscom, radix: 16, uppercase: true)) SIF_SMCOM=0x\(String(bus.sifSmcom, radix: 16, uppercase: true)) SIF_SMFLAG=0x\(String(bus.sifSmflag, radix: 16, uppercase: true))"
        )
        BootDiagLogger.shared.log("STALL-EE-CODE", words.joined(separator: " "))
        BootDiagLogger.shared.log("STALL-IOP-CODE", iopWords.joined(separator: " "))
        BootDiagLogger.shared.flush()
    }

    // MARK: - VBlank

    private func signalVBlank() {
        // Toggle FIELD bit (bit 13) and assert VSINT (bit 3)
        gs.csr ^= (1 << 13)
        gs.csr |= (1 << 3)
        intc.assertIRQ(bit: 2)
        intc.assertIRQ(bit: 3)
        iop.assertVBlankIRQ()
    }

    // MARK: - Save States

    func saveState(to url: URL) throws {
        let state = SaveState(
            eePc: ee.pc,
            eeGpr: ee.gpr.map { [$0.hi, $0.lo] },
            iopPc: iop.pc,
            iopGpr: iop.gpr,
            ram: Data(bus.ram),
            iopRam: Data(iop.ram)
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: url)
    }

    func loadState(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let s = try JSONDecoder().decode(SaveState.self, from: data)
        ee.pc = s.eePc
        ee.gpr = s.eeGpr.map { UInt128(hi: $0[0], lo: $0[1]) }
        iop.pc = s.iopPc
        iop.gpr = s.iopGpr
        s.ram.copyBytes(to: &bus.ram, count: min(s.ram.count, bus.ram.count))
        s.iopRam.copyBytes(to: &iop.ram, count: min(s.iopRam.count, iop.ram.count))
        jitCache.flush()
    }
}

// MARK: - Save State Codable

struct SaveState: Codable {
    var eePc:   UInt32
    var eeGpr:  [[UInt64]]
    var iopPc:  UInt32
    var iopGpr: [UInt32]
    var ram:    Data
    var iopRam: Data
}

// MARK: - Errors

enum EmulatorError: LocalizedError {
    case biosNotLoaded
    case biosInvalid(String)
    case discLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .biosNotLoaded:         return "No PS2 BIOS is loaded. Please import a BIOS file first."
        case .biosInvalid(let m):    return "Invalid BIOS: \(m)"
        case .discLoadFailed(let m): return "Failed to load disc: \(m)"
        }
    }
}
