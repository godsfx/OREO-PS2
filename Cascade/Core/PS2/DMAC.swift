import Foundation

// MARK: - EE DMA Controller
// 10 DMA channels for bulk transfers between RAM, GIF, VIF0/1, SPR, SIF0/1/2, IPU, etc.

public final class DMAC {

    static let channelCount = 10

    struct Channel {
        var madr: UInt32 = 0    // memory address
        var qwc:  UInt32 = 0    // quadword count
        var tadr: UInt32 = 0    // tag address
        var chcr: UInt32 = 0    // channel control
        var sadr: UInt32 = 0    // scratchpad address
        var chainEnded: Bool = false

        var active: Bool { (chcr & (1 << 8)) != 0 }
        var mode: UInt32 { (chcr >> 2) & 0x3 } // 0 = Normal, 1 = Chain, 2 = Interleave
        var tte: Bool    { (chcr & (1 << 6)) != 0 } // Tag Transfer Enable
    }

    var channels: [Channel] = Array(repeating: Channel(), count: DMAC.channelCount)
    var dstat: UInt32 = 0    // interrupt status
    var dmask: UInt32 = 0    // interrupt mask
    var ctrl:  UInt32 = 0    // global control
    var pcr:   UInt32 = 0    // priority control
    var sqwc:  UInt32 = 0    // stall quad-word count
    var rbsr:  UInt32 = 0    // ring buffer size
    var rbor:  UInt32 = 0    // ring buffer offset
    var stadr: UInt32 = 0    // stall address
    var enableW: UInt32 = 0

    weak var bus: MemoryBus?
    weak var intc: INTC?
    weak var gs: GraphicsSynthesizer?
    weak var vif0: VectorInterface?
    weak var vif1: VectorInterface?

    func step() {
        for i in 0..<DMAC.channelCount {
            guard channels[i].active else { continue }
            performTransfer(channel: i)
        }
    }

    private func performTransfer(channel idx: Int) {
        guard let bus = bus else {
            finishChannel(idx)
            return
        }

        var tagGuard = 0
        while channels[idx].active && tagGuard < 64 {
            tagGuard += 1

            if channels[idx].qwc == 0 {
                if channels[idx].mode == 1 && !channels[idx].chainEnded {
                    fetchNextSourceTag(channel: idx, bus: bus)
                }
                if channels[idx].qwc == 0 {
                    finishChannel(idx)
                    return
                }
            }

            let batchSize = min(channels[idx].qwc, 128)
            transferPayload(channel: idx, qwords: batchSize, bus: bus)

            if channels[idx].qwc == 0 && (channels[idx].mode != 1 || channels[idx].chainEnded) {
                finishChannel(idx)
                return
            }
        }
    }

    private func fetchNextSourceTag(channel idx: Int, bus: MemoryBus) {
        var ch = channels[idx]
        let tagAddr = ch.tadr & 0x1FFF_FFF0
        let lo = bus.read32(address: tagAddr)
        let hi = bus.read32(address: tagAddr + 4)

        let qwc = lo & 0xFFFF
        let id  = (lo >> 28) & 0x7

        if ch.tte && (idx == 0 || idx == 1) {
            let w2 = bus.read32(address: tagAddr + 8)
            let w3 = bus.read32(address: tagAddr + 12)
            if idx == 0 { vif0?.feed(words: [w2, w3]) }
            if idx == 1 { vif1?.feed(words: [w2, w3]) }
        }

        ch.qwc = qwc
        switch id {
        case 0: // refe: transfer qwc from addr, then end
            ch.madr = hi & 0x1FFF_FFF0
            ch.tadr &+= 16
            ch.chainEnded = true
        case 1: // cnt: transfer qwc following tag
            ch.madr = tagAddr &+ 16
            ch.tadr = ch.madr &+ (qwc * 16)
        case 2: // next: transfer qwc following tag, next tag at addr
            ch.madr = tagAddr &+ 16
            ch.tadr = hi & 0x1FFF_FFF0
        case 3, 4: // ref / refs: transfer qwc from addr, next tag follows current tag
            ch.madr = hi & 0x1FFF_FFF0
            ch.tadr = tagAddr &+ 16
        case 5: // call
            ch.madr = tagAddr &+ 16
            ch.tadr = hi & 0x1FFF_FFF0
        case 6: // ret
            ch.madr = tagAddr &+ 16
            ch.chainEnded = true
        case 7: // end: transfer qwc following tag, then end
            ch.madr = tagAddr &+ 16
            ch.tadr = ch.madr &+ (qwc * 16)
            ch.chainEnded = true
        default:
            ch.chainEnded = true
        }

        channels[idx] = ch
    }

