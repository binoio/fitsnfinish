import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Minimal reader for monolithic XISF files (the PixInsight native format,
/// also written by Siril): the primary Image element with UInt8/16/32 or
/// Float32/64 samples, Gray or RGB, planar or interleaved storage, raw or
/// zlib-compressed blocks (with optional byte shuffling). Embedded
/// FITSKeyword elements are surfaced as a synthetic FITS header so header
/// astrometry works identically.
enum XISFReader {
    static let signature = Data("XISF0100".utf8)

    static func isXISF(_ data: Data) -> Bool {
        data.count > 16 && data.prefix(8) == signature
    }

    private final class HeaderParser: NSObject, XMLParserDelegate {
        var imageAttributes: [String: String]?
        var fitsKeywords: [(String, String)] = []
        private var insideImage = false

        func parser(
            _ parser: XMLParser, didStartElement name: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            let local = name.components(separatedBy: ":").last ?? name
            if local == "Image", imageAttributes == nil {
                imageAttributes = attributes
                insideImage = true
            } else if local == "FITSKeyword", insideImage,
                      let keyword = attributes["name"], let value = attributes["value"] {
                fitsKeywords.append((keyword, value))
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            let local = name.components(separatedBy: ":").last ?? name
            if local == "Image" { insideImage = false }
        }
    }

    static func read(data: Data) throws -> FITSImage {
        guard isXISF(data) else {
            throw FITSError.unsupportedCompression("not an XISF file")
        }
        let headerLength = Int(
            UInt32(data[8]) | UInt32(data[9]) << 8
            | UInt32(data[10]) << 16 | UInt32(data[11]) << 24
        )
        guard 16 + headerLength <= data.count else {
            throw FITSError.truncatedData(expected: 16 + headerLength, actual: data.count)
        }
        let xml = data.subdata(in: 16 ..< 16 + headerLength)

        let delegate = HeaderParser()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        guard let attributes = delegate.imageAttributes else {
            throw FITSError.unsupportedCompression("XISF header has no Image element")
        }

        // geometry="W:H:C"
        let geometry = (attributes["geometry"] ?? "").split(separator: ":").compactMap { Int($0) }
        guard geometry.count >= 2 else {
            throw FITSError.unsupportedCompression("XISF geometry \(attributes["geometry"] ?? "?")")
        }
        let width = geometry[0]
        let height = geometry[1]
        let channels = geometry.count > 2 ? geometry[2] : 1
        guard width > 0, height > 0, (1 ... 4).contains(channels) else {
            throw FITSError.unsupportedAxisCount(geometry.count)
        }

        // location="attachment:offset:size"
        let location = (attributes["location"] ?? "").split(separator: ":")
        guard location.count == 3, location[0] == "attachment",
              let offset = Int(location[1]), let size = Int(location[2]),
              offset + size <= data.count
        else {
            throw FITSError.unsupportedCompression("XISF location \(attributes["location"] ?? "?")")
        }
        var block = [UInt8](data.subdata(in: offset ..< offset + size))

        // compression="codec[+sh]:uncompressed-size[:item-size]"
        if let compression = attributes["compression"], !compression.isEmpty {
            let parts = compression.split(separator: ":")
            let codec = String(parts[0])
            guard codec == "zlib" || codec == "zlib+sh" else {
                throw FITSError.unsupportedCompression("XISF codec \(codec)")
            }
            block = try FITSTileDecompressor.zlibInflate(block)
            if codec == "zlib+sh", parts.count >= 3, let itemSize = Int(parts[2]), itemSize > 1 {
                block = FITSTileDecompressor.unshuffle(
                    block, unit: itemSize, count: block.count / itemSize
                )
            }
        }

        let sampleFormat = attributes["sampleFormat"] ?? "UInt16"
        let count = width * height * channels
        var values = try decodeSamples(block, format: sampleFormat, count: count)

        // pixelStorage default Planar (channel-major); Normal is interleaved.
        if (attributes["pixelStorage"] ?? "Planar") == "Normal", channels > 1 {
            var planar = [Double](repeating: 0, count: count)
            let planeSize = width * height
            for k in 0 ..< planeSize {
                for c in 0 ..< channels {
                    planar[c * planeSize + k] = values[k * channels + c]
                }
            }
            values = planar
        }

        // Normalize to [0, 1].
        let normalized: [Double]
        switch sampleFormat {
        case "UInt8": normalized = values.map { $0 / 255 }
        case "UInt16": normalized = values.map { $0 / 65535 }
        case "UInt32": normalized = values.map { $0 / 4294967295 }
        default:
            // Floats honor the declared bounds, else data min/max.
            let bounds = (attributes["bounds"] ?? "").split(separator: ":")
                .compactMap { Double($0) }
            let lo = bounds.count == 2 ? bounds[0] : (values.min() ?? 0)
            let hi = bounds.count == 2 ? bounds[1] : (values.max() ?? 1)
            let span = max(hi - lo, .ulpOfOne)
            normalized = values.map { min(max(($0 - lo) / span, 0), 1) }
        }

        let planeSize = width * height
        let planes = (0 ..< channels).map { c in
            normalized[c * planeSize ..< (c + 1) * planeSize].map { Float($0) }
        }

        // XISF stores row 0 at the TOP; FITS convention (and this app) put
        // row 0 at the bottom — flip vertically.
        let flipped = planes.map { plane -> [Float] in
            var out = [Float](repeating: 0, count: planeSize)
            for y in 0 ..< height {
                let src = y * width
                let dst = (height - 1 - y) * width
                out[dst ..< dst + width] = plane[src ..< src + width]
            }
            return out
        }

        let header = try syntheticHeader(
            width: width, height: height, channels: channels,
            keywords: delegate.fitsKeywords
        )
        return FITSImage(header: header, width: width, height: height, planes: flipped)
    }

    private static func decodeSamples(
        _ bytes: [UInt8], format: String, count: Int
    ) throws -> [Double] {
        func le(_ index: Int, _ size: Int) -> UInt64 {
            var v: UInt64 = 0
            for b in stride(from: size - 1, through: 0, by: -1) {
                v = v << 8 | UInt64(bytes[index * size + b])
            }
            return v
        }
        let unit: Int
        switch format {
        case "UInt8": unit = 1
        case "UInt16": unit = 2
        case "UInt32", "Float32": unit = 4
        case "Float64": unit = 8
        default: throw FITSError.unsupportedCompression("XISF sampleFormat \(format)")
        }
        guard bytes.count >= count * unit else {
            throw FITSError.truncatedData(expected: count * unit, actual: bytes.count)
        }
        var out = [Double](repeating: 0, count: count)
        for k in 0 ..< count {
            switch format {
            case "UInt8": out[k] = Double(bytes[k])
            case "UInt16": out[k] = Double(le(k, 2))
            case "UInt32": out[k] = Double(le(k, 4))
            case "Float32": out[k] = Double(Float(bitPattern: UInt32(truncatingIfNeeded: le(k, 4))))
            default: out[k] = Double(bitPattern: le(k, 8))
            }
        }
        return out
    }

    /// Wraps embedded FITSKeyword elements in a real FITSHeader so the rest
    /// of the app (astrometry, WCS passthrough) treats XISF like FITS.
    private static func syntheticHeader(
        width: Int, height: Int, channels: Int, keywords: [(String, String)]
    ) throws -> FITSHeader {
        var cards = "SIMPLE  =                    T".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "BITPIX  =                   16".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS   =                    \(channels > 1 ? 3 : 2)"
            .padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS1  = \(width)".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS2  = \(height)".padding(toLength: 80, withPad: " ", startingAt: 0)
        if channels > 1 {
            cards += "NAXIS3  = \(channels)".padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        let reserved: Set<String> = ["SIMPLE", "BITPIX", "NAXIS", "NAXIS1", "NAXIS2", "NAXIS3", "END"]
        for (keyword, value) in keywords where !reserved.contains(keyword) {
            guard keyword.count <= 8, !value.isEmpty else { continue }
            var card = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
            card += "= " + value
            cards += card.prefix(80).padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        cards += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        var data = Data(cards.utf8)
        let remainder = data.count % FITSHeader.blockSize
        if remainder != 0 {
            data.append(Data(String(
                repeating: " ", count: FITSHeader.blockSize - remainder
            ).utf8))
        }
        return try FITSHeader(data: data)
    }
}
