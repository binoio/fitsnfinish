import Foundation

/// A snapshot of everything the physics stage needs to know about the
/// observing session, gathered from device telemetry, the image header, or
/// manual entry.
public struct TelemetrySnapshot: Equatable {
    /// Observer latitude/longitude in degrees (longitude east-positive).
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
    /// Direction of increasing altitude in the frame, degrees clockwise
    /// from the +Y (row) axis. 0 = "up" is along rows, the historical
    /// assumption; from a WCS this is north angle + parallactic angle.
    public var fieldRotationDegrees: Double
    /// Target equatorial coordinates, degrees — when present together with
    /// `observationDate`, pointing (and its drift across the exposure) is
    /// computed rather than taken from the manual altitude/azimuth.
    public var rightAscensionDegrees: Double?
    public var declinationDegrees: Double?
    /// Start of the exposure (UTC).
    public var observationDate: Date?
    /// Total integration time, seconds; with a date and RA/Dec the prior is
    /// averaged over the exposure.
    public var exposureSeconds: Double
    /// Include the lunar scattering term when the moon is up.
    public var moonlightEnabled: Bool
    /// Direction of the dominant artificial light dome, degrees from north.
    public var lightDomeAzimuthDegrees: Double
    /// Strength of the artificial light dome term (0 = off).
    public var lightDomeIntensity: Double

    public init(
        latitude: Double = 0,
        longitude: Double = 0,
        targetAltitudeDegrees: Double = 45,
        targetAzimuthDegrees: Double = 180,
        relativeHumidity: Double = 0.5,
        aerosolOpticalDepth: Double = 0.1,
        fieldOfViewDegrees: Double = 2,
        wavelengthMicrons: Double = 0.55,
        fieldRotationDegrees: Double = 0,
        rightAscensionDegrees: Double? = nil,
        declinationDegrees: Double? = nil,
        observationDate: Date? = nil,
        exposureSeconds: Double = 0,
        moonlightEnabled: Bool = true,
        lightDomeAzimuthDegrees: Double = 0,
        lightDomeIntensity: Double = 0
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.targetAltitudeDegrees = targetAltitudeDegrees
        self.targetAzimuthDegrees = targetAzimuthDegrees
        self.relativeHumidity = relativeHumidity
        self.aerosolOpticalDepth = aerosolOpticalDepth
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.wavelengthMicrons = wavelengthMicrons
        self.fieldRotationDegrees = fieldRotationDegrees
        self.rightAscensionDegrees = rightAscensionDegrees
        self.declinationDegrees = declinationDegrees
        self.observationDate = observationDate
        self.exposureSeconds = exposureSeconds
        self.moonlightEnabled = moonlightEnabled
        self.lightDomeAzimuthDegrees = lightDomeAzimuthDegrees
        self.lightDomeIntensity = lightDomeIntensity
    }
}

/// Deterministic physical skyglow model. Given telemetry, produces the
/// non-linear baseline across the frame that statistical tools would
/// otherwise have to chase with high-order polynomials:
///
/// - **airmass glow** — Rayleigh/Mie scattering through the Kasten–Young
///   airmass along each pixel's line of sight;
/// - **moonlight** — a Krisciunas–Schaefer scattering term for the moon's
///   position and phase (computed from time and place);
/// - **light dome** — a Garstang-style directional term for a dominant
///   artificial glow on a known azimuth;
/// - **time averaging** — with equatorial coordinates and an exposure
///   duration, the prior is averaged over the exposure as the target and
///   moon move.
public struct AtmosphericModel {
    public var telemetry: TelemetrySnapshot

    public init(telemetry: TelemetrySnapshot) {
        self.telemetry = telemetry
    }

    /// One time slice of the sky geometry.
    public struct SkySample: Equatable {
        public var altitudeCenterDegrees: Double
        public var azimuthCenterDegrees: Double
        public var moonAltitudeDegrees: Double
        public var moonAzimuthDegrees: Double
        /// Premultiplied moon strength: illuminance × extinction to the
        /// moon × 1/normalization; 0 disables the term.
        public var moonFactor: Double
    }

