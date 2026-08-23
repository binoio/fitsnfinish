import Foundation
import CZLib

/// Reader for tile-compressed FITS images (the fpack convention): a BINTABLE
/// extension with ZIMAGE=T whose rows are compressed tiles of the original
/// image. Supports RICE_1 (integer data) and GZIP_1/GZIP_2 tiles; quantized
/// floating-point data is supported when stored without subtractive
/// dithering (ZQUANTIZ = NO_DITHER), since dithered reconstruction requires
/// the encoder's random sequence.
enum FITSTileDecompressor {
    // MARK: HDU walking

    /// Finds the first tile-compressed image extension after the primary HDU.
    static func read(data: Data, primaryHeader: FITSHeader) throws -> FITSImage {
        var offset = primaryHeader.byteCount + primaryHeader.dataByteCount
        while offset + FITSHeader.blockSize <= data.count {
            let header = try FITSHeader(data: data, byteOffset: offset)
            if header.string("XTENSION") == "BINTABLE", header.string("ZIMAGE") == "T" {
                return try decompress(data: data, header: header, dataStart: offset + header.byteCount)
            }
            offset += header.byteCount + header.dataByteCount
        }
        throw FITSError.unsupportedAxisCount(0)
    }

    // MARK: Table layout

    private struct Column {
        let name: String
        let form: String
        let offset: Int
        let width: Int
    }

    private static func columns(of header: FITSHeader) throws -> [Column] {
        let fieldCount = try header.requiredInteger("TFIELDS")
        var columns: [Column] = []
        var offset = 0
        for n in 1 ... fieldCount {
            let name = header.string("TTYPE\(n)") ?? ""
            let form = header.string("TFORM\(n)") ?? ""
            let width = try formWidth(form)
            columns.append(Column(name: name, form: form, offset: offset, width: width))
            offset += width
        }
        return columns
    }

    private static func formWidth(_ form: String) throws -> Int {
        let repeatDigits = form.prefix { $0.isNumber }
        let count = Int(repeatDigits) ?? 1
        guard let type = form.dropFirst(repeatDigits.count).first else {
            throw FITSError.missingKeyword("TFORMn")
        }
        switch type {
        case "L", "B", "A": return count
        case "X": return (count + 7) / 8
        case "I": return count * 2
        case "J", "E": return count * 4
        case "K", "D", "C": return count * 8
        case "M": return count * 16
        case "P": return count * 8
        case "Q": return count * 16
        default: throw FITSError.unsupportedCompression("TFORM \(form)")
        }
    }

    // MARK: Raw value readers

    private static func readInt(_ data: Data, at offset: Int, bytes: Int) -> Int {
        var value = 0
        for k in 0 ..< bytes {
            value = value << 8 | Int(data[data.startIndex + offset + k])
        }
        return value
    }

    private static func readDouble(_ data: Data, at offset: Int, form: String) -> Double {
        if form.hasSuffix("E") {
            let bits = UInt32(readInt(data, at: offset, bytes: 4))
            return Double(Float(bitPattern: bits))
        }
        let bits = UInt64(readInt(data, at: offset, bytes: 8))
        return Double(bitPattern: bits)
    }

    // MARK: Decompression

