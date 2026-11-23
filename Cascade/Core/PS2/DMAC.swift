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
    var sqwc:  UInt32 = 0    // stall quad-word count
    var rbsr:  UInt32 = 0    // ring buffer size
    var rbor:  UInt32 = 0    // ring buffer offset

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

        // Process up to 32 chain tags per step so display lists complete promptly
        var tagGuard = 0
        while channels[idx].active && tagGuard < 32 {
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

            let batchSize = min(channels[idx].qwc, 64)
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

        // If TTE (Tag Transfer Enable) is set, forward upper 64 bits of DMAtag to VIF/GIF
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
        if dstat & dmask != 0 { intc?.assertIRQ(bit: 3) }
    }

    // MARK: - I/O

    func read(offset: UInt32) -> UInt32 {
        let ch = Int((offset >> 8) & 0xF)
        switch offset & 0xFF {
        case 0x00: return ch < channels.count ? channels[ch].chcr : 0
        case 0x10: return ch < channels.count ? channels[ch].madr : 0
        case 0x20: return ch < channels.count ? channels[ch].qwc  : 0
        case 0x30: return ch < channels.count ? channels[ch].tadr : 0
        case 0xE0: return dstat
        case 0xF0: return dmask
        default:   return 0
        }
    }

    func write(offset: UInt32, value: UInt32) {
        let ch = Int((offset >> 8) & 0xF)
        switch offset & 0xFF {
        case 0x00:
            if ch < channels.count {
                channels[ch].chcr = value
                channels[ch].chainEnded = false
                if (value & (1 << 8)) != 0 { performTransfer(channel: ch) }
            }
        case 0x10: if ch < channels.count { channels[ch].madr = value }
        case 0x20: if ch < channels.count { channels[ch].qwc  = value }
        case 0x30: if ch < channels.count { channels[ch].tadr = value }
        case 0xE0:
            // Lower 16 bits of D_STAT are W1C; upper 16 bits toggle interrupt masks
            let clearBits = value & 0xFFFF
            let toggleMask = (value >> 16) & 0xFFFF
            dstat &= ~clearBits
            dmask ^= toggleMask
        case 0xF0: dmask = value
        default:   break
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
    weak var intc: INTC?

    func tick() {
        for i in 0..<4 {
            guard (mode[i] & (1 << 7)) != 0 || (mode[i] & 1) != 0 else { continue }
            count[i] &+= 1
            let target = comp[i] == 0 ? 0xFFFF : comp[i]
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
        let t = Int((offset >> 4) & 3)
        switch offset & 0xF {
        case 0: return count[t]
        case 4: return mode[t]
        case 8: return comp[t]
        default: return 0
        }
    }

    func write(offset: UInt32, value: UInt32) {
        let t = Int((offset >> 4) & 3)
        switch offset & 0xF {
        case 0: count[t] = value
        case 4:
            let w1c = value & ((1 << 10) | (1 << 11))
            mode[t] = (value & ~w1c) | (mode[t] & ~w1c)
        case 8: comp[t] = value
        default: break
        }
    }
}
