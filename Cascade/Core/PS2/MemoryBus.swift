import Foundation

// MARK: - PS2 Memory Map
//
//  0x0000_0000 – 0x01FF_FFFF   Main RAM (32 MB) + uncached mirrors (0x2000_0000, 0x3000_0000)
//  0x1000_0000 – 0x1000_FFFF   EE Hardware I/O registers (Timers, GIF, VIF, DMAC, INTC, SIF, MCH)
//  0x1200_0000 – 0x1200_1FFF   GS Privileged Registers (PMODE, DISPFB, DISPLAY, BGCOLOR, CSR, IMR)
//  0x1C00_0000 – 0x1C1F_FFFF   IOP RAM (2 MB, shared directly with IOProcessor)
//  0x1E00_0000 – 0x1E3F_FFFF   ROM1 / DVD-ROM area
//  0x1FC0_0000 – 0x1FFF_FFFF   BIOS ROM (4 MB)
//  0x7000_0000 – 0x7000_3FFF   Scratchpad RAM (16 KB)
//  Mirrors: KSEG0 (0x8000_0000), KSEG1 (0xA000_0000) → physical

public final class MemoryBus {

    // MARK: - Memory Regions

    let ramSize     = 32 * 1024 * 1024   // 32 MB EE RAM
    let biosSize    =  4 * 1024 * 1024   // 4 MB BIOS
    let iopSize     =  2 * 1024 * 1024   // 2 MB IOP RAM
    let scratchSize = 16 * 1024          // 16 KB scratchpad

    var ram:      [UInt8]
    var bios:     [UInt8]
    var iopRam:   [UInt8]
    var scratch:  [UInt8]

    // MARK: - SIF (Subsystem Interface EE <-> IOP)
    var sifMscom:  UInt32 = 0
    var sifSmcom:  UInt32 = 0
    var sifMsflag: UInt32 = 0
    var sifSmflag: UInt32 = 0x0007_0000 // IOP boot/SIF ready flags
    var sifCtrl:   UInt32 = 0xF000_0102
    var sifBd6:    UInt32 = 0

    // MARK: - RDRAM Controller (MCH)
    var mchRicm: UInt32 = 0
    var mchDrd:  UInt32 = 0
    private var rdramDevCounter: UInt32 = 0

    // MARK: - Direct GIF FIFO accumulator (0x1000_6000)
    private var gifFifoWords: [UInt32] = []

    // MARK: - Hardware components (weak to avoid retain cycles)
    weak var gs: GraphicsSynthesizer?
    weak var dmac: DMAC?
    weak var intc: INTC?
    weak var timer: EETimer?
    weak var iop: IOProcessor?
    weak var vif0: VectorInterface?
    weak var vif1: VectorInterface?

    /// Notifies JIT cache when executable EE RAM is modified
    var onRAMWrite: ((UInt32, UInt32) -> Void)?
    private var loggedUnmappedIO: Set<UInt32> = []

    // MARK: - Init

    init() {
        ram     = [UInt8](repeating: 0, count: ramSize)
        bios    = [UInt8](repeating: 0, count: biosSize)
        iopRam  = [UInt8](repeating: 0, count: iopSize)
        scratch = [UInt8](repeating: 0, count: scratchSize)
    }

    // MARK: - BIOS Loading

    func loadBIOS(data: Data) -> Bool {
        guard data.count >= 256_000, data.count <= biosSize else { return false }
        bios = [UInt8](repeating: 0, count: biosSize)
        data.copyBytes(to: &bios, count: min(data.count, biosSize))
        return true
    }

    // MARK: - Address Translation

    func physicalAddress(_ virtual: UInt32) -> UInt32 {
        // Preserve Scratchpad (0x7000_0000 ..< 0x7000_4000) before masking KSEG0/KSEG1
        if virtual >= 0x7000_0000 && virtual < 0x7000_4000 {
            return virtual
        }
        switch virtual >> 29 {
        case 0x4: return virtual & 0x1FFF_FFFF  // KSEG0 (0x8000_0000..0x9FFF_FFFF)
        case 0x5: return virtual & 0x1FFF_FFFF  // KSEG1 (0xA000_0000..0xBFFF_FFFF)
        default:  return virtual & 0x1FFF_FFFF
        }
    }

