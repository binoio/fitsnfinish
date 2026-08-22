import XCTest
@testable import FitsnFinishCore

final class SolverTests: XCTestCase {
    // MARK: Least-squares solver

    func testLeastSquaresRecoversExactSolution() throws {
        // Overdetermined but consistent: y = 2 + 3x.
        let xs: [Double] = [0, 1, 2, 3, 4]
        let a = xs.flatMap { [1.0, $0] }
        let b = xs.map { 2 + 3 * $0 }
        let solution = try LAPACKSolver.leastSquares(rowMajorA: a, rows: 5, columns: 2, b: b)
        XCTAssertEqual(solution[0], 2, accuracy: 1e-9)
        XCTAssertEqual(solution[1], 3, accuracy: 1e-9)
    }

    func testLeastSquaresMinimizesResidualWithNoise() throws {
        let xs = stride(from: 0.0, through: 9.0, by: 1.0).map { $0 }
        let noise: [Double] = [0.01, -0.02, 0.015, -0.01, 0.005, 0.02, -0.015, 0.01, -0.005, 0.0]
        let a = xs.flatMap { [1.0, $0] }
        let b = zip(xs, noise).map { 5 - 0.5 * $0 + $1 }
        let solution = try LAPACKSolver.leastSquares(rowMajorA: a, rows: 10, columns: 2, b: b)
        XCTAssertEqual(solution[0], 5, accuracy: 0.05)
        XCTAssertEqual(solution[1], -0.5, accuracy: 0.02)
    }

    func testPortableFallbackMatchesPrimarySolver() throws {
        let xs: [Double] = [0, 1, 2, 3, 4, 5]
        let a = xs.flatMap { [1.0, $0, $0 * $0] }
        let b = xs.map { 1 + 2 * $0 - 0.3 * $0 * $0 }
        let primary = try LAPACKSolver.leastSquares(rowMajorA: a, rows: 6, columns: 3, b: b)
        let fallback = try LAPACKSolver.normalEquationsLeastSquares(
            rowMajorA: a, rows: 6, columns: 3, b: b
        )
        for (p, f) in zip(primary, fallback) {
            XCTAssertEqual(p, f, accuracy: 1e-6)
        }
    }

    func testDimensionMismatchThrows() {
        XCTAssertThrowsError(
            try LAPACKSolver.leastSquares(rowMajorA: [1, 2, 3], rows: 2, columns: 2, b: [1, 2])
        )
    }

    // MARK: Polynomial surface fitting

