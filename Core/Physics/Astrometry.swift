import Foundation

/// Positional astronomy for the physics prior: sidereal time, equatorial ↔
/// horizontal conversion, and low-precision solar and lunar ephemerides
/// (truncated Meeus series, good to a few tenths of a degree — ample for
/// modeling sky-brightness gradients).
public enum Astrometry {
    // MARK: Time

    /// Julian date (UTC treated as UT1; sub-second precision is irrelevant
    /// at gradient-modeling accuracy).
    public static func julianDate(_ date: Date) -> Double {
        2440587.5 + date.timeIntervalSince1970 / 86400.0
    }

    /// Greenwich mean sidereal time, degrees in [0, 360).
    public static func greenwichSiderealTime(_ date: Date) -> Double {
        let d = julianDate(date) - 2451545.0
        let t = d / 36525.0
        let gmst = 280.46061837 + 360.98564736629 * d + 0.000387933 * t * t
        return normalized(gmst)
    }

    static func normalized(_ degrees: Double) -> Double {
        var v = degrees.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        return v
    }

    // MARK: Coordinate conversion

    public struct Horizontal: Equatable {
        /// Altitude above the horizon, degrees.
        public var altitudeDegrees: Double
        /// Azimuth from north through east, degrees in [0, 360).
        public var azimuthDegrees: Double
    }

    /// Converts equatorial (RA/Dec, degrees) to horizontal coordinates for
    /// an observer at `latitude`/`longitude` (east-positive) at `date`.
    public static func horizontal(
        rightAscensionDegrees ra: Double, declinationDegrees dec: Double,
        latitude: Double, longitude: Double, date: Date
    ) -> Horizontal {
        let lst = normalized(greenwichSiderealTime(date) + longitude)
        let hourAngle = normalized(lst - ra)
        let h = radians(hourAngle)
        let φ = radians(latitude)
        let δ = radians(dec)
        let sinAlt = sin(φ) * sin(δ) + cos(φ) * cos(δ) * cos(h)
        let altitude = degrees(asin(max(-1, min(1, sinAlt))))
        // Meeus azimuth is measured from south; convert to from-north.
        let azSouth = atan2(sin(h), cos(h) * sin(φ) - tan(δ) * cos(φ))
        let azimuth = normalized(degrees(azSouth) + 180)
        return Horizontal(altitudeDegrees: altitude, azimuthDegrees: azimuth)
    }

    /// Parallactic angle (degrees): the position angle of the zenith
    /// relative to celestial north at the target — needed to turn a WCS
    /// north angle into the direction "up" in the frame.
    public static func parallacticAngle(
        rightAscensionDegrees ra: Double, declinationDegrees dec: Double,
        latitude: Double, longitude: Double, date: Date
    ) -> Double {
        let lst = normalized(greenwichSiderealTime(date) + longitude)
        let h = radians(normalized(lst - ra))
        let φ = radians(latitude)
        let δ = radians(dec)
        return degrees(atan2(sin(h), tan(φ) * cos(δ) - sin(δ) * cos(h)))
    }

    /// Angular separation between two horizontal positions, degrees.
    public static func separation(_ a: Horizontal, _ b: Horizontal) -> Double {
        let a1 = radians(a.altitudeDegrees), a2 = radians(b.altitudeDegrees)
        let dAz = radians(a.azimuthDegrees - b.azimuthDegrees)
        let cosSep = sin(a1) * sin(a2) + cos(a1) * cos(a2) * cos(dAz)
        return degrees(acos(max(-1, min(1, cosSep))))
    }

    // MARK: Sun (Meeus low precision)

    /// Apparent ecliptic longitude of the sun, degrees.
    public static func sunEclipticLongitude(_ date: Date) -> Double {
        let t = (julianDate(date) - 2451545.0) / 36525.0
        let l0 = 280.46646 + 36000.76983 * t
        let m = radians(357.52911 + 35999.05029 * t)
        let c = (1.914602 - 0.004817 * t) * sin(m)
            + (0.019993 - 0.000101 * t) * sin(2 * m)
            + 0.000289 * sin(3 * m)
        return normalized(l0 + c)
    }

    static func obliquity(_ date: Date) -> Double {
        let t = (julianDate(date) - 2451545.0) / 36525.0
        return 23.4392911 - 0.0130042 * t
    }

