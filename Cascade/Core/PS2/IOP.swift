import Foundation

// MARK: - I/O Processor (IOP)
// The PS2's secondary CPU: a MIPS R3000A running at ~36.864 MHz
// Handles CD/DVD, SPU2, controllers, memory cards, and SIF communication with EE.

public final class IOProcessor {

    // MARK: - Registers
    var gpr: [UInt32] = Array(repeating: 0, count: 32)
    var pc: UInt32 = 0xBFC00000
    var hi: UInt32 = 0
    var lo: UInt32 = 0
    var inDelaySlot = false
    var nextPC: UInt32 = 0

    // COP0
    var cop0Status: UInt32 = 0x0040_0000 // BEV = 1 on reset
    var cop0Cause:  UInt32 = 0
    var cop0EPC:    UInt32 = 0

    // IOP Interrupt Controller (0x1F80_1070 / 0x1F80_1074 / 0x1F80_1078)
    var iStat: UInt32 = 0
    var iMask: UInt32 = 0
    var iCtrl: UInt32 = 0

    // MARK: - Subsystems
    weak var bus: MemoryBus?
    var spu2: SPU2?
    var cdvd: CDVD?
    var pad:  PadManager?

    // MARK: - IOP RAM (2 MB, mapped on EE bus at 0x1C00_0000 ..< 0x1C20_0000)
    var ram: [UInt8] = [UInt8](repeating: 0, count: 2 * 1024 * 1024)

    var cycles: UInt64 = 0
    private var loggedUnmappedIOP: Set<UInt32> = []

    // MARK: - Init

    init() {
        reset()
    }

    func reset() {
        gpr = Array(repeating: 0, count: 32)
        pc = 0xBFC00000
        hi = 0; lo = 0
        inDelaySlot = false
        nextPC = 0
        cop0Status = 0x0040_0000
        cop0Cause  = 0
        cop0EPC    = 0
        iStat = 0
        iMask = 0
        iCtrl = 0
        cycles = 0
    }

    func assertVBlankIRQ() {
        iStat |= (1 << 0) // IOP IRQ0 = VBlank
        iStat |= (1 << 11) // IOP IRQ11 = VBlank end
    }

    // MARK: - Step

    func step(count: Int) {
        for _ in 0..<count {
            if iCtrl != 0 && (iStat & iMask) != 0 && (cop0Status & 0x1) != 0 {
                deliverInterrupt()
            }
            executeOne()
            cycles &+= 1
            if (cycles & 0x3F) == 0 {
                spu2?.tick()
            }
        }
    }

    private func deliverInterrupt() {
        cop0EPC = inDelaySlot ? (pc &- 4) : pc
        cop0Cause = (cop0Cause & ~(0x1F << 2)) | (1 << 10)
        // Shift KUc/IEc -> KUp/IEp -> KUo/IEo
        let mode = cop0Status & 0x3F
        cop0Status = (cop0Status & ~0x3F) | ((mode << 2) & 0x3C)
        inDelaySlot = false
        pc = ((cop0Status & (1 << 22)) != 0) ? 0xBFC00180 : 0x80000080
    }

    private func executeOne() {
        let instruction = read32(address: pc)
        if inDelaySlot {
            pc = nextPC
            inDelaySlot = false
        } else {
            pc &+= 4
        }
        decode(instruction)
    }

    // MARK: - Decode (MIPS R3000A)

