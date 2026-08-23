import Foundation

/// Swift port of the IRAF PLIO line-list decoder (`pl_l2pi` from CFITSIO's
/// pliocomp.c), used for PLIO_1 tile compression of integer mask data.
enum PLIO {
    /// Decodes one encoded line list into `pixelCount` pixels.
    static func decode(_ words: [Int16], pixelCount: Int) throws -> [Int32] {
        var out = [Int32](repeating: 0, count: pixelCount)
        guard words.count >= 4 else {
            throw FITSError.unsupportedCompression("PLIO short header")
        }

        // Header (1-based ll_src in the reference): ll_src[3] > 0 means the
        // old format with the length in that word; otherwise the length is
        // split across words 4 and 5 and the data starts after ll_src[2].
        let listLength: Int
        var ip: Int // 1-based index of next word
        if words[2] > 0 {
            listLength = Int(words[2])
            ip = 4
        } else {
            guard words.count >= 5 else {
                throw FITSError.unsupportedCompression("PLIO short header")
            }
            listLength = (Int(words[4]) << 15) + Int(words[3])
            ip = Int(words[1]) + 1
        }
        guard pixelCount > 0, listLength > 0 else { return out }

        let xs = 1
        let xe = xs + pixelCount - 1
        var skipWord = false
        var op = 1 // 1-based output position
        var x1 = 1
        var pv = 1

        while ip <= listLength {
            defer { ip += 1 }
            if skipWord {
                skipWord = false
                continue
            }
            guard ip >= 1, ip <= words.count else {
                throw FITSError.unsupportedCompression("PLIO index out of range")
            }
            let word = Int(words[ip - 1])
            let opcode = word / 4096
            let data = word & 4095

            switch opcode {
            case 0, 4, 5:
                // A run: zeros (0), the current value (4), or zeros with
                // the current value at the end (5).
                let x2 = x1 + data - 1
                let i1 = max(x1, xs)
                let i2 = min(x2, xe)
                let np = i2 - i1 + 1
                if np > 0 {
                    let otop = op + np - 1
                    if opcode == 4 {
                        for i in op ... otop { out[i - 1] = Int32(pv) }
                    } else {
                        for i in op ... otop { out[i - 1] = 0 }
                        if opcode == 5 && i2 == x2 { out[otop - 1] = Int32(pv) }
                    }
                    op = otop + 1
                }
                x1 = x2 + 1
            case 1:
                // Set the high bits of the current value from the next word.
                guard ip + 1 <= words.count else {
                    throw FITSError.unsupportedCompression("PLIO truncated list")
                }
                pv = (Int(words[ip]) << 12) + data
                skipWord = true
            case 2:
                pv += data
            case 3:
                pv -= data
            case 6, 7:
                // Adjust the value and emit a single pixel.
                pv += opcode == 6 ? data : -data
                if x1 >= xs && x1 <= xe {
                    out[op - 1] = Int32(pv)
                    op += 1
                }
                x1 += 1
            default:
                break
            }
            if x1 > xe { break }
        }
        // Anything unwritten stays zero (already initialized).
        return out
    }
}