    private func transferPayload(channel idx: Int, qwords: UInt32, bus: MemoryBus) {
        var ch = channels[idx]
        switch idx {
        case 0: // VIF0
            if let vif = vif0 {
                var words: [UInt32] = []
                words.reserveCapacity(Int(qwords * 4))
                for _ in 0..<(qwords * 4) {
                    words.append(bus.read32(address: ch.madr))
                    ch.madr &+= 4
                }
                ch.qwc -= qwords
                vif.feed(words: words)
            } else {
                ch.madr &+= qwords * 16
                ch.qwc  -= qwords
            }
        case 1: // VIF1
            if let vif = vif1 {
                var words: [UInt32] = []
                words.reserveCapacity(Int(qwords * 4))
                for _ in 0..<(qwords * 4) {
                    words.append(bus.read32(address: ch.madr))
                    ch.madr &+= 4
                }
                ch.qwc -= qwords
                vif.feed(words: words)
            } else {
                ch.madr &+= qwords * 16
                ch.qwc  -= qwords
            }
        case 2: // GIF — direct path to GS (2 x UInt64 per 128-bit QWORD)
            var gifData: [UInt64] = []
            gifData.reserveCapacity(Int(qwords * 2))
            for _ in 0..<qwords {
                let w0 = UInt64(bus.read32(address: ch.madr))
                let w1 = UInt64(bus.read32(address: ch.madr + 4))
                let w2 = UInt64(bus.read32(address: ch.madr + 8))
                let w3 = UInt64(bus.read32(address: ch.madr + 12))
                gifData.append(w0 | (w1 << 32))
                gifData.append(w2 | (w3 << 32))
                ch.madr &+= 16
                ch.qwc  -= 1
            }
            gs?.processGIFPacket(data: gifData, qwordCount: Int(qwords), flag: 0)
        case 8: // fromSPR (Scratchpad -> Main RAM)
            for _ in 0..<qwords {
                let sprOff = Int(ch.sadr & 0x3FF0)
                let q = bus.scratch.withUnsafeBytes { ptr in
                    let lo = ptr.load(fromByteOffset: sprOff, as: UInt64.self).littleEndian
                    let hi = ptr.load(fromByteOffset: sprOff + 8, as: UInt64.self).littleEndian
                    return UInt128(hi: hi, lo: lo)
                }
                bus.write128(address: ch.madr, value: q)
                ch.sadr = (ch.sadr &+ 16) & 0x3FF0
                ch.madr &+= 16
                ch.qwc  -= 1
            }
        case 9: // toSPR (Main RAM -> Scratchpad)
            for _ in 0..<qwords {
                let q = bus.read128(address: ch.madr)
                let sprOff = Int(ch.sadr & 0x3FF0)
                bus.scratch.withUnsafeMutableBytes { ptr in
                    ptr.storeBytes(of: q.lo.littleEndian, toByteOffset: sprOff, as: UInt64.self)
                    ptr.storeBytes(of: q.hi.littleEndian, toByteOffset: sprOff + 8, as: UInt64.self)
                }
                ch.sadr = (ch.sadr &+ 16) & 0x3FF0
                ch.madr &+= 16
                ch.qwc  -= 1
            }
        default:
            ch.madr &+= qwords * 16
            ch.qwc  -= qwords
        }
        channels[idx] = ch
    }

    private func finishChannel(_ idx: Int) {
        channels[idx].chcr &= ~(1 << 8)
        channels[idx].chainEnded = false
        dstat |= (1 << idx)
        checkInterrupt()
    }

    private func checkInterrupt() {
        if (dstat & dmask) != 0 { intc?.assertIRQ(bit: 3) }
    }

    // MARK: - Channel Base Mapping (PS2 EE DMAC)

    private func channelIndex(for offset: UInt32) -> Int? {
        switch offset & 0xFF00 {
        case 0x8000: return 0 // VIF0
        case 0x9000: return 1 // VIF1
        case 0xA000: return 2 // GIF
        case 0xB000: return 3 // fromIPU
        case 0xB400: return 4 // toIPU
        case 0xC000: return 5 // SIF0
        case 0xC400: return 6 // SIF1
        case 0xC800: return 7 // SIF2
        case 0xD000: return 8 // fromSPR
        case 0xD400: return 9 // toSPR
        default:     return nil
        }
    }

    // MARK: - I/O