    private func decode(_ instruction: UInt32) {
        guard instruction != 0 else { return } // Fast NOP

        let op    = (instruction >> 26) & 0x3F
        let rs    = Int((instruction >> 21) & 0x1F)
        let rt    = Int((instruction >> 16) & 0x1F)
        let rd    = Int((instruction >> 11) & 0x1F)
        let shamt = (instruction >> 6) & 0x1F
        let funct = instruction & 0x3F
        let imm16 = Int32(Int16(bitPattern: UInt16(instruction & 0xFFFF)))
        let imm26 = instruction & 0x03FF_FFFF

        switch op {
        case 0x00: // SPECIAL
            switch funct {
            case 0x00: setGPR(rd, value: gpr[rt] << shamt)
            case 0x02: setGPR(rd, value: gpr[rt] >> shamt)
            case 0x03: setGPR(rd, value: UInt32(bitPattern: Int32(bitPattern: gpr[rt]) >> shamt))
            case 0x04: setGPR(rd, value: gpr[rt] << (gpr[rs] & 0x1F))
            case 0x06: setGPR(rd, value: gpr[rt] >> (gpr[rs] & 0x1F))
            case 0x07: setGPR(rd, value: UInt32(bitPattern: Int32(bitPattern: gpr[rt]) >> (gpr[rs] & 0x1F)))
            case 0x08: branch(to: gpr[rs])
            case 0x09: let ret = pc &+ 4; branch(to: gpr[rs]); setGPR(rd, value: ret)
            case 0x0C: triggerSyscall()
            case 0x10: setGPR(rd, value: hi)
            case 0x11: hi = gpr[rs]
            case 0x12: setGPR(rd, value: lo)
            case 0x13: lo = gpr[rs]
            case 0x18:
                let r = Int64(Int32(bitPattern: gpr[rs])) &* Int64(Int32(bitPattern: gpr[rt]))
                lo = UInt32(UInt64(bitPattern: r) & 0xFFFF_FFFF)
                hi = UInt32(UInt64(bitPattern: r) >> 32)
            case 0x19:
                let r = UInt64(gpr[rs]) * UInt64(gpr[rt])
                lo = UInt32(r & 0xFFFF_FFFF)
                hi = UInt32(r >> 32)
            case 0x1A:
                let b = Int32(bitPattern: gpr[rt])
                if b != 0 {
                    lo = UInt32(bitPattern: Int32(bitPattern: gpr[rs]) / b)
                    hi = UInt32(bitPattern: Int32(bitPattern: gpr[rs]) % b)
                }
            case 0x1B:
                let b = gpr[rt]
                if b != 0 { lo = gpr[rs] / b; hi = gpr[rs] % b }
            case 0x20: setGPR(rd, value: UInt32(bitPattern: Int32(bitPattern: gpr[rs]) &+ Int32(bitPattern: gpr[rt])))
            case 0x21: setGPR(rd, value: gpr[rs] &+ gpr[rt])
            case 0x22: setGPR(rd, value: UInt32(bitPattern: Int32(bitPattern: gpr[rs]) &- Int32(bitPattern: gpr[rt])))
            case 0x23: setGPR(rd, value: gpr[rs] &- gpr[rt])
            case 0x24: setGPR(rd, value: gpr[rs] & gpr[rt])
            case 0x25: setGPR(rd, value: gpr[rs] | gpr[rt])
            case 0x26: setGPR(rd, value: gpr[rs] ^ gpr[rt])
            case 0x27: setGPR(rd, value: ~(gpr[rs] | gpr[rt]))
            case 0x2A: setGPR(rd, value: Int32(bitPattern: gpr[rs]) < Int32(bitPattern: gpr[rt]) ? 1 : 0)
            case 0x2B: setGPR(rd, value: gpr[rs] < gpr[rt] ? 1 : 0)
            default: break
            }
        case 0x01: // REGIMM
            switch rt {
            case 0x00: if Int32(bitPattern: gpr[rs]) < 0 { branchOffset(imm16) }
            case 0x01: if Int32(bitPattern: gpr[rs]) >= 0 { branchOffset(imm16) }
            case 0x10: setGPR(31, value: pc &+ 4); if Int32(bitPattern: gpr[rs]) < 0 { branchOffset(imm16) }
            case 0x11: setGPR(31, value: pc &+ 4); if Int32(bitPattern: gpr[rs]) >= 0 { branchOffset(imm16) }
            default: break
            }
        case 0x02: jumpAbsolute(imm26)
        case 0x03: setGPR(31, value: pc &+ 4); jumpAbsolute(imm26)
        case 0x04: if gpr[rs] == gpr[rt] { branchOffset(imm16) }
        case 0x05: if gpr[rs] != gpr[rt] { branchOffset(imm16) }
        case 0x06: if Int32(bitPattern: gpr[rs]) <= 0 { branchOffset(imm16) }
        case 0x07: if Int32(bitPattern: gpr[rs]) > 0 { branchOffset(imm16) }
        case 0x08: setGPR(rt, value: UInt32(bitPattern: Int32(bitPattern: gpr[rs]) &+ imm16))
        case 0x09: setGPR(rt, value: UInt32(bitPattern: Int32(bitPattern: gpr[rs]) &+ imm16))
        case 0x0A: setGPR(rt, value: Int32(bitPattern: gpr[rs]) < imm16 ? 1 : 0)
        case 0x0B: setGPR(rt, value: gpr[rs] < UInt32(bitPattern: imm16) ? 1 : 0)
        case 0x0C: setGPR(rt, value: gpr[rs] & UInt32(instruction & 0xFFFF))
        case 0x0D: setGPR(rt, value: gpr[rs] | UInt32(instruction & 0xFFFF))
        case 0x0E: setGPR(rt, value: gpr[rs] ^ UInt32(instruction & 0xFFFF))
        case 0x0F: setGPR(rt, value: UInt32(instruction & 0xFFFF) << 16)
        case 0x10: // COP0
            switch rs {
            case 0x00: // MFC0
                let val: UInt32
                switch rd {
                case 12: val = cop0Status
                case 13: val = cop0Cause
                case 14: val = cop0EPC
                case 15: val = 0x0000_002E // IOP PRId
                default: val = 0
                }
                setGPR(rt, value: val)
            case 0x04: // MTC0
                switch rd {
                case 12: cop0Status = gpr[rt]
                case 13: cop0Cause  = gpr[rt]
                case 14: cop0EPC    = gpr[rt]
                default: break
                }
            case 0x10: // RFE
                if funct == 0x10 {
                    let mode = cop0Status & 0x3F
                    cop0Status = (cop0Status & ~0x0F) | (mode >> 2)
                }
            default: break
            }
        case 0x20: setGPR(rt, value: UInt32(bitPattern: Int32(Int8(bitPattern: read8(address: ea(rs, imm16))))))
        case 0x21: setGPR(rt, value: UInt32(bitPattern: Int32(Int16(bitPattern: read16(address: ea(rs, imm16))))))
        case 0x22: // LWL
            let addr = ea(rs, imm16)
            let aligned = addr & ~3
            let word = read32(address: aligned)
            let shift = (addr & 3) * 8
            let mask = UInt32(0x00FF_FFFF) >> shift
            setGPR(rt, value: (gpr[rt] & mask) | (word << (24 - shift)))
        case 0x23: setGPR(rt, value: read32(address: ea(rs, imm16)))
        case 0x24: setGPR(rt, value: UInt32(read8(address: ea(rs, imm16))))
        case 0x25: setGPR(rt, value: UInt32(read16(address: ea(rs, imm16))))
        case 0x26: // LWR
            let addr = ea(rs, imm16)
            let aligned = addr & ~3
            let word = read32(address: aligned)
            let shift = (addr & 3) * 8
            let mask = shift == 0 ? 0 : (UInt32(0xFFFF_FFFF) << (32 - shift))
            setGPR(rt, value: (gpr[rt] & mask) | (word >> shift))
        case 0x28: write8(address: ea(rs, imm16), value: UInt8(gpr[rt] & 0xFF))
        case 0x29: write16(address: ea(rs, imm16), value: UInt16(gpr[rt] & 0xFFFF))
        case 0x2A: // SWL
            let addr = ea(rs, imm16)
            let aligned = addr & ~3
            let word = read32(address: aligned)
            let shift = (addr & 3) * 8
            let mask = UInt32(0xFFFF_FF00) << shift
            write32(address: aligned, value: (word & mask) | (gpr[rt] >> (24 - shift)))
        case 0x2B: write32(address: ea(rs, imm16), value: gpr[rt])
        case 0x2E: // SWR
            let addr = ea(rs, imm16)
            let aligned = addr & ~3
            let word = read32(address: aligned)
            let shift = (addr & 3) * 8
            let mask = shift == 0 ? 0 : (UInt32(0xFFFF_FFFF) >> (32 - shift))
            write32(address: aligned, value: (word & mask) | (gpr[rt] << shift))
        default: break
        }
    }