    // MARK: - Read

    func read8(address: UInt32) -> UInt8 {
        let phys = physicalAddress(address)
        switch phys {
        case 0x0000_0000..<0x0200_0000:
            return ram[Int(phys)]
        case 0x2000_0000..<0x2200_0000, 0x3000_0000..<0x3200_0000:
            return ram[Int(phys & 0x01FF_FFFF)]
        case 0x1FC0_0000..<0x2000_0000:
            return bios[Int(phys - 0x1FC0_0000)]
        case 0x1E00_0000..<0x1E40_0000:
            return 0 // Unpopulated ROM1 reads as 0
        case 0x1C00_0000..<0x1C20_0000:
            let off = Int(phys - 0x1C00_0000)
            return iop?.ram[off] ?? iopRam[off]
        case 0x7000_0000..<0x7000_4000:
            return scratch[Int(phys - 0x7000_0000)]
        case 0x1000_0000..<0x1001_0000:
            return readIO8(offset: phys - 0x1000_0000)
        case 0x1200_0000..<0x1200_2000:
            let word = gs?.readPriv(offset: (phys - 0x1200_0000) & ~3) ?? 0
            return UInt8((word >> ((phys & 3) * 8)) & 0xFF)
        default:
            return 0
        }
    }

    func read16(address: UInt32) -> UInt16 {
        return UInt16(read8(address: address)) | (UInt16(read8(address: address &+ 1)) << 8)
    }

