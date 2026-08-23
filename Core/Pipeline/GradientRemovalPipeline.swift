import Foundation

/// The hybrid two-stage engine:
///
/// 1. **Physics** — the `AtmosphericModel` renders the non-linear airmass
///    baseline from telemetry and subtracts it first.
/// 2. **Math** — a low-order (1st/2nd degree) polynomial surface cleans up
///    remaining localized light domes and flat-field residuals.
///
/// This CPU implementation is the reference path (also exercised by the test
/// suite); the app's Metal kernel performs the same blend on GPU for display.
public struct GradientRemovalPipeline {
    public var telemetry: TelemetrySnapshot
    /// Effective imaging wavelengths per channel, micrometers. Used by
    /// `processPlanes` when the image's channel count matches; otherwise the
    /// single telemetry wavelength applies. Defaults to typical RGB camera
    /// bands — Rayleigh scattering goes as λ⁻⁴, so the blue channel's skyglow
    /// curve is far steeper than the red's.
    public var channelWavelengthsMicrons: [Double]
    public var degree: PolynomialFitter.Degree
    /// Physical-stage strength multiplier (1 = fully trust the model).
    public var physicsStrength: Float
    public var sampleSpacing: Int

    /// Approximate central wavelengths of consumer-camera R, G, B bands.
    public static let rgbWavelengthsMicrons: [Double] = [0.64, 0.53, 0.47]

    public init(
        telemetry: TelemetrySnapshot = TelemetrySnapshot(),
        channelWavelengthsMicrons: [Double] = GradientRemovalPipeline.rgbWavelengthsMicrons,
        degree: PolynomialFitter.Degree = .linear,
        physicsStrength: Float = 1,
        sampleSpacing: Int = 8
    ) {
        self.telemetry = telemetry
        self.channelWavelengthsMicrons = channelWavelengthsMicrons
        self.degree = degree
        self.physicsStrength = physicsStrength
        self.sampleSpacing = sampleSpacing
    }

    public struct Result {
        public let pixels: [Float]
        public let physicalPrior: [Float]
        public let polynomialSurface: [Float]
    }

    public func process(image: FITSImage) throws -> Result {
        try process(pixels: image.pixels, width: image.width, height: image.height)
    }

    /// Processes every channel of a color cube independently — skyglow is
    /// strongly color-dependent, so each plane gets its own scattering
    /// wavelength (via `channelWavelengthsMicrons`), prior gain, and surface
    /// fit. Returns one result per plane, in channel order.
    public func processPlanes(image: FITSImage) throws -> [Result] {
        try image.planes.enumerated().map { index, plane in
            var channelPipeline = self
            channelPipeline.telemetry.wavelengthMicrons = wavelength(
                forChannel: index, of: image.channelCount
            )
            return try channelPipeline.process(
                pixels: plane, width: image.width, height: image.height
            )
        }
    }

    /// The wavelength driving the Rayleigh/Mie model for one channel.
    public func wavelength(forChannel index: Int, of channelCount: Int) -> Double {
        guard channelCount > 1, channelCount == channelWavelengthsMicrons.count else {
            return telemetry.wavelengthMicrons
        }
        return channelWavelengthsMicrons[index]
    }

    public func process(pixels: [Float], width: Int, height: Int) throws -> Result {
        let model = AtmosphericModel(telemetry: telemetry)
        let prior = model.priorSurface(width: width, height: height)
        let afterPhysics = AtmosphericModel.subtract(
            pixels: pixels, prior: prior, strength: physicsStrength
        )

        let fitter = PolynomialFitter(degree: degree, sampleSpacing: sampleSpacing)
        let surface = try fitter.fit(pixels: afterPhysics, width: width, height: height)
        let rendered = surface.render()
        let mean = Float(surface.gridMean())
        var final = [Float](repeating: 0, count: afterPhysics.count)
        for k in 0 ..< afterPhysics.count {
            final[k] = max(afterPhysics[k] - (rendered[k] - mean), 0)
        }
        return Result(pixels: final, physicalPrior: prior, polynomialSurface: rendered)
    }
}