    private func setGPR(_ i: Int, value: UInt32) { if i != 0 { gpr[i] = value } }
    private func ea(_ rs: Int, _ imm: Int32) -> UInt32 { UInt32(bitPattern: Int32(bitPattern: gpr[rs]) &+ imm) }
    private func branch(to address: UInt32) { inDelaySlot = true; nextPC = address }
    private func branchOffset(_ offset: Int32) { inDelaySlot = true; nextPC = UInt32(bitPattern: Int32(bitPattern: pc) &+ (offset << 2)) }
    private func jumpAbsolute(_ imm26: UInt32) { inDelaySlot = true; nextPC = (pc & 0xF000_0000) | (imm26 << 2) }
    private func triggerSyscall() {
        cop0Cause = (cop0Cause & ~(0x1F << 2)) | (8 << 2)
        let mode = cop0Status & 0x3F
        cop0Status = (cop0Status & ~0x3F) | ((mode << 2) & 0x3C)
        cop0EPC = pc &- 4
        inDelaySlot = false
        pc = ((cop0Status & (1 << 22)) != 0) ? 0xBFC00180 : 0x80000080
    }

    // MARK: - Memory

    func physicalAddress(_ v: UInt32) -> UInt32 { v & 0x1FFF_FFFF }

    func read8(address: UInt32) -> UInt8 {
        let p = physicalAddress(address)
        if p < ram.count { return ram[Int(p)] }
        if p >= 0x1FC0_0000 && p < 0x2000_0000, let bios = bus?.bios {
            let off = Int(p - 0x1FC0_0000)
            if off < bios.count { return bios[off] }
        }
        return readIO8(phys: p)
    }

    func read16(address: UInt32) -> UInt16 {
        UInt16(read8(address: address)) | (UInt16(read8(address: address &+ 1)) << 8)
    }

