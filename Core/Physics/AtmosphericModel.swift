import Foundation

/// A snapshot of everything the physics stage needs to know about the
/// observing session, gathered from device telemetry (or entered manually).
public struct TelemetrySnapshot: Equatable {
    /// Observer latitude/longitude in degrees.
    public var latitude: Double
    public var longitude: Double
    /// Optical-axis pointing, degrees. Altitude 90° = zenith.
    public var targetAltitudeDegrees: Double
    public var targetAzimuthDegrees: Double
    /// Relative humidity in [0, 1].
    public var relativeHumidity: Double
    /// Aerosol optical depth at 1 µm (Ångström β turbidity coefficient).
    public var aerosolOpticalDepth: Double
    /// Field of view of the frame along its width, degrees.
    public var fieldOfViewDegrees: Double
    /// Effective imaging wavelength in micrometers (0.55 ≈ luminance).
    public var wavelengthMicrons: Double

    public init(
        latitude: Double = 0,
        longitude: Double = 0,
        targetAltitudeDegrees: Double = 45,
        targetAzimuthDegrees: Double = 180,
        relativeHumidity: Double = 0.5,
        aerosolOpticalDepth: Double = 0.1,
        fieldOfViewDegrees: Double = 2,
        wavelengthMicrons: Double = 0.55
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.targetAltitudeDegrees = targetAltitudeDegrees
        self.targetAzimuthDegrees = targetAzimuthDegrees
        self.relativeHumidity = relativeHumidity
        self.aerosolOpticalDepth = aerosolOpticalDepth
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.wavelengthMicrons = wavelengthMicrons
    }
}

/// Deterministic physical skyglow model. Given telemetry, produces the
/// non-linear atmospheric baseline across the frame that statistical tools
/// would otherwise have to chase with high-order polynomials.
public struct AtmosphericModel {
    public var telemetry: TelemetrySnapshot

    public init(telemetry: TelemetrySnapshot) {
        self.telemetry = telemetry
    }

    /// Relative airmass for an apparent altitude (degrees) using the
    /// Kasten–Young (1989) formula, valid down to the horizon.
    public static func airmass(altitudeDegrees: Double) -> Double {
        let altitude = min(max(altitudeDegrees, 0), 90)
        let zenithAngle = 90 - altitude
        let cosZ = cos(zenithAngle * .pi / 180)
        return 1 / (cosZ + 0.50572 * pow(96.07995 - zenithAngle, -1.6364))
    }

    /// Relative scattered-skyglow intensity toward an apparent altitude.
    ///
    /// Along a line of sight of airmass X through an atmosphere of optical
    /// depth τ, the fraction of incident light scattered into the beam is
    /// 1 − e^(−τX): it grows steeply (non-linearly) toward the horizon.
    public func skyglow(altitudeDegrees: Double) -> Double {
        let τ = RayleighMie.totalOpticalDepth(
            wavelengthMicrons: telemetry.wavelengthMicrons,
            beta: telemetry.aerosolOpticalDepth,
            relativeHumidity: telemetry.relativeHumidity
        )
        let x = Self.airmass(altitudeDegrees: altitudeDegrees)
        return 1 - exp(-τ * x)
    }

    /// Renders the physical prior for a `width × height` frame: the modeled
    /// skyglow at every pixel, in the same relative units for the whole frame.
    ///
    /// Row 0 is the *bottom* of the frame (FITS convention). The frame is
    /// assumed roughly aligned with the vertical: altitude varies along Y
    /// across `fieldOfViewDegrees * height / width`, azimuth along X (which
    /// only matters very near the horizon through its altitude coupling —
    /// treated as flat here).
    public func priorSurface(width: Int, height: Int) -> [Float] {
        precondition(width > 0 && height > 0)
        let fovY = telemetry.fieldOfViewDegrees * Double(height) / Double(width)
        var surface = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            let fraction = height > 1 ? Double(y) / Double(height - 1) - 0.5 : 0
            let altitude = telemetry.targetAltitudeDegrees + fraction * fovY
            let value = Float(skyglow(altitudeDegrees: altitude))
            for x in 0 ..< width {
                surface[y * width + x] = value
            }
        }
        return surface
    }

    /// Subtracts the physical prior from `pixels`, scaling the prior so its
    /// mean matches `strength` × the pixel background median estimate, and
    /// clamping at zero. Returns the residual image.
    public func subtractPrior(
        from pixels: [Float], width: Int, height: Int, strength: Float = 1
    ) -> [Float] {
        let prior = priorSurface(width: width, height: height)
        return AtmosphericModel.subtract(
            pixels: pixels, prior: prior, strength: strength
        )
    }

    /// Least-squares gain matching the prior's shape to the image: the `b` of
    /// fitting `a + b·prior` against the pixels, plus the prior mean. A flat
    /// prior carries no gradient information and yields gain 0.
    public static func priorGain(
        pixels: [Float], prior: [Float]
    ) -> (gain: Float, priorMean: Float) {
        precondition(pixels.count == prior.count)
        // Accumulate in Double: Float32 sums over megapixel frames lose
        // enough precision to visibly bias the fitted gain.
        let n = Double(pixels.count)
        var sumP = 0.0, sumI = 0.0, sumPP = 0.0, sumPI = 0.0
        for k in 0 ..< pixels.count {
            let p = Double(prior[k])
            let i = Double(pixels[k])
            sumP += p
            sumI += i
            sumPP += p * p
            sumPI += p * i
        }
        let meanPrior = Float(sumP / n)
        let denominator = n * sumPP - sumP * sumP
        guard abs(denominator) > Double.ulpOfOne * n else { return (0, meanPrior) }
        return (Float((n * sumPI - sumP * sumI) / denominator), meanPrior)
    }

    /// Removes the fitted prior component `b·(prior − mean(prior))` from the
    /// pixels, preserving the frame's overall pedestal and clamping at zero.
    public static func subtract(
        pixels: [Float], prior: [Float], strength: Float = 1
    ) -> [Float] {
        let (b, meanPrior) = priorGain(pixels: pixels, prior: prior)
        guard b != 0 else { return pixels }
        var result = [Float](repeating: 0, count: pixels.count)
        for k in 0 ..< pixels.count {
            let correction = strength * b * (prior[k] - meanPrior)
            result[k] = max(pixels[k] - correction, 0)
        }
        return result
    }
}
