import Foundation

/// Serializes normalized float planes as a 16-bit FITS primary HDU
/// (BITPIX=16 with the conventional BZERO=32768 unsigned representation) —
/// NAXIS=2 for a single plane, NAXIS=3 for color cubes. Used for export and
/// for synthesizing test fixtures.
public enum FITSWriter {
    public static func data(pixels: [Float], width: Int, height: Int) -> Data {
        data(planes: [pixels], width: width, height: height)
    }

    public static func data(planes: [[Float]], width: Int, height: Int) -> Data {
        precondition(!planes.isEmpty)
        precondition(planes.allSatisfy { $0.count == width * height })
        var cards: [String] = [
            card("SIMPLE", "T", comment: "conforms to FITS standard"),
            card("BITPIX", "16", comment: "16-bit signed integers"),
            card("NAXIS", planes.count > 1 ? "3" : "2"),
            card("NAXIS1", String(width)),
            card("NAXIS2", String(height)),
        ]
        if planes.count > 1 {
            cards.append(card("NAXIS3", String(planes.count), comment: "color channels"))
        }
        cards.append(contentsOf: [
            card("BZERO", "32768", comment: "unsigned 16-bit representation"),
            card("BSCALE", "1"),
            "END".padding(toLength: FITSHeader.cardSize, withPad: " ", startingAt: 0),
        ])
        while cards.count * FITSHeader.cardSize % FITSHeader.blockSize != 0 {
            cards.append(String(repeating: " ", count: FITSHeader.cardSize))
        }
        var output = Data(cards.joined().utf8)

        for plane in planes {
            for value in plane {
                let clamped = min(max(value, 0), 1)
                let unsigned = UInt16((clamped * 65535).rounded())
                // Stored value = physical − BZERO, big-endian.
                let stored = Int16(bitPattern: unsigned &- 32768)
                withUnsafeBytes(of: stored.bigEndian) { output.append(contentsOf: $0) }
            }
        }
        let remainder = output.count % FITSHeader.blockSize
        if remainder != 0 {
            output.append(Data(count: FITSHeader.blockSize - remainder))
        }
        return output
    }

    private static func card(_ keyword: String, _ value: String, comment: String? = nil) -> String {
        var text = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
        text += "= "
        text += String(repeating: " ", count: max(0, 20 - value.count)) + value
        if let comment {
            text += " / " + comment
        }
        return text.padding(toLength: FITSHeader.cardSize, withPad: " ", startingAt: 0)
    }
}
