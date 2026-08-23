import Foundation

/// Swift port of the HCOMPRESS_1 tile decoder (CFITSIO
/// `fits_hdecompress.c`, itself derived from the AURA hcompress sources):
/// quadtree-coded bit planes of an H-transform, followed by undigitization
/// and the inverse transform with optional smoothing.
enum HCompress {
    private static let magic: [UInt8] = [0xDD, 0x99]

    /// Decompresses one tile. `smooth` and `scale` behavior mirror
    /// `fits_hdecompress`; the returned array is row-major with the fast
    /// axis last (matching FITS tile order).
    static func decode(_ input: [UInt8], smooth: Bool) throws -> (pixels: [Int32], width: Int, height: Int) {
        var reader = ByteInput(bytes: input)
        guard reader.read(2) == magic else {
            throw FITSError.unsupportedCompression("HCOMPRESS bad magic")
        }
        // NOTE: nx is the slow axis here, ny the fast axis.
        let nx = reader.readInt32()
        let ny = reader.readInt32()
        let scale = reader.readInt32()
        let sumAll = reader.readInt64()
        guard nx > 0, ny > 0, nx * ny <= 100_000_000 else {
            throw FITSError.unsupportedCompression("HCOMPRESS bad dimensions")
        }
        let nbitplanes = (0 ..< 3).map { _ in Int(reader.readByte()) }

        var a = [Int32](repeating: 0, count: nx * ny)
        try dodecode(&reader, a: &a, nx: nx, ny: ny, nbitplanes: nbitplanes)
        a[0] = Int32(truncatingIfNeeded: sumAll)

        undigitize(&a, count: nx * ny, scale: scale)
        hinv(&a, nx: nx, ny: ny, smooth: smooth, scale: scale)
        return (a, ny, nx)
    }

    // MARK: Byte/bit input

    private struct ByteInput {
        let bytes: [UInt8]
        var position = 0
        var bitBuffer = 0
        var bitsToGo = 0

        mutating func readByte() -> UInt8 {
            defer { position += 1 }
            return position < bytes.count ? bytes[position] : 0
        }

        mutating func read(_ n: Int) -> [UInt8] {
            (0 ..< n).map { _ in readByte() }
        }

        mutating func readInt32() -> Int {
            var v = 0
            for _ in 0 ..< 4 { v = v << 8 | Int(readByte()) }
            return Int(Int32(truncatingIfNeeded: v))
        }

        mutating func readInt64() -> Int64 {
            var v: Int64 = 0
            for _ in 0 ..< 8 { v = v << 8 | Int64(readByte()) }
            return v
        }

        mutating func startInputingBits() {
            bitsToGo = 0
        }

        mutating func inputBit() -> Int {
            if bitsToGo == 0 {
                bitBuffer = Int(readByte())
                bitsToGo = 8
            }
            bitsToGo -= 1
            return (bitBuffer >> bitsToGo) & 1
        }

        mutating func inputNBits(_ n: Int) -> Int {
            if bitsToGo < n {
                bitBuffer = bitBuffer << 8 | Int(readByte())
                bitsToGo += 8
            }
            bitsToGo -= n
            return (bitBuffer >> bitsToGo) & ((1 << n) - 1)
        }

        mutating func inputNybble() -> Int {
            inputNBits(4)
        }

        mutating func inputHuffman() -> Int {
            var c = inputNBits(3)
            if c < 4 { return 1 << c }
            c = inputBit() | (c << 1)
            if c < 13 {
                switch c {
                case 8: return 3
                case 9: return 5
                case 10: return 10
                case 11: return 12
                default: return 15 // c == 12
                }
            }
            c = inputBit() | (c << 1)
            if c < 31 {
                switch c {
                case 26: return 6
                case 27: return 7
                case 28: return 9
                case 29: return 11
                default: return 13 // c == 30
                }
            }
            c = inputBit() | (c << 1)
            return c == 62 ? 0 : 14
        }
    }

    // MARK: Decode stages