    func read32(address: UInt32) -> UInt32 {
        let phys = physicalAddress(address)
        switch phys {
        case 0x0000_0000..<0x0200_0000:
            let off = Int(phys & ~3)
            return ram.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: off, as: UInt32.self).littleEndian
            }
        case 0x2000_0000..<0x2200_0000, 0x3000_0000..<0x3200_0000:
            let off = Int((phys & 0x01FF_FFFF) & ~3)
            return ram.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: off, as: UInt32.self).littleEndian
            }
        case 0x1FC0_0000..<0x2000_0000:
            let off = Int((phys - 0x1FC0_0000) & ~3)
            return bios.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: off, as: UInt32.self).littleEndian
            }
        case 0x1E00_0000..<0x1E40_0000:
            return 0
        case 0x1C00_0000..<0x1C20_0000:
            let off = Int((phys - 0x1C00_0000) & ~3)
            if let iopRef = iop {
                return iopRef.ram.withUnsafeBytes { ptr in
                    ptr.load(fromByteOffset: off, as: UInt32.self).littleEndian
                }
            }
            return iopRam.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: off, as: UInt32.self).littleEndian
            }
        case 0x1000_0000..<0x1001_0000:
            return readIO32(offset: phys - 0x1000_0000)
        case 0x1200_0000..<0x1200_2000:
            return gs?.readPriv(offset: phys - 0x1200_0000) ?? 0
        case 0x7000_0000..<0x7000_4000:
            let off = Int((phys - 0x7000_0000) & ~3)
            return scratch.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: off, as: UInt32.self).littleEndian
            }
        default:
            return 0
        }
    }

    func read64(address: UInt32) -> UInt64 {
        let lo = UInt64(read32(address: address))
        let hi = UInt64(read32(address: address &+ 4))
        return lo | (hi << 32)
    }

    func read128(address: UInt32) -> UInt128 {
        UInt128(hi: read64(address: address &+ 8), lo: read64(address: address))
    }

    // MARK: - Write

    func write8(address: UInt32, value: UInt8) {
        let phys = physicalAddress(address)
        switch phys {
        case 0x0000_0000..<0x0200_0000:
            ram[Int(phys)] = value
            onRAMWrite?(phys & ~3, 4)
        case 0x2000_0000..<0x2200_0000, 0x3000_0000..<0x3200_0000:
            let mapped = phys & 0x01FF_FFFF
            ram[Int(mapped)] = value
            onRAMWrite?(mapped & ~3, 4)
        case 0x1C00_0000..<0x1C20_0000:
            let off = Int(phys - 0x1C00_0000)
            if let iopRef = iop { iopRef.ram[off] = value } else { iopRam[off] = value }
        case 0x7000_0000..<0x7000_4000:
            scratch[Int(phys - 0x7000_0000)] = value
        case 0x1000_0000..<0x1001_0000:
            writeIO8(offset: phys - 0x1000_0000, value: value)
        case 0x1200_0000..<0x1200_2000:
            let aligned = (phys - 0x1200_0000) & ~3
            var word = gs?.readPriv(offset: aligned) ?? 0
            let shift = (phys & 3) * 8
            word = (word & ~(0xFF << shift)) | (UInt32(value) << shift)
            gs?.writePriv(offset: aligned, value: word)
        default:
            break
        }
    }

    func write16(address: UInt32, value: UInt16) {
        write8(address: address, value: UInt8(value & 0xFF))
        write8(address: address &+ 1, value: UInt8(value >> 8))
    }

    func write32(address: UInt32, value: UInt32) {
        let phys = physicalAddress(address)
        switch phys {
        case 0x0000_0000..<0x0200_0000:
            let off = Int(phys & ~3)
            ram.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt32.self)
            }
            onRAMWrite?(UInt32(off), 4)
        case 0x2000_0000..<0x2200_0000, 0x3000_0000..<0x3200_0000:
            let off = Int((phys & 0x01FF_FFFF) & ~3)
            ram.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt32.self)
            }
            onRAMWrite?(UInt32(off), 4)
        case 0x1C00_0000..<0x1C20_0000:
            let off = Int((phys - 0x1C00_0000) & ~3)
            if let iopRef = iop {
                iopRef.ram.withUnsafeMutableBytes { ptr in
                    ptr.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt32.self)
                }
            } else {
                iopRam.withUnsafeMutableBytes { ptr in
                    ptr.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt32.self)
                }
            }
        case 0x7000_0000..<0x7000_4000:
            let off = Int((phys - 0x7000_0000) & ~3)
            scratch.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt32.self)
            }
        case 0x1000_0000..<0x1001_0000:
            writeIO32(offset: phys - 0x1000_0000, value: value)
        case 0x1200_0000..<0x1200_2000:
            gs?.writePriv(offset: phys - 0x1200_0000, value: value)
        default:
            break
        }
    }

    func write64(address: UInt32, value: UInt64) {
        write32(address: address, value: UInt32(value & 0xFFFF_FFFF))
        write32(address: address &+ 4, value: UInt32(value >> 32))
    }

    func write128(address: UInt32, value: UInt128) {
        let phys = physicalAddress(address)
        // Fast path for direct GIF FIFO (0x1000_6000 ..< 0x1000_7000)
        if phys >= 0x1000_6000 && phys < 0x1000_7000 {
            let qwords: [UInt64] = [value.lo, value.hi]
            gs?.processGIFPacket(data: qwords, qwordCount: 1, flag: 0)
            return
        }
        write64(address: address, value: value.lo)
        write64(address: address &+ 8, value: value.hi)
    }

    // MARK: - Hardware I/O (0x1000_0000 ..< 0x1001_0000)

    private func readIO8(offset: UInt32) -> UInt8 {
        return UInt8((readIO32(offset: offset & ~3) >> ((offset & 3) * 8)) & 0xFF)
    }

    private func writeIO8(offset: UInt32, value: UInt8) {
        var word = readIO32(offset: offset & ~3)
        let shift = (offset & 3) * 8
        word = (word & ~(0xFF << shift)) | (UInt32(value) << shift)
        writeIO32(offset: offset & ~3, value: word)
    }

    func readIO32(offset: UInt32) -> UInt32 {
        switch offset {
        case 0x0000..<0x2000:   // EE Timers 0..3
            return timer?.read(offset: offset) ?? 0
        case 0x2000..<0x3000:   // IPU
            return 0
        case 0x3000..<0x3800:   // GIF registers (GIF_STAT = 0 -> FIFO empty/idle)
            return 0
        case 0x3800..<0x4000:   // VIF0 / VIF1 status (idle)
            return 0
        case 0x8000..<0xE100:   // DMAC channels 0..9 + global registers
            return dmac?.read(offset: offset) ?? 0
        case 0xF000:            // INTC_STAT
            return intc?.read(offset: 0) ?? 0
        case 0xF010:            // INTC_MASK
            return intc?.read(offset: 4) ?? 0
        case 0xF200:            // SIF MSCOM
            return sifMscom
        case 0xF210:            // SIF SMCOM
            return sifSmcom
        case 0xF220:            // SIF MSFLAG
            return sifMsflag
        case 0xF230:            // SIF SMFLAG
            return sifSmflag
        case 0xF240:            // SIF CTRL
            return sifCtrl
        case 0xF260:            // SIF BD6
            return sifBd6
        case 0xF430:            // MCH_RICM (bit 31 = 0 -> ready)
            return mchRicm & 0x7FFF_FFFF
        case 0xF440:            // MCH_DRD (RDRAM init/probe responses)
            let cmd = (mchRicm >> 16) & 0xF
            if cmd == 1 {
                // RDRAM device ID response
                defer { rdramDevCounter &+= 1 }
                return rdramDevCounter < 2 ? 0x0000_001F : 0
            }
            return mchDrd
        case 0xF520:            // D_ENABLER
            return dmac?.read(offset: 0xF520) ?? 0
        default:
            let addr = 0x1000_0000 | offset
            if loggedUnmappedIO.insert(addr).inserted {
                BootDiagLogger.shared.logHex("EE-IO", "Unhandled READ32", addr: addr, val: 0)
            }
            return 0
        }
    }

    func writeIO32(offset: UInt32, value: UInt32) {
        switch offset {
        case 0x0000..<0x2000:   // EE Timers 0..3
            timer?.write(offset: offset, value: value)
        case 0x4000..<0x5000:   // VIF0 FIFO
            vif0?.feed(words: [value])
        case 0x5000..<0x6000:   // VIF1 FIFO
            vif1?.feed(words: [value])
        case 0x6000..<0x7000:   // GIF FIFO (32-bit writes accumulated into 128-bit qwords)
            gifFifoWords.append(value)
            if gifFifoWords.count >= 4 {
                let lo = UInt64(gifFifoWords[0]) | (UInt64(gifFifoWords[1]) << 32)
                let hi = UInt64(gifFifoWords[2]) | (UInt64(gifFifoWords[3]) << 32)
                gifFifoWords.removeAll(keepingCapacity: true)
                gs?.processGIFPacket(data: [lo, hi], qwordCount: 1, flag: 0)
            }
        case 0x8000..<0xE100:   // DMAC channels 0..9 + global registers
            dmac?.write(offset: offset, value: value)
        case 0xF000:            // INTC_STAT (W1C)
            intc?.write(offset: 0, value: value)
        case 0xF010:            // INTC_MASK (toggle)
            intc?.write(offset: 4, value: value)
        case 0xF200:            // SIF MSCOM
            sifMscom = value
        case 0xF210:            // SIF SMCOM
            sifSmcom = value
        case 0xF220:            // SIF MSFLAG (set bits)
            sifMsflag |= value
        case 0xF230:            // SIF SMFLAG (clear bits)
            sifSmflag &= ~value
        case 0xF240:            // SIF CTRL
            sifCtrl = (sifCtrl & ~0xF0) | (value & 0xF0) | 0xF000_0102
        case 0xF260:            // SIF BD6
            sifBd6 = value
        case 0xF430:            // MCH_RICM
            mchRicm = value & 0x7FFF_FFFF
            if ((value >> 16) & 0xF) == 1 {
                rdramDevCounter = 0
            }
        case 0xF440:            // MCH_DRD
            mchDrd = value
        case 0xF590:            // D_ENABLEW
            dmac?.write(offset: 0xF590, value: value)
        default:
            let addr = 0x1000_0000 | offset
            if loggedUnmappedIO.insert(addr).inserted {
                BootDiagLogger.shared.logHex("EE-IO", "Unhandled WRITE32", addr: addr, val: value)
            }
            break
        }
    }
}