    func testPlanarFitRecoversPlane() throws {
        let width = 64, height = 64
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let nx = Float(x) / Float(width - 1)
                let ny = Float(y) / Float(height - 1)
                pixels[y * width + x] = 0.2 + 0.1 * nx + 0.05 * ny
            }
        }
        let fitter = PolynomialFitter(degree: .linear, sampleSpacing: 8)
        let surface = try fitter.fit(pixels: pixels, width: width, height: height)
        for (x, y) in [(0, 0), (width - 1, 0), (0, height - 1), (width / 2, height / 2)] {
            let nx = Float(x) / Float(width - 1)
            let ny = Float(y) / Float(height - 1)
            let expected = 0.2 + 0.1 * nx + 0.05 * ny
            XCTAssertEqual(Float(surface.value(x: x, y: y)), expected, accuracy: 0.01)
        }
    }

    func testBackgroundRemovalFlattensGradientButKeepsStars() throws {
        let width = 80, height = 80
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let nx = Float(x) / Float(width - 1)
                pixels[y * width + x] = 0.1 + 0.3 * nx // strong horizontal gradient
            }
        }
        // A bright "star" that the median sampling should ignore.
        pixels[40 * width + 40] = 1.0

        let fitter = PolynomialFitter(degree: .linear, sampleSpacing: 8)
        let flattened = try fitter.removeBackground(pixels: pixels, width: width, height: height)

        var background = flattened
        background[40 * width + 40] = flattened[40 * width + 39] // exclude star
        let mean = background.reduce(0, +) / Float(background.count)
        let maxDeviation = background.map { abs($0 - mean) }.max() ?? 1
        XCTAssertLessThan(maxDeviation, 0.01, "background should be flat after removal")
        XCTAssertGreaterThan(flattened[40 * width + 40], 0.7, "star flux must be preserved")
    }

    // MARK: Physics stage

    func testAirmassMatchesKastenYoungReferencePoints() {
        XCTAssertEqual(AtmosphericModel.airmass(altitudeDegrees: 90), 1.0, accuracy: 0.001)
        XCTAssertEqual(AtmosphericModel.airmass(altitudeDegrees: 30), 2.0, accuracy: 0.01)
        // Horizon airmass ≈ 38 for Kasten–Young.
        XCTAssertEqual(AtmosphericModel.airmass(altitudeDegrees: 0), 38, accuracy: 1.0)
    }

    func testSkyglowIncreasesTowardHorizon() {
        let model = AtmosphericModel(telemetry: TelemetrySnapshot())
        XCTAssertGreaterThan(
            model.skyglow(altitudeDegrees: 10),
            model.skyglow(altitudeDegrees: 60)
        )
    }

    func testHumidityIncreasesAerosolScattering() {
        let dry = RayleighMie.totalOpticalDepth(
            wavelengthMicrons: 0.55, beta: 0.1, relativeHumidity: 0.2
        )
        let humid = RayleighMie.totalOpticalDepth(
            wavelengthMicrons: 0.55, beta: 0.1, relativeHumidity: 0.9
        )
        XCTAssertGreaterThan(humid, dry)
    }

    /// Spec acceptance test: a synthetic 100×100 FITS grid whose background is
    /// exactly the modeled atmospheric skyglow must yield flat residuals after
    /// physical subtraction.
    func testSynthetic100x100GridYieldsFlatResidualAfterPhysicalSubtraction() throws {
        let width = 100, height = 100
        let telemetry = TelemetrySnapshot(
            targetAltitudeDegrees: 20, // low target → steep airmass gradient
            relativeHumidity: 0.7,
            aerosolOpticalDepth: 0.15,
            fieldOfViewDegrees: 10
        )
        let model = AtmosphericModel(telemetry: telemetry)
        let prior = model.priorSurface(width: width, height: height)

        // Synthesize frame = pedestal + 0.6 × skyglow, through a real FITS
        // encode/decode round trip.
        var truth = [Float](repeating: 0, count: width * height)
        for k in 0 ..< truth.count {
            truth[k] = 0.1 + 0.6 * prior[k]
        }
        let image = try FITSReader.read(
            data: FITSWriter.data(pixels: truth, width: width, height: height)
        )

        let residual = model.subtractPrior(
            from: image.pixels, width: width, height: height
        )
        let mean = residual.reduce(0, +) / Float(residual.count)
        let maxDeviation = residual.map { abs($0 - mean) }.max() ?? 1
        XCTAssertLessThan(
            maxDeviation, 2.0 / 65535,
            "physical subtraction must flatten the modeled skyglow to quantization noise"
        )
    }

    // MARK: Full hybrid pipeline

    func testHybridPipelinePreservesFaintExtendedFlux() throws {
        let width = 100, height = 100
        let telemetry = TelemetrySnapshot(
            targetAltitudeDegrees: 25, fieldOfViewDegrees: 8
        )
        let model = AtmosphericModel(telemetry: telemetry)
        let prior = model.priorSurface(width: width, height: height)

        // Frame = pedestal + skyglow + tilt (light dome) + faint IFN patch.
        var pixels = [Float](repeating: 0, count: width * height)
        var ifnMask = [Bool](repeating: false, count: width * height)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let k = y * width + x
                let nx = Float(x) / Float(width - 1)
                pixels[k] = 0.1 + 0.5 * prior[k] + 0.05 * nx
                let inPatch = (30 ... 45).contains(x) && (30 ... 45).contains(y)
                if inPatch {
                    pixels[k] += 0.03
                    ifnMask[k] = true
                }
            }
        }

        let pipeline = GradientRemovalPipeline(
            telemetry: telemetry, degree: .linear, sampleSpacing: 10
        )
        let result = try pipeline.process(pixels: pixels, width: width, height: height)

        var patch: [Float] = []
        var sky: [Float] = []
        for k in 0 ..< pixels.count {
            if ifnMask[k] { patch.append(result.pixels[k]) } else { sky.append(result.pixels[k]) }
        }
        let patchMean = patch.reduce(0, +) / Float(patch.count)
        let skyMean = sky.reduce(0, +) / Float(sky.count)
        XCTAssertEqual(
            patchMean - skyMean, 0.03, accuracy: 0.012,
            "low-order fitting must not scoop out faint extended flux"
        )

        // And the sky background itself must be flat.
        let skyDeviation = sky.map { abs($0 - skyMean) }.max() ?? 1
        XCTAssertLessThan(skyDeviation, 0.02)
    }

    func testTelemetryManagerAssemblesSnapshotFromProviders() async {
        let manager = TelemetryManager(
            location: StaticLocationProvider(latitude: 46.2, longitude: 6.1),
            pointing: StaticPointingProvider(altitudeDegrees: 35, azimuthDegrees: 120),
            weather: StaticWeatherProvider(
                observation: WeatherObservation(relativeHumidity: 0.8, aerosolOpticalDepth: 0.2)
            )
        )
        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.latitude, 46.2)
        XCTAssertEqual(snapshot.longitude, 6.1)
        XCTAssertEqual(snapshot.targetAltitudeDegrees, 35)
        XCTAssertEqual(snapshot.targetAzimuthDegrees, 120)
        XCTAssertEqual(snapshot.relativeHumidity, 0.8)
        XCTAssertEqual(snapshot.aerosolOpticalDepth, 0.2)
    }
}