    private static func decompress(
        data: Data, header: FITSHeader, dataStart: Int
    ) throws -> FITSImage {
        let zbitpix = try header.requiredInteger("ZBITPIX")
        let znaxis = try header.requiredInteger("ZNAXIS")
        guard znaxis == 2 || znaxis == 3 else { throw FITSError.unsupportedAxisCount(znaxis) }
        let width = try header.requiredInteger("ZNAXIS1")
        let height = try header.requiredInteger("ZNAXIS2")
        let channels = znaxis == 3 ? try header.requiredInteger("ZNAXIS3") : 1
        guard (1 ... 4).contains(channels) else { throw FITSError.unsupportedAxisCount(znaxis) }

        let compression = header.string("ZCMPTYPE") ?? ""

        let dims = [width, height, channels]
        let tile = [
            header.integer("ZTILE1") ?? width,
            header.integer("ZTILE2") ?? 1,
            header.integer("ZTILE3") ?? 1,
        ]
        let tilesPerAxis = zip(dims, tile).map { ($0 + $1 - 1) / $1 }
        let tileCount = tilesPerAxis.reduce(1, *)

        let rowBytes = try header.requiredInteger("NAXIS1")
        let rows = try header.requiredInteger("NAXIS2")
        guard rows == tileCount else {
            throw FITSError.unsupportedCompression("row count \(rows) != tile count \(tileCount)")
        }
        let heapOffset = header.integer("THEAP") ?? rowBytes * rows
        let heapStart = dataStart + heapOffset

        let tableColumns = try columns(of: header)
        guard let dataColumn = tableColumns.first(where: {
            $0.name == "COMPRESSED_DATA" || $0.name == "GZIP_COMPRESSED_DATA"
        }) else {
            throw FITSError.missingKeyword("COMPRESSED_DATA")
        }
        let scaleColumn = tableColumns.first { $0.name == "ZSCALE" }
        let zeroColumn = tableColumns.first { $0.name == "ZZERO" }
        let quantized = scaleColumn != nil && zeroColumn != nil
        if quantized {
            // Subtractive dithering needs the encoder's random sequence to
            // reconstruct; only undithered quantization is supported.
            let method = header.string("ZQUANTIZ") ?? "NO_DITHER"
            guard method == "NO_DITHER" || method == "NONE" else {
                throw FITSError.unsupportedCompression("quantization \(method)")
            }
        }

        // RICE parameters from ZNAMEn/ZVALn pairs.
        var blockSize = 32
        var bytePix = max(abs(zbitpix) / 8, 1)
        var n = 1
        while let name = header.string("ZNAME\(n)") {
            if name == "BLOCKSIZE" { blockSize = header.integer("ZVAL\(n)") ?? 32 }
            if name == "BYTEPIX" { bytePix = header.integer("ZVAL\(n)") ?? bytePix }
            n += 1
        }

        var physical = [Double](repeating: 0, count: width * height * channels)

        for row in 0 ..< rows {
            let rowStart = dataStart + row * rowBytes
            let (count, heapPointer): (Int, Int)
            if dataColumn.form.contains("Q") {
                count = readInt(data, at: rowStart + dataColumn.offset, bytes: 8)
                heapPointer = readInt(data, at: rowStart + dataColumn.offset + 8, bytes: 8)
            } else {
                count = readInt(data, at: rowStart + dataColumn.offset, bytes: 4)
                heapPointer = readInt(data, at: rowStart + dataColumn.offset + 4, bytes: 4)
            }
            let tileStart = heapStart + heapPointer
            guard count >= 0, tileStart + count <= data.count else {
                throw FITSError.truncatedData(expected: count, actual: max(data.count - tileStart, 0))
            }
            let compressed = [UInt8](data.subdata(in: tileStart ..< tileStart + count))

            // This tile's position and clipped extent.
            let tx = row % tilesPerAxis[0]
            let ty = (row / tilesPerAxis[0]) % tilesPerAxis[1]
            let tz = row / (tilesPerAxis[0] * tilesPerAxis[1])
            let x0 = tx * tile[0], y0 = ty * tile[1], z0 = tz * tile[2]
            let tw = min(tile[0], width - x0)
            let th = min(tile[1], height - y0)
            let td = min(tile[2], channels - z0)
            let pixelCount = tw * th * td

            let values: [Double]
            switch compression {
            case "RICE_1", "RICE_ONE":
                let decoded = try riceDecode(
                    compressed, pixelCount: pixelCount,
                    blockSize: blockSize, bytePix: bytePix
                )
                values = decoded.map { raw -> Double in
                    switch bytePix {
                    case 1: return Double(UInt8(truncatingIfNeeded: raw))
                    case 2: return Double(Int16(truncatingIfNeeded: raw))
                    default: return Double(raw)
                    }
                }
            case "GZIP_1", "GZIP_2":
                var bytes = try zlibInflate(compressed)
                // Quantized floating-point tiles travel as 32-bit integers
                // regardless of ZBITPIX; unquantized tiles keep the original
                // pixel type.
                let effectiveType = quantized ? 32 : zbitpix
                let unit = abs(effectiveType) / 8
                guard bytes.count == pixelCount * unit else {
                    throw FITSError.truncatedData(expected: pixelCount * unit, actual: bytes.count)
                }
                if compression == "GZIP_2" {
                    bytes = unshuffle(bytes, unit: unit, count: pixelCount)
                }
                values = decodeBigEndian(bytes, bitpix: effectiveType, count: pixelCount)
            default:
                throw FITSError.unsupportedCompression(compression)
            }

            var mapped = values
            if quantized, let scaleColumn, let zeroColumn {
                let scale = readDouble(data, at: rowStart + scaleColumn.offset, form: scaleColumn.form)
                let zero = readDouble(data, at: rowStart + zeroColumn.offset, form: zeroColumn.form)
                mapped = values.map { zero + scale * $0 }
            }

            // Scatter the tile into the full frame (axis 1 fastest).
            var k = 0
            for dz in 0 ..< td {
                for dy in 0 ..< th {
                    let rowBase = ((z0 + dz) * height + (y0 + dy)) * width + x0
                    for dx in 0 ..< tw {
                        physical[rowBase + dx] = mapped[k]
                        k += 1
                    }
                }
            }
        }

        // Quantized data reconstructs the original float image regardless of
        // the integer storage type it traveled in.
        let effectiveBitpix = quantized ? -32 : zbitpix
        let planes = try FITSReader.normalizedPlanes(
            physical: physical, bitpix: effectiveBitpix,
            bzero: header.bzero, bscale: header.bscale,
            width: width, height: height, channels: channels
        )
        return FITSImage(header: header, width: width, height: height, planes: planes)
    }

    // MARK: Byte utilities