    private static func dodecode(
        _ reader: inout ByteInput, a: inout [Int32], nx: Int, ny: Int, nbitplanes: [Int]
    ) throws {
        let nel = nx * ny
        let nx2 = (nx + 1) / 2
        let ny2 = (ny + 1) / 2
        reader.startInputingBits()

        try qtreeDecode(&reader, a: &a, offset: 0, n: ny, nqx: nx2, nqy: ny2, nbitplanes: nbitplanes[0])
        try qtreeDecode(&reader, a: &a, offset: ny2, n: ny, nqx: nx2, nqy: ny / 2, nbitplanes: nbitplanes[1])
        try qtreeDecode(&reader, a: &a, offset: ny * nx2, n: ny, nqx: nx / 2, nqy: ny2, nbitplanes: nbitplanes[1])
        try qtreeDecode(&reader, a: &a, offset: ny * nx2 + ny2, n: ny, nqx: nx / 2, nqy: ny / 2, nbitplanes: nbitplanes[2])

        guard reader.inputNybble() == 0 else {
            throw FITSError.unsupportedCompression("HCOMPRESS bad bit plane values")
        }
        // Sign bits.
        reader.startInputingBits()
        for i in 0 ..< nel where a[i] != 0 {
            if reader.inputBit() != 0 { a[i] = -a[i] }
        }
    }

    private static func qtreeDecode(
        _ reader: inout ByteInput, a: inout [Int32], offset: Int,
        n: Int, nqx: Int, nqy: Int, nbitplanes: Int
    ) throws {
        let nqmax = max(nqx, nqy, 1)
        var log2n = Int((log(Double(nqmax)) / log(2.0) + 0.5).rounded(.down))
        if nqmax > (1 << log2n) { log2n += 1 }
        let nqx2 = (nqx + 1) / 2
        let nqy2 = (nqy + 1) / 2
        var scratch = [UInt8](repeating: 0, count: max(nqx2 * nqy2, 1))

        for bit in stride(from: nbitplanes - 1, through: 0, by: -1) {
            let b = reader.inputNybble()
            if b == 0 {
                readBDirect(&reader, a: &a, offset: offset, n: n, nqx: nqx, nqy: nqy, scratch: &scratch, bit: bit)
            } else if b != 0xF {
                throw FITSError.unsupportedCompression("HCOMPRESS bad format code")
            } else {
                scratch[0] = UInt8(reader.inputHuffman())
                var nx = 1, ny = 1
                var nfx = nqx, nfy = nqy
                var c = 1 << log2n
                for _ in 1 ..< max(log2n, 1) {
                    c >>= 1
                    nx <<= 1
                    ny <<= 1
                    if nfx <= c { nx -= 1 } else { nfx -= c }
                    if nfy <= c { ny -= 1 } else { nfy -= c }
                    qtreeExpand(&reader, b: &scratch, nx: nx, ny: ny)
                }
                qtreeBitins(scratch, nx: nqx, ny: nqy, b: &a, offset: offset, n: n, bit: bit)
            }
        }
    }

    private static func readBDirect(
        _ reader: inout ByteInput, a: inout [Int32], offset: Int,
        n: Int, nqx: Int, nqy: Int, scratch: inout [UInt8], bit: Int
    ) {
        let count = ((nqx + 1) / 2) * ((nqy + 1) / 2)
        for i in 0 ..< count {
            scratch[i] = UInt8(reader.inputNybble())
        }
        qtreeBitins(scratch, nx: nqx, ny: nqy, b: &a, offset: offset, n: n, bit: bit)
    }

    private static func qtreeExpand(_ reader: inout ByteInput, b: inout [UInt8], nx: Int, ny: Int) {
        qtreeCopy(&b, nx: nx, ny: ny, n: ny)
        for i in stride(from: nx * ny - 1, through: 0, by: -1) where b[i] != 0 {
            b[i] = UInt8(reader.inputHuffman())
        }
    }