    /// Everything a renderer (CPU loop or Metal kernel) needs.
    public struct RenderModel: Equatable {
        public var opticalDepth: Double
        /// Extinction coefficient, magnitudes per airmass (1.086 τ).
        public var extinction: Double
        public var pixelScaleDegrees: Double
        public var rotationSine: Double
        public var rotationCosine: Double
        public var lightDomeAzimuthDegrees: Double
        public var lightDomeIntensity: Double
        public var samples: [SkySample]
    }

    /// Relative airmass for an apparent altitude (degrees) using the
    /// Kasten–Young (1989) formula, valid down to the horizon.
    public static func airmass(altitudeDegrees: Double) -> Double {
        let altitude = min(max(altitudeDegrees, 0), 90)
        let zenithAngle = 90 - altitude
        let cosZ = cos(zenithAngle * .pi / 180)
        return 1 / (cosZ + 0.50572 * pow(96.07995 - zenithAngle, -1.6364))
    }

    public var opticalDepth: Double {
        RayleighMie.totalOpticalDepth(
            wavelengthMicrons: telemetry.wavelengthMicrons,
            beta: telemetry.aerosolOpticalDepth,
            relativeHumidity: telemetry.relativeHumidity
        )
    }

    /// Relative scattered-skyglow intensity toward an apparent altitude
    /// (airmass term only).
    public func skyglow(altitudeDegrees: Double) -> Double {
        let x = Self.airmass(altitudeDegrees: altitudeDegrees)
        return 1 - exp(-opticalDepth * x)
    }

    // MARK: Sky geometry

    /// Builds the time samples: three across the exposure when equatorial
    /// coordinates and a start time are available, else a single static
    /// sample from the manual pointing.
    public func skySamples() -> [SkySample] {
        let τ = opticalDepth
        let k = 1.086 * τ

        func sample(at date: Date?) -> SkySample {
            var altitude = telemetry.targetAltitudeDegrees
            var azimuth = telemetry.targetAzimuthDegrees
            if let date, let ra = telemetry.rightAscensionDegrees,
               let dec = telemetry.declinationDegrees {
                let position = Astrometry.horizontal(
                    rightAscensionDegrees: ra, declinationDegrees: dec,
                    latitude: telemetry.latitude, longitude: telemetry.longitude,
                    date: date
                )
                altitude = position.altitudeDegrees
                azimuth = position.azimuthDegrees
            }

            var moonAlt = -90.0
            var moonAz = 0.0
            var moonFactor = 0.0
            if telemetry.moonlightEnabled, let date {
                let moon = Astrometry.moonState(date)
                let position = Astrometry.horizontal(
                    rightAscensionDegrees: moon.rightAscensionDegrees,
                    declinationDegrees: moon.declinationDegrees,
                    latitude: telemetry.latitude, longitude: telemetry.longitude,
                    date: date
                )
                moonAlt = position.altitudeDegrees
                moonAz = position.azimuthDegrees
                if moonAlt > 0 {
                    // Krisciunas & Schaefer (1991): lunar illuminance from
                    // phase angle, attenuated on the way in.
                    let α = abs(moon.phaseAngleDegrees)
                    let illuminance = pow(10, -0.4 * (3.84 + 0.026 * α + 4e-9 * pow(α, 4)))
                    let moonAirmass = Self.airmass(altitudeDegrees: moonAlt)
                    let attenuation = pow(10, -0.4 * k * moonAirmass)
                    // 1/50000 nL brings a typical bright-moon sky into the
                    // same relative units as the airmass glow; the overall
                    // prior amplitude is least-squares fitted anyway.
                    moonFactor = illuminance * attenuation / 50_000
                }
            }
            return SkySample(
                altitudeCenterDegrees: altitude,
                azimuthCenterDegrees: azimuth,
                moonAltitudeDegrees: moonAlt,
                moonAzimuthDegrees: moonAz,
                moonFactor: moonFactor
            )
        }

        guard let start = telemetry.observationDate else {
            return [sample(at: nil)]
        }
        let exposure = telemetry.exposureSeconds
        let trackable = telemetry.rightAscensionDegrees != nil
            && telemetry.declinationDegrees != nil
        guard trackable, exposure > 60 else {
            return [sample(at: start)]
        }
        return [0.0, 0.5, 1.0].map {
            sample(at: start.addingTimeInterval(exposure * $0))
        }
    }