    func read32(address: UInt32) -> UInt32 {
        let p = physicalAddress(address)
        if p + 3 < ram.count {
            let off = Int(p & ~3)
            return ram.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self).littleEndian }
        }
        if p >= 0x1FC0_0000 && p + 3 < 0x2000_0000, let bios = bus?.bios {
            let off = Int((p - 0x1FC0_0000) & ~3)
            if off + 3 < bios.count {
                return bios.withUnsafeBytes { $0.load(fromByteOffset: off, as: UInt32.self).littleEndian }
            }
        }
        return readIO32(phys: p)
    }

    func write8(address: UInt32, value: UInt8) {
        let p = physicalAddress(address)
        if p < ram.count { ram[Int(p)] = value } else { writeIO8(phys: p, value: value) }
    }

    func write16(address: UInt32, value: UInt16) {
        write8(address: address, value: UInt8(value & 0xFF))
        write8(address: address &+ 1, value: UInt8(value >> 8))
    }

    func write32(address: UInt32, value: UInt32) {
        let p = physicalAddress(address)
        if p + 3 < ram.count {
            let off = Int(p & ~3)
            ram.withUnsafeMutableBytes { $0.storeBytes(of: value.littleEndian, toByteOffset: off, as: UInt32.self) }
        } else {
            writeIO32(phys: p, value: value)
        }
    }

    private func readIO8(phys: UInt32) -> UInt8 {
        switch phys {
        case 0x1F40_2000..<0x1F40_2020:
            return UInt8(cdvd?.readIO(offset: phys - 0x1F40_2000) ?? 0)
        case 0x1F80_1800..<0x1F80_1810:
            return UInt8(cdvd?.readIO(offset: phys - 0x1F80_1800) ?? 0)
        default:
            return UInt8((readIO32(phys: phys & ~3) >> ((phys & 3) * 8)) & 0xFF)
        }
    }

    private func readIO32(phys: UInt32) -> UInt32 {
        switch phys {
        case 0x1D00_0000: return bus?.sifMscom ?? 0
        case 0x1D00_0010: return bus?.sifSmcom ?? 0
        case 0x1D00_0020: return bus?.sifMsflag ?? 0
        case 0x1D00_0030: return bus?.sifSmflag ?? 0
        case 0x1D00_0040: return bus?.sifCtrl ?? 0xF000_0102
        case 0x1F80_1070: return iStat
        case 0x1F80_1074: return iMask
        case 0x1F80_1078:
            let prev = iCtrl
            iCtrl = 0
            return prev
        case 0x1F80_1100..<0x1F80_1130, 0x1F80_1480..<0x1F80_14B0:
            return UInt32(truncatingIfNeeded: cycles)
        case 0x1F80_1450: return 0 // IOP HW CFG
        case 0x1F80_1C00..<0x1F80_1E00: return spu2?.readIO(offset: phys - 0x1F80_1C00) ?? 0
        case 0x1F80_1800..<0x1F80_1810: return cdvd?.readIO(offset: phys - 0x1F80_1800) ?? 0
        default:
            if loggedUnmappedIOP.insert(phys).inserted {
                BootDiagLogger.shared.logHex("IOP-IO", "Unhandled READ32", addr: phys, val: 0)
            }
            return 0
        }
    }

    private func writeIO8(phys: UInt32, value: UInt8) {
        switch phys {
        case 0x1F40_2000..<0x1F40_2020:
            cdvd?.writeIO(offset: phys - 0x1F40_2000, value: UInt32(value))
        case 0x1F80_1800..<0x1F80_1810:
            cdvd?.writeIO(offset: phys - 0x1F80_1800, value: UInt32(value))
        default:
            break
        }
    }

    private func writeIO32(phys: UInt32, value: UInt32) {
        switch phys {
        case 0x1D00_0000: bus?.sifMscom = value
        case 0x1D00_0010: bus?.sifSmcom = value
        case 0x1D00_0020: bus?.sifMsflag &= ~value
        case 0x1D00_0030: bus?.sifSmflag |= value
        case 0x1D00_0040: bus?.sifCtrl = value
        case 0x1F80_1070: iStat &= value
        case 0x1F80_1074: iMask = value
        case 0x1F80_1078: iCtrl = value & 1
        case 0x1F80_1C00..<0x1F80_1E00: spu2?.writeIO(offset: phys - 0x1F80_1C00, value: value)
        case 0x1F80_1800..<0x1F80_1810: cdvd?.writeIO(offset: phys - 0x1F80_1800, value: value)
        default:
            if loggedUnmappedIOP.insert(phys).inserted {
                BootDiagLogger.shared.logHex("IOP-IO", "Unhandled WRITE32", addr: phys, val: value)
            }
            break
        }
    }
}
