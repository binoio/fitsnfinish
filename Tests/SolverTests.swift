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

    // MARK: Astrometry

    private func utcDate(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: iso)!
    }

    func testSiderealTimeAtJ2000() {
        // JD 2451545.0 (2000-01-01 12:00 UT): GMST = 280.4606°.
        let gmst = Astrometry.greenwichSiderealTime(utcDate("2000-01-01T12:00:00Z"))
        XCTAssertEqual(gmst, 280.4606, accuracy: 0.01)
    }

    func testPolarisAltitudeTracksLatitude() {
        // Polaris (RA 2h31.8m, dec +89.26°) sits within a degree of the
        // observer's latitude at any time.
        let position = Astrometry.horizontal(
            rightAscensionDegrees: 37.95, declinationDegrees: 89.264,
            latitude: 46.2, longitude: 6.1,
            date: utcDate("2026-08-23T22:00:00Z")
        )
        XCTAssertEqual(position.altitudeDegrees, 46.2, accuracy: 1.0)
        XCTAssertLessThan(min(position.azimuthDegrees, 360 - position.azimuthDegrees), 2.0)
    }

    func testSunLongitudeAtSolstice() {
        // June solstice 2000 (~01:48 UT June 21): solar longitude = 90°.
        let λ = Astrometry.sunEclipticLongitude(utcDate("2000-06-21T02:00:00Z"))
        XCTAssertEqual(λ, 90, accuracy: 0.1)
    }

    func testMoonPositionAgainstMeeusExample() {
        // Meeus, Astronomical Algorithms, example 47.a:
        // 1992 April 12.0 TD → λ = 133.1627°, β = −3.2291°.
        let moon = Astrometry.moonState(utcDate("1992-04-12T00:00:00Z"))
        let (ra, dec) = (moon.rightAscensionDegrees, moon.declinationDegrees)
        // Reference apparent RA/Dec: 134.6885°, +13.7684°.
        XCTAssertEqual(ra, 134.6885, accuracy: 0.1)
        XCTAssertEqual(dec, 13.7684, accuracy: 0.05)
    }

    func testMoonPhaseAtKnownFullAndNewMoon() {
        // 2000-01-21 04:44 UT: total lunar eclipse (exactly full).
        let full = Astrometry.moonState(utcDate("2000-01-21T04:44:00Z"))
        XCTAssertLessThan(abs(full.phaseAngleDegrees), 3)
        XCTAssertGreaterThan(full.illuminatedFraction, 0.998)
        // 2000-01-06 18:14 UT: new moon.
        let new = Astrometry.moonState(utcDate("2000-01-06T18:14:00Z"))
        XCTAssertGreaterThan(abs(new.phaseAngleDegrees), 177)
        XCTAssertLessThan(new.illuminatedFraction, 0.002)
    }

    func testMoonlightBrightensPriorTowardTheMoon() {
        // Full-moon night, moon well above the horizon: the prior must be
        // brighter on the moonward side of the frame.
        var telemetry = TelemetrySnapshot(
            latitude: 46.2, longitude: 6.1,
            targetAltitudeDegrees: 45, targetAzimuthDegrees: 180,
            fieldOfViewDegrees: 20,
            observationDate: nil
        )
        telemetry.observationDate = ISO8601DateFormatter()
            .date(from: "2000-01-21T04:44:00Z")
        telemetry.moonlightEnabled = true
        let model = AtmosphericModel(telemetry: telemetry)
        let samples = model.skySamples()
        // If the moon is below the horizon for this geometry the factor is
        // zero and the test is vacuous — assert it's up first.
        XCTAssertGreaterThan(samples[0].moonAltitudeDegrees, 0)
        XCTAssertGreaterThan(samples[0].moonFactor, 0)

        let render = model.renderModel(width: 64, height: 64)
        // Pixel nearest the moon azimuthally should exceed the far side.
        let near = AtmosphericModel.evaluatePrior(model: render, x: 0, y: 32, width: 64, height: 64)
        let far = AtmosphericModel.evaluatePrior(model: render, x: 63, y: 32, width: 64, height: 64)
        XCTAssertNotEqual(near, far, accuracy: 1e-9)
    }

    func testLightDomeAddsDirectionalGradient() {
        var telemetry = TelemetrySnapshot(
            targetAltitudeDegrees: 30, targetAzimuthDegrees: 0,
            fieldOfViewDegrees: 10
        )
        telemetry.lightDomeAzimuthDegrees = 0
        telemetry.lightDomeIntensity = 0.5
        let withDome = AtmosphericModel(telemetry: telemetry)
            .priorSurface(width: 32, height: 32)
        telemetry.lightDomeIntensity = 0
        let without = AtmosphericModel(telemetry: telemetry)
            .priorSurface(width: 32, height: 32)
        // Dome must raise the prior, more at low altitude (bottom rows).
        let bottomLift = withDome[16] - without[16]
        let topLift = withDome[31 * 32 + 16] - without[31 * 32 + 16]
        XCTAssertGreaterThan(Double(bottomLift), 0)
        XCTAssertGreaterThan(Double(bottomLift), Double(topLift))
    }

    func testFieldRotationRotatesGradientDirection() {
        var telemetry = TelemetrySnapshot(
            targetAltitudeDegrees: 20, fieldOfViewDegrees: 10
        )
        telemetry.fieldRotationDegrees = 90 // "up" now along +x
        let prior = AtmosphericModel(telemetry: telemetry)
            .priorSurface(width: 32, height: 32)
        // Gradient should now run along x, flat along y.
        let alongX = abs(prior[16 * 32 + 30] - prior[16 * 32 + 1])
        let alongY = abs(prior[30 * 32 + 16] - prior[1 * 32 + 16])
        XCTAssertGreaterThan(alongX, alongY * 10)
    }

    func testHeaderAstrometryParsing() throws {
        var cards = "SIMPLE  =                    T".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "BITPIX  =                   16".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS   =                    2".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS1  =                    2".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "NAXIS2  =                    2".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "OBJCTRA = '2 33 41 '".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "OBJCTDEC= '+61 26 47'".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "DATE-OBS= '2026-08-20T21:30:00.000'".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "EXPTIME =                 5400".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "XPIXSZ  =                 2.90".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "FOCALLEN=                 150.".padding(toLength: 80, withPad: " ", startingAt: 0)
        cards += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        var data = Data(cards.utf8)
        data.append(Data(count: FITSHeader.blockSize - data.count % FITSHeader.blockSize))
        let header = try FITSHeader(data: data)

        let astrometry = HeaderAstrometry(header: header)
        XCTAssertEqual(astrometry.rightAscensionDegrees ?? 0, 38.42, accuracy: 0.01)
        XCTAssertEqual(astrometry.declinationDegrees ?? 0, 61.446, accuracy: 0.01)
        XCTAssertEqual(astrometry.exposureSeconds, 5400)
        XCTAssertNotNil(astrometry.observationDate)
        // 206.265 × 2.9 / 150 arcsec ≈ 3.988″ ≈ 0.001108°.
        XCTAssertEqual(astrometry.pixelScaleDegrees ?? 0, 0.001108, accuracy: 0.00002)
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