    func read(offset: UInt32) -> UInt32 {
        if let ch = channelIndex(for: offset) {
            switch offset & 0xFF {
            case 0x00: return channels[ch].chcr
            case 0x10: return channels[ch].madr
            case 0x20: return channels[ch].qwc
            case 0x30: return channels[ch].tadr
            case 0x80: return channels[ch].sadr
            default:   return 0
            }
        }
        switch offset {
        case 0xE000: return ctrl
        case 0xE010: return dstat
        case 0xE020: return pcr
        case 0xE030: return sqwc
        case 0xE040: return rbsr
        case 0xE050: return rbor
        case 0xE060: return stadr
        case 0xF520: return enableW
        default:     return 0
        }
    }

    func write(offset: UInt32, value: UInt32) {
        if let ch = channelIndex(for: offset) {
            switch offset & 0xFF {
            case 0x00:
                channels[ch].chcr = value
                channels[ch].chainEnded = false
                if (value & (1 << 8)) != 0 { performTransfer(channel: ch) }
            case 0x10: channels[ch].madr = value
            case 0x20: channels[ch].qwc  = value
            case 0x30: channels[ch].tadr = value
            case 0x80: channels[ch].sadr = value
            default:   break
            }
            return
        }
        switch offset {
        case 0xE000: ctrl = value
        case 0xE010:
            // Lower 16 bits of D_STAT are W1C; upper 16 bits toggle interrupt masks
            let clearBits = value & 0xFFFF
            let toggleMask = (value >> 16) & 0xFFFF
            dstat &= ~clearBits
            dmask ^= toggleMask
        case 0xE020: pcr = value
        case 0xE030: sqwc = value
        case 0xE040: rbsr = value
        case 0xE050: rbor = value
        case 0xE060: stadr = value
        case 0xF590: enableW = value
        default:     break
        }
    }
}

// MARK: - INTC

public final class INTC {
    var stat: UInt32 = 0
    var mask: UInt32 = 0

    func assertIRQ(bit: Int) {
        stat |= (1 << bit)
    }

    func read(offset: UInt32) -> UInt32 {
        switch offset {
        case 0: return stat
        case 4: return mask
        default: return 0
        }
    }

    func write(offset: UInt32, value: UInt32) {
        switch offset {
        case 0: stat &= ~value
        case 4: mask ^= value // PS2 INTC_MASK writes toggle mask bits
        default: break
        }
    }
}

// MARK: - EE Timer

public final class EETimer {
    var count: [UInt32] = [0, 0, 0, 0]
    var mode:  [UInt32] = [0, 0, 0, 0]
    var comp:  [UInt32] = [0, 0, 0, 0]
    var hold:  [UInt32] = [0, 0, 0, 0]
    weak var intc: INTC?

    func tick() {
        for i in 0..<4 {
            guard (mode[i] & (1 << 7)) != 0 else { continue }
            count[i] = (count[i] &+ 1) & 0xFFFF
            let target = comp[i] == 0 ? 0xFFFF : (comp[i] & 0xFFFF)
            if count[i] >= target {
                if (mode[i] & (1 << 6)) != 0 { count[i] = 0 }
                mode[i] |= (1 << 10)
                if (mode[i] & (1 << 8)) != 0 {
                    intc?.assertIRQ(bit: 9 + i)
                }
            }
        }
    }

    func read(offset: UInt32) -> UInt32 {
        // Timer 0 = 0x0000, Timer 1 = 0x0800, Timer 2 = 0x1000, Timer 3 = 0x1800
        let t = Int((offset >> 11) & 3)
        switch offset & 0xFF {
        case 0x00:
            if (mode[t] & (1 << 7)) != 0 {
                count[t] = (count[t] &+ 1) & 0xFFFF
            }
            return count[t]
        case 0x10: return mode[t]
        case 0x20: return comp[t]
        case 0x30: return hold[t]
        default:   return 0
        }
    }

    func write(offset: UInt32, value: UInt32) {
        let t = Int((offset >> 11) & 3)
        switch offset & 0xFF {
        case 0x00: count[t] = value & 0xFFFF
        case 0x10:
            // Bits 10 and 11 are Write-1-to-Clear (EQUF, OVFF)
            let w1c = value & ((1 << 10) | (1 << 11))
            let preservedFlags = (mode[t] & ((1 << 10) | (1 << 11))) & ~w1c
            mode[t] = (value & ~((1 << 10) | (1 << 11))) | preservedFlags
        case 0x20: comp[t] = value & 0xFFFF
        case 0x30: hold[t] = value & 0xFFFF
        default:   break
        }
    }
}