    /// The complete parameter set for rendering the prior.
    public func renderModel(width: Int, height: Int) -> RenderModel {
        let τ = opticalDepth
        let θ = telemetry.fieldRotationDegrees * .pi / 180
        return RenderModel(
            opticalDepth: τ,
            extinction: 1.086 * τ,
            pixelScaleDegrees: telemetry.fieldOfViewDegrees / Double(max(width - 1, 1)),
            rotationSine: sin(θ),
            rotationCosine: cos(θ),
            lightDomeAzimuthDegrees: telemetry.lightDomeAzimuthDegrees,
            lightDomeIntensity: telemetry.lightDomeIntensity,
            samples: skySamples()
        )
    }

    /// Evaluates the full prior (airmass + dome + moon, sample-averaged) at
    /// one pixel. Shared reference for the CPU path; the Metal kernel
    /// mirrors this arithmetic.
    public static func evaluatePrior(
        model: RenderModel, x: Int, y: Int, width: Int, height: Int
    ) -> Double {
        let dx = (Double(x) - Double(width - 1) / 2) * model.pixelScaleDegrees
        let dy = (Double(y) - Double(height - 1) / 2) * model.pixelScaleDegrees
        let along = dx * model.rotationSine + dy * model.rotationCosine
        let across = dx * model.rotationCosine - dy * model.rotationSine

        var total = 0.0
        for sample in model.samples {
            let altitude = sample.altitudeCenterDegrees + along
            let clamped = min(max(altitude, 0), 90)
            let airmass = Self.airmass(altitudeDegrees: clamped)
            var value = 1 - exp(-model.opticalDepth * airmass)

            if model.lightDomeIntensity > 0 {
                let azimuth = sample.azimuthCenterDegrees
                    + across / max(cos(clamped * .pi / 180), 0.2)
                let azimuthDelta = (azimuth - model.lightDomeAzimuthDegrees) * .pi / 180
                value += model.lightDomeIntensity
                    * exp(-max(clamped, 0) / 10)
                    * (1 + cos(azimuthDelta)) / 2
            }

            if sample.moonFactor > 0 {
                let azimuth = sample.azimuthCenterDegrees
                    + across / max(cos(clamped * .pi / 180), 0.2)
                let separation = Astrometry.separation(
                    Astrometry.Horizontal(altitudeDegrees: clamped, azimuthDegrees: azimuth),
                    Astrometry.Horizontal(
                        altitudeDegrees: sample.moonAltitudeDegrees,
                        azimuthDegrees: sample.moonAzimuthDegrees
                    )
                )
                let ρ = max(separation, 1)
                let cosρ = cos(ρ * .pi / 180)
                let scattering = pow(10, 5.36) * (1.06 + cosρ * cosρ)
                    + pow(10, 6.15 - ρ / 40)
                let selfAbsorption = 1 - pow(10, -0.4 * model.extinction * airmass)
                value += sample.moonFactor * scattering * selfAbsorption
            }
            total += value
        }
        return total / Double(model.samples.count)
    }

    /// Renders the physical prior for a `width × height` frame. Row 0 is
    /// the bottom of the frame (FITS convention).
    public func priorSurface(width: Int, height: Int) -> [Float] {
        precondition(width > 0 && height > 0)
        let model = renderModel(width: width, height: height)
        var surface = [Float](repeating: 0, count: width * height)

        // Fast path: no rotation, no dome, no moon — the prior is constant
        // along rows, so evaluate one column.
        let simple = model.rotationSine == 0
            && model.lightDomeIntensity == 0
            && model.samples.allSatisfy { $0.moonFactor == 0 }
        if simple {
            for y in 0 ..< height {
                let value = Float(Self.evaluatePrior(
                    model: model, x: (width - 1) / 2, y: y, width: width, height: height
                ))
                for x in 0 ..< width {
                    surface[y * width + x] = value
                }
            }
            return surface
        }

        for y in 0 ..< height {
            for x in 0 ..< width {
                surface[y * width + x] = Float(Self.evaluatePrior(
                    model: model, x: x, y: y, width: width, height: height
                ))
            }
        }
        return surface
    }

    /// Subtracts the physical prior from `pixels`, scaling via the fitted
    /// gain, clamping at zero. Returns the residual image.
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
