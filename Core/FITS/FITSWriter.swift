import Foundation

/// Serializes normalized float planes as a 16-bit FITS primary HDU
/// (BITPIX=16 with the conventional BZERO=32768 unsigned representation) —
/// NAXIS=2 for a single plane, NAXIS=3 for color cubes. Used for export and
/// for synthesizing test fixtures.
public enum FITSWriter {
    public static func data(pixels: [Float], width: Int, height: Int) -> Data {
        data(planes: [pixels], width: width, height: height)
    }

    /// Keywords copied verbatim from the source header on export, so plate
    /// solutions and provenance survive processing (the image is never
    /// resampled, so the WCS stays valid).
    static func isPreservedKeyword(_ keyword: String) -> Bool {
        let exact: Set<String> = [
            "WCSAXES", "LONPOLE", "LATPOLE", "EQUINOX", "EPOCH",
            "RADESYS", "RADECSYS", "MJD-OBS", "DATE-OBS", "OBJECT",
            "TELESCOP", "INSTRUME", "OBSERVER", "EXPTIME", "FOCALLEN",
        ]
        if exact.contains(keyword) { return true }
        for prefix in ["CTYPE", "CUNIT", "CRVAL", "CRPIX", "CDELT", "CROTA", "PV", "PC", "CD"]
        where keyword.hasPrefix(prefix) {
            let rest = keyword.dropFirst(prefix.count)
            if !rest.isEmpty, rest.allSatisfy({ $0.isNumber || $0 == "_" }) {
                return true
            }
        }
        return false
    }

    public static func data(
        planes: [[Float]], width: Int, height: Int,
        preservingFrom source: FITSHeader? = nil
    ) -> Data {
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
        ])
        if let source {
            for (keyword, value) in source.cards
            where isPreservedKeyword(keyword) && value != nil {
                var text = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
                text += "= " + value!
                cards.append(text.padding(
                    toLength: FITSHeader.cardSize, withPad: " ", startingAt: 0
                ))
            }
        }
        cards.append("END".padding(toLength: FITSHeader.cardSize, withPad: " ", startingAt: 0))
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
