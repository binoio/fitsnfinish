import Foundation

/// Pointing and timing information extracted from a FITS header — the
/// "plate solve" the file already carries: WCS solutions, capture-software
/// RA/Dec cards, observation time, and optics geometry.
public struct HeaderAstrometry: Equatable {
    public var rightAscensionDegrees: Double?
    public var declinationDegrees: Double?
    public var observationDate: Date?
    public var exposureSeconds: Double?
    /// Degrees per pixel on the sky.
    public var pixelScaleDegrees: Double?
    /// Position angle of celestial north in the image, degrees (from the
    /// WCS CD/PC matrix); nil when the file carries no orientation.
    public var northAngleDegrees: Double?

    public var hasPointing: Bool {
        rightAscensionDegrees != nil && declinationDegrees != nil
    }

    /// Extracts whatever the header provides; every field is optional.
    public init(header: FITSHeader) {
        // RA/Dec: a real WCS first, then capture-software conventions.
        if let ctype = header.string("CTYPE1"), ctype.hasPrefix("RA"),
           let ra = header.double("CRVAL1"), let dec = header.double("CRVAL2") {
            rightAscensionDegrees = ra
            declinationDegrees = dec
        } else if let ra = Self.angle(header, "RA", hoursWhenSexagesimal: true),
                  let dec = Self.angle(header, "DEC", hoursWhenSexagesimal: false) {
            rightAscensionDegrees = ra
            declinationDegrees = dec
        } else if let ra = Self.angle(header, "OBJCTRA", hoursWhenSexagesimal: true),
                  let dec = Self.angle(header, "OBJCTDEC", hoursWhenSexagesimal: false) {
            rightAscensionDegrees = ra
            declinationDegrees = dec
        }

        if let dateString = header.string("DATE-OBS") {
            observationDate = Self.parseDate(dateString)
        }
        exposureSeconds = header.double("EXPTIME") ?? header.double("EXPOSURE")

        // Pixel scale: CD matrix determinant, then CDELT, then optics.
        if let cd11 = header.double("CD1_1"), let cd12 = header.double("CD1_2"),
           let cd21 = header.double("CD2_1"), let cd22 = header.double("CD2_2") {
            let determinant = abs(cd11 * cd22 - cd12 * cd21)
            if determinant > 0 {
                pixelScaleDegrees = determinant.squareRoot()
            }
            northAngleDegrees = atan2(cd12, cd11) * 180 / .pi
        } else if let cdelt = header.double("CDELT1") {
            pixelScaleDegrees = abs(cdelt)
            if let crota = header.double("CROTA2") {
                northAngleDegrees = crota
            }
        } else if let pixelMicrons = header.double("XPIXSZ"),
                  let focalMillimeters = header.double("FOCALLEN"),
                  focalMillimeters > 0 {
            // Small-angle: scale(arcsec) = 206.265 × pixel(µm) / focal(mm).
            pixelScaleDegrees = 206.265 * pixelMicrons / focalMillimeters / 3600
        }
    }

    /// Reads an angle card that may be decimal degrees or a sexagesimal
    /// string ("2 33 41.6" / "+61 26 47").
    static func angle(
        _ header: FITSHeader, _ keyword: String, hoursWhenSexagesimal: Bool
    ) -> Double? {
        if let value = header.double(keyword) { return value }
        guard let text = header.string(keyword) else { return nil }
        let parts = text
            .replacingOccurrences(of: ":", with: " ")
            .split(separator: " ")
            .compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        let sign: Double = text.trimmingCharacters(in: .whitespaces).hasPrefix("-") ? -1 : 1
        var magnitude = abs(parts[0])
        if parts.count > 1 { magnitude += parts[1] / 60 }
        if parts.count > 2 { magnitude += parts[2] / 3600 }
        let degrees = sign * magnitude
        return hoursWhenSexagesimal ? degrees * 15 : degrees
    }

    static func parseDate(_ text: String) -> Date? {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