    /// Expands packed 4-bit values into 2×2 blocks in place (works back to
    /// front so source and destination can share storage).
    private static func qtreeCopy(_ b: inout [UInt8], nx: Int, ny: Int, n: Int) {
        let nx2 = (nx + 1) / 2
        let ny2 = (ny + 1) / 2
        var k = ny2 * (nx2 - 1) + ny2 - 1
        for i in stride(from: nx2 - 1, through: 0, by: -1) {
            var s00 = 2 * (n * i + ny2 - 1)
            for _ in stride(from: ny2 - 1, through: 0, by: -1) {
                b[s00] = b[k]
                k -= 1
                s00 -= 2
            }
        }

        var i = 0
        while i < nx - 1 {
            var s00 = n * i
            var s10 = s00 + n
            var j = 0
            while j < ny - 1 {
                let v = b[s00]
                b[s10 + 1] = v & 1
                b[s10] = (v >> 1) & 1
                b[s00 + 1] = (v >> 2) & 1
                b[s00] = (v >> 3) & 1
                s00 += 2
                s10 += 2
                j += 2
            }
            if j < ny {
                let v = b[s00]
                b[s10] = (v >> 1) & 1
                b[s00] = (v >> 3) & 1
            }
            i += 2
        }
        if i < nx {
            var s00 = n * i
            var j = 0
            while j < ny - 1 {
                let v = b[s00]
                b[s00 + 1] = (v >> 2) & 1
                b[s00] = (v >> 3) & 1
                s00 += 2
                j += 2
            }
            if j < ny {
                b[s00] = (b[s00] >> 3) & 1
            }
        }
    }

    /// ORs the packed 4-bit codes into bit plane `bit` of the output array.
    private static func qtreeBitins(
        _ a: [UInt8], nx: Int, ny: Int, b: inout [Int32], offset: Int, n: Int, bit: Int
    ) {
        let plane = Int32(1 << bit)
        var k = 0
        var i = 0
        while i < nx - 1 {
            var s00 = offset + n * i
            var j = 0
            while j < ny - 1 {
                let v = Int32(a[k])
                if v & 1 != 0 { b[s00 + n + 1] |= plane }
                if v & 2 != 0 { b[s00 + n] |= plane }
                if v & 4 != 0 { b[s00 + 1] |= plane }
                if v & 8 != 0 { b[s00] |= plane }
                s00 += 2
                k += 1
                j += 2
            }
            if j < ny {
                let v = Int32(a[k])
                if v & 2 != 0 { b[s00 + n] |= plane }
                if v & 8 != 0 { b[s00] |= plane }
                k += 1
            }
            i += 2
        }
        if i < nx {
            var s00 = offset + n * i
            var j = 0
            while j < ny - 1 {
                let v = Int32(a[k])
                if v & 4 != 0 { b[s00 + 1] |= plane }
                if v & 8 != 0 { b[s00] |= plane }
                s00 += 2
                k += 1
                j += 2
            }
            if j < ny {
                if Int32(a[k]) & 8 != 0 { b[s00] |= plane }
                k += 1
            }
        }
    }

    private static func undigitize(_ a: inout [Int32], count: Int, scale: Int) {
        guard scale > 1 else { return }
        let s = Int32(scale)
        for i in 0 ..< count { a[i] &*= s }
    }

    // MARK: Inverse H-transform

    private static func unshuffle(_ a: inout [Int32], base: Int, n: Int, n2: Int, tmp: inout [Int32]) {
        let nhalf = (n + 1) >> 1
        var pt = 0
        var p1 = base + n2 * nhalf
        for _ in nhalf ..< n {
            tmp[pt] = a[p1]
            p1 += n2
            pt += 1
        }
        var p2 = base + n2 * (nhalf - 1)
        var q1 = base + 2 * n2 * (nhalf - 1)
        for _ in stride(from: nhalf - 1, through: 0, by: -1) {
            a[q1] = a[p2]
            p2 -= n2
            q1 -= 2 * n2
        }
        pt = 0
        p1 = base + n2
        var i = 1
        while i < n {
            a[p1] = tmp[pt]
            p1 += 2 * n2
            pt += 1
            i += 2
        }
    }