    /// Equatorial position of the sun (RA/Dec, degrees).
    public static func sunPosition(_ date: Date) -> (ra: Double, dec: Double) {
        equatorial(eclipticLongitude: sunEclipticLongitude(date), eclipticLatitude: 0, date: date)
    }

    static func equatorial(
        eclipticLongitude λ: Double, eclipticLatitude β: Double, date: Date
    ) -> (ra: Double, dec: Double) {
        let ε = radians(obliquity(date))
        let lr = radians(λ)
        let br = radians(β)
        let ra = atan2(sin(lr) * cos(ε) - tan(br) * sin(ε), cos(lr))
        let dec = asin(sin(br) * cos(ε) + cos(br) * sin(ε) * sin(lr))
        return (normalized(degrees(ra)), degrees(dec))
    }

    // MARK: Moon (Meeus ch. 47, principal terms)

    public struct MoonState: Equatable {
        public var rightAscensionDegrees: Double
        public var declinationDegrees: Double
        /// Phase angle, degrees: 0 = full, 180 = new.
        public var phaseAngleDegrees: Double
        /// Illuminated fraction in [0, 1].
        public var illuminatedFraction: Double
    }

    public static func moonState(_ date: Date) -> MoonState {
        let t = (julianDate(date) - 2451545.0) / 36525.0
        let lp = radians(normalized(218.3164477 + 481267.88123421 * t))
        let d = radians(normalized(297.8501921 + 445267.1114034 * t))
        let m = radians(normalized(357.5291092 + 35999.0502909 * t))
        let mp = radians(normalized(134.9633964 + 477198.8675055 * t))
        let f = radians(normalized(93.2720950 + 483202.0175233 * t))

        // Principal longitude terms (degrees).
        var λ = degrees(lp)
        λ += 6.288774 * sin(mp)
        λ += 1.274027 * sin(2 * d - mp)
        λ += 0.658314 * sin(2 * d)
        λ += 0.213618 * sin(2 * mp)
        λ -= 0.185116 * sin(m)
        λ -= 0.114332 * sin(2 * f)
        λ += 0.058793 * sin(2 * d - 2 * mp)
        λ += 0.057066 * sin(2 * d - m - mp)
        λ += 0.053322 * sin(2 * d + mp)
        λ += 0.045758 * sin(2 * d - m)
        λ -= 0.040923 * sin(m - mp)
        λ -= 0.034720 * sin(d)
        λ -= 0.030383 * sin(m + mp)
        λ += 0.015327 * sin(2 * d - 2 * f)
        λ -= 0.012528 * sin(mp + 2 * f)
        λ += 0.010980 * sin(mp - 2 * f)
        λ += 0.010675 * sin(4 * d - mp)
        λ += 0.010034 * sin(3 * mp)
        λ += 0.008548 * sin(4 * d - 2 * mp)
        λ -= 0.007888 * sin(2 * d + m - mp)
        λ -= 0.006766 * sin(2 * d + m)
        λ -= 0.005163 * sin(d - mp)

        // Principal latitude terms (degrees).
        var β = 5.128122 * sin(f)
        β += 0.280602 * sin(mp + f)
        β += 0.277693 * sin(mp - f)
        β += 0.173237 * sin(2 * d - f)
        β += 0.055413 * sin(2 * d - mp + f)
        β += 0.046271 * sin(2 * d - mp - f)
        β += 0.032573 * sin(2 * d + f)
        β += 0.017198 * sin(2 * mp + f)
        β += 0.009266 * sin(2 * d + mp - f)
        β += 0.008822 * sin(2 * mp - f)

        let (ra, dec) = equatorial(eclipticLongitude: normalized(λ), eclipticLatitude: β, date: date)

        // Phase from elongation to the sun (distances neglected: the error
        // in phase angle is under ~0.3°).
        let sunλ = sunEclipticLongitude(date)
        let cosElongation = cos(radians(β)) * cos(radians(λ - sunλ))
        let elongation = degrees(acos(max(-1, min(1, cosElongation))))
        let phaseAngle = 180 - elongation
        let illuminated = (1 + cos(radians(phaseAngle))) / 2
        return MoonState(
            rightAscensionDegrees: ra,
            declinationDegrees: dec,
            phaseAngleDegrees: phaseAngle,
            illuminatedFraction: illuminated
        )
    }

    // MARK: Helpers

    static func radians(_ deg: Double) -> Double { deg * .pi / 180 }
    static func degrees(_ rad: Double) -> Double { rad * 180 / .pi }
}
