import Foundation

/// Errors thrown while decoding a FITS primary header or data unit.
public enum FITSError: Error, Equatable, CustomStringConvertible {
    case truncatedHeader
    case notFITS
    case missingKeyword(String)
    case unsupportedBitpix(Int)
    case unsupportedAxisCount(Int)
    case truncatedData(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .truncatedHeader:
            return "FITS header ended before an END card was found"
        case .notFITS:
            return "File does not begin with a SIMPLE = T card"
        case .missingKeyword(let key):
            return "Required FITS keyword \(key) is missing"
        case .unsupportedBitpix(let bitpix):
            return "Unsupported BITPIX value \(bitpix)"
        case .unsupportedAxisCount(let naxis):
            return "Unsupported NAXIS value \(naxis); only 2-D images and 3-axis color cubes (up to 4 channels) are supported"
        case .truncatedData(let expected, let actual):
            return "FITS data unit truncated: expected \(expected) bytes, found \(actual)"
        }
    }
}

/// A parsed FITS primary header: an ordered list of 80-character cards plus
/// typed accessors for the keywords the reader needs.
public struct FITSHeader: Equatable {
    public static let blockSize = 2880
    public static let cardSize = 80

    /// Keyword → raw value string (comment stripped), in card order.
    public private(set) var cards: [(keyword: String, value: String?)] = []
    private var index: [String: String] = [:]

    /// Number of bytes the header occupies in the file (a multiple of 2880).
    public let byteCount: Int

    public static func == (lhs: FITSHeader, rhs: FITSHeader) -> Bool {
        lhs.index == rhs.index && lhs.byteCount == rhs.byteCount
    }

    /// Parses header blocks from the start of `data` until the END card.
    public init(data: Data) throws {
        var offset = 0
        var foundEnd = false

        while !foundEnd {
            guard offset + Self.blockSize <= data.count else {
                throw FITSError.truncatedHeader
            }
            let block = data.subdata(in: offset ..< offset + Self.blockSize)
            for cardStart in stride(from: 0, to: Self.blockSize, by: Self.cardSize) {
                let cardData = block.subdata(in: cardStart ..< cardStart + Self.cardSize)
                guard let card = String(data: cardData, encoding: .ascii) else { continue }
                let keyword = String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
                if keyword == "END" {
                    foundEnd = true
                    break
                }
                if keyword.isEmpty || keyword == "COMMENT" || keyword == "HISTORY" {
                    continue
                }
                var value: String?
                if card.count >= 10, card.dropFirst(8).hasPrefix("= ") {
                    let raw = String(card.dropFirst(10))
                    value = Self.stripComment(raw)
                }
                cards.append((keyword, value))
                if let value { index[keyword] = value }
            }
            offset += Self.blockSize
        }

        byteCount = offset
        guard string("SIMPLE") == "T" else { throw FITSError.notFITS }
    }

    /// Removes the trailing `/ comment` portion of a value field, honoring
    /// quoted strings.
    private static func stripComment(_ raw: String) -> String {
        var inQuote = false
        var result = ""
        for character in raw {
            if character == "'" { inQuote.toggle() }
            if character == "/" && !inQuote { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Typed accessors

    public func string(_ keyword: String) -> String? {
        guard var value = index[keyword] else { return nil }
        if value.hasPrefix("'") {
            value = String(value.dropFirst())
            if let end = value.firstIndex(of: "'") {
                value = String(value[value.startIndex ..< end])
            }
            value = value.trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    public func integer(_ keyword: String) -> Int? {
        index[keyword].flatMap { Int($0) }
    }

    public func double(_ keyword: String) -> Double? {
        index[keyword].flatMap { Double($0) }
    }

    // MARK: Required image keywords

    public func requiredInteger(_ keyword: String) throws -> Int {
        guard let value = integer(keyword) else { throw FITSError.missingKeyword(keyword) }
        return value
    }

    public var bitpix: Int { integer("BITPIX") ?? 0 }
    public var bzero: Double { double("BZERO") ?? 0 }
    public var bscale: Double { double("BSCALE") ?? 1 }
}