    private static func hsmooth(_ a: inout [Int32], nxtop: Int, nytop: Int, ny: Int, scale: Int) {
        let smax = Int32(scale >> 1)
        guard smax > 0 else { return }
        let ny2 = ny << 1

        func limitShift(_ value: Int32, shiftBits: Int) -> Int32 {
            value >= 0 ? value >> shiftBits : (value + Int32((1 << shiftBits) - 1)) >> shiftBits
        }

        var i = 2
        while i < nxtop - 2 {
            var s00 = ny * i
            var s10 = s00 + ny
            var j = 0
            while j < nytop {
                let hm = a[s00 - ny2], h0 = a[s00], hp = a[s00 + ny2]
                var diff = hp - hm
                let dmax = max(min(hp - h0, h0 - hm), 0) << 2
                let dmin = min(max(hp - h0, h0 - hm), 0) << 2
                if dmin < dmax {
                    diff = max(min(diff, dmax), dmin)
                    var s = diff - (a[s10] << 3)
                    s = limitShift(s, shiftBits: 3)
                    s = max(min(s, smax), -smax)
                    a[s10] = a[s10] + s
                }
                s00 += 2
                s10 += 2
                j += 2
            }
            i += 2
        }

        i = 0
        while i < nxtop {
            var s00 = ny * i + 2
            var j = 2
            while j < nytop - 2 {
                let hm = a[s00 - 2], h0 = a[s00], hp = a[s00 + 2]
                var diff = hp - hm
                let dmax = max(min(hp - h0, h0 - hm), 0) << 2
                let dmin = min(max(hp - h0, h0 - hm), 0) << 2
                if dmin < dmax {
                    diff = max(min(diff, dmax), dmin)
                    var s = diff - (a[s00 + 1] << 3)
                    s = limitShift(s, shiftBits: 3)
                    s = max(min(s, smax), -smax)
                    a[s00 + 1] = a[s00 + 1] + s
                }
                s00 += 2
                j += 2
            }
            i += 2
        }

        i = 2
        while i < nxtop - 2 {
            var s00 = ny * i + 2
            var s10 = s00 + ny
            var j = 2
            while j < nytop - 2 {
                let hmm = a[s00 - ny2 - 2], hpm = a[s00 + ny2 - 2]
                let hmp = a[s00 - ny2 + 2], hpp = a[s00 + ny2 + 2]
                let h0 = a[s00]
                var diff = hpp + hmm - hmp - hpm
                let hx2 = a[s10] << 1
                let hy2 = a[s00 + 1] << 1
                var m1 = min(max(hpp - h0, 0) - hx2 - hy2, max(h0 - hpm, 0) + hx2 - hy2)
                var m2 = min(max(h0 - hmp, 0) - hx2 + hy2, max(hmm - h0, 0) + hx2 + hy2)
                let dmax = min(m1, m2) << 4
                m1 = max(min(hpp - h0, 0) - hx2 - hy2, min(h0 - hpm, 0) + hx2 - hy2)
                m2 = max(min(h0 - hmp, 0) - hx2 + hy2, min(hmm - h0, 0) + hx2 + hy2)
                let dmin = max(m1, m2) << 4
                if dmin < dmax {
                    diff = max(min(diff, dmax), dmin)
                    var s = diff - (a[s10 + 1] << 6)
                    s = limitShift(s, shiftBits: 6)
                    s = max(min(s, smax), -smax)
                    a[s10 + 1] = a[s10 + 1] + s
                }
                s00 += 2
                s10 += 2
                j += 2
            }
            i += 2
        }
    }