    static func decodeBigEndian(_ bytes: [UInt8], bitpix: Int, count: Int) -> [Double] {
        var out = [Double](repeating: 0, count: count)
        let unit = abs(bitpix) / 8
        for k in 0 ..< count {
            var raw: UInt64 = 0
            for b in 0 ..< unit {
                raw = raw << 8 | UInt64(bytes[k * unit + b])
            }
            switch bitpix {
            case 8: out[k] = Double(raw)
            case 16: out[k] = Double(Int16(truncatingIfNeeded: Int(raw)))
            case 32: out[k] = Double(Int32(truncatingIfNeeded: Int(raw)))
            case -32: out[k] = Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
            case -64: out[k] = Double(bitPattern: raw)
            default: out[k] = 0
            }
        }
        return out
    }

    /// GZIP_2 shuffles bytes by significance (all most-significant bytes
    /// first); this restores value order.
    static func unshuffle(_ bytes: [UInt8], unit: Int, count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes.count)
        for b in 0 ..< unit {
            for k in 0 ..< count {
                out[k * unit + b] = bytes[b * count + k]
            }
        }
        return out
    }

    // MARK: zlib

    static func zlibInflate(_ input: [UInt8]) throws -> [UInt8] {
        var stream = z_stream()
        // 15 + 32: max window, auto-detect zlib or gzip headers.
        let initStatus = inflateInit2_(
            &stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw FITSError.unsupportedCompression("zlib init \(initStatus)")
        }
        defer { inflateEnd(&stream) }

        var output: [UInt8] = []
        let chunkSize = 1 << 16
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var source = input
        return try source.withUnsafeMutableBufferPointer { inBuffer -> [UInt8] in
            stream.next_in = inBuffer.baseAddress
            stream.avail_in = uInt(inBuffer.count)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBufferPointer { outBuffer in
                    stream.next_out = outBuffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: chunk[0 ..< produced])
                }
                if status == Z_STREAM_END { return output }
                guard status == Z_OK else {
                    throw FITSError.unsupportedCompression("zlib inflate \(status)")
                }
                if stream.avail_in == 0 && produced == 0 {
                    throw FITSError.truncatedData(expected: 0, actual: output.count)
                }
            }
        }
    }

    // MARK: Rice

    struct BitReader {
        let bytes: [UInt8]
        var bitPosition = 0

        mutating func bit() throws -> Int {
            let byteIndex = bitPosition >> 3
            guard byteIndex < bytes.count else {
                throw FITSError.truncatedData(expected: byteIndex + 1, actual: bytes.count)
            }
            let bit = (Int(bytes[byteIndex]) >> (7 - (bitPosition & 7))) & 1
            bitPosition += 1
            return bit
        }

        mutating func bits(_ n: Int) throws -> Int {
            var value = 0
            for _ in 0 ..< n {
                value = value << 1 | (try bit())
            }
            return value
        }
    }

    /// Rice decompression (the RICE_1 convention used by fpack/CFITSIO):
    /// a raw first value seeds a running predictor; each block of
    /// `blockSize` pixels carries a split-position code `fs`, then each
    /// pixel's mapped difference as a unary prefix plus `fs` low bits.
    static func riceDecode(
        _ input: [UInt8], pixelCount: Int, blockSize: Int, bytePix: Int
    ) throws -> [Int32] {
        let fsbits: Int
        let fsmax: Int
        switch bytePix {
        case 1: fsbits = 3; fsmax = 6
        case 2: fsbits = 4; fsmax = 14
        case 4: fsbits = 5; fsmax = 25
        default: throw FITSError.unsupportedCompression("RICE BYTEPIX \(bytePix)")
        }
        let rawBits = bytePix * 8

        var reader = BitReader(bytes: input)
        var out = [Int32](repeating: 0, count: pixelCount)
        var lastPixel = Int32(truncatingIfNeeded: try reader.bits(rawBits))

        func unmap(_ mapped: UInt32) -> Int32 {
            mapped & 1 == 0 ? Int32(bitPattern: mapped >> 1) : ~Int32(bitPattern: mapped >> 1)
        }

        var i = 0
        while i < pixelCount {
            let blockEnd = min(i + blockSize, pixelCount)
            let fs = try reader.bits(fsbits) - 1
            if fs < 0 {
                while i < blockEnd {
                    out[i] = lastPixel
                    i += 1
                }
            } else if fs == fsmax {
                while i < blockEnd {
                    let mapped = UInt32(try reader.bits(rawBits))
                    lastPixel = lastPixel &+ unmap(mapped)
                    out[i] = lastPixel
                    i += 1
                }
            } else {
                while i < blockEnd {
                    var leading = 0
                    while try reader.bit() == 0 {
                        leading += 1
                        guard leading <= 64 else {
                            throw FITSError.unsupportedCompression("RICE stream corrupt")
                        }
                    }
                    var mapped = UInt32(leading) << fs
                    if fs > 0 {
                        mapped |= UInt32(try reader.bits(fs))
                    }
                    lastPixel = lastPixel &+ unmap(mapped)
                    out[i] = lastPixel
                    i += 1
                }
            }
        }
        return out
    }
}