    private static func hinv(_ a: inout [Int32], nx: Int, ny: Int, smooth: Bool, scale: Int) {
        let nmax = max(nx, ny)
        var log2n = Int((log(Double(nmax)) / log(2.0) + 0.5).rounded(.down))
        if nmax > (1 << log2n) { log2n += 1 }
        var tmp = [Int32](repeating: 0, count: (nmax + 1) / 2)

        var shift = 1
        var bit0 = Int32(1 << (log2n - 1))
        var bit1 = bit0 << 1
        var bit2 = bit0 << 2
        var mask0 = -bit0
        var mask1 = mask0 << 1
        let mask2 = mask0 << 2
        var prnd0 = bit0 >> 1
        var prnd1 = bit1 >> 1
        let prnd2 = bit2 >> 1
        var nrnd0 = prnd0 - 1
        var nrnd1 = prnd1 - 1
        let nrnd2 = prnd2 - 1

        a[0] = (a[0] + (a[0] >= 0 ? prnd2 : nrnd2)) & mask2

        var nxtop = 1, nytop = 1
        var nxf = nx, nyf = ny
        var c = 1 << log2n
        for k in stride(from: log2n - 1, through: 0, by: -1) {
            c >>= 1
            nxtop <<= 1
            nytop <<= 1
            if nxf <= c { nxtop -= 1 } else { nxf -= c }
            if nyf <= c { nytop -= 1 } else { nyf -= c }
            if k == 0 {
                nrnd0 = 0
                shift = 2
            }
            for i in 0 ..< nxtop {
                unshuffle(&a, base: ny * i, n: nytop, n2: 1, tmp: &tmp)
            }
            for j in 0 ..< nytop {
                unshuffle(&a, base: j, n: nxtop, n2: ny, tmp: &tmp)
            }
            if smooth { hsmooth(&a, nxtop: nxtop, nytop: nytop, ny: ny, scale: scale) }

            let oddx = nxtop % 2
            let oddy = nytop % 2
            var i = 0
            while i < nxtop - oddx {
                var s00 = ny * i
                var s10 = s00 + ny
                var j = 0
                while j < nytop - oddy {
                    var h0 = a[s00]
                    var hx = a[s10]
                    var hy = a[s00 + 1]
                    var hc = a[s10 + 1]
                    hx = (hx + (hx >= 0 ? prnd1 : nrnd1)) & mask1
                    hy = (hy + (hy >= 0 ? prnd1 : nrnd1)) & mask1
                    hc = (hc + (hc >= 0 ? prnd0 : nrnd0)) & mask0
                    let lowbit0 = hc & bit0
                    hx = hx >= 0 ? (hx - lowbit0) : (hx + lowbit0)
                    hy = hy >= 0 ? (hy - lowbit0) : (hy + lowbit0)
                    let lowbit1 = (hc ^ hx ^ hy) & bit1
                    h0 = h0 >= 0
                        ? (h0 + lowbit0 - lowbit1)
                        : (h0 + (lowbit0 == 0 ? lowbit1 : (lowbit0 - lowbit1)))
                    a[s10 + 1] = (h0 + hx + hy + hc) >> shift
                    a[s10] = (h0 + hx - hy - hc) >> shift
                    a[s00 + 1] = (h0 - hx + hy - hc) >> shift
                    a[s00] = (h0 - hx - hy + hc) >> shift
                    s00 += 2
                    s10 += 2
                    j += 2
                }
                if oddy != 0 {
                    var h0 = a[s00]
                    var hx = a[s10]
                    hx = (hx + (hx >= 0 ? prnd1 : nrnd1)) & mask1
                    let lowbit1 = hx & bit1
                    h0 = h0 >= 0 ? (h0 - lowbit1) : (h0 + lowbit1)
                    a[s10] = (h0 + hx) >> shift
                    a[s00] = (h0 - hx) >> shift
                }
                i += 2
            }
            if oddx != 0 {
                var s00 = ny * i
                var j = 0
                while j < nytop - oddy {
                    var h0 = a[s00]
                    var hy = a[s00 + 1]
                    hy = (hy + (hy >= 0 ? prnd1 : nrnd1)) & mask1
                    let lowbit1 = hy & bit1
                    h0 = h0 >= 0 ? (h0 - lowbit1) : (h0 + lowbit1)
                    a[s00 + 1] = (h0 + hy) >> shift
                    a[s00] = (h0 - hy) >> shift
                    s00 += 2
                    j += 2
                }
                if oddy != 0 {
                    a[s00] = a[s00] >> shift
                }
            }

            bit2 = bit1
            bit1 = bit0
            bit0 = bit0 >> 1
            mask1 = mask0
            mask0 = mask0 >> 1
            prnd1 = prnd0
            prnd0 = prnd0 >> 1
            nrnd1 = nrnd0
            nrnd0 = prnd0 - 1
        }
    }
}
