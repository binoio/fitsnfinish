import XCTest
@testable import FitsnFinishCore

final class TelemetryTests: XCTestCase {
    func testTelemetrySnapshotWithStaticProviders() async {
        let location = StaticLocationProvider(latitude: 37.7749, longitude: -122.4194)
        let pointing = StaticPointingProvider(altitudeDegrees: 45.0, azimuthDegrees: 180.0)
        let weather = StaticWeatherProvider(observation: WeatherObservation(relativeHumidity: 0.65, aerosolOpticalDepth: 0.12))
        let manager = TelemetryManager(
            location: location,
            pointing: pointing,
            weather: weather,
            baseline: TelemetrySnapshot()
        )

        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.latitude, 37.7749, accuracy: 1e-4)
        XCTAssertEqual(snapshot.longitude, -122.4194, accuracy: 1e-4)
        XCTAssertEqual(snapshot.targetAltitudeDegrees, 45.0, accuracy: 1e-4)
        XCTAssertEqual(snapshot.targetAzimuthDegrees, 180.0, accuracy: 1e-4)
        XCTAssertEqual(snapshot.relativeHumidity, 0.65, accuracy: 1e-4)
        XCTAssertEqual(snapshot.aerosolOpticalDepth, 0.12, accuracy: 1e-4)
    }

    func testTelemetrySnapshotFallsBackToBaselineWhenProvidersNil() async {
        var baseline = TelemetrySnapshot()
        baseline.latitude = 51.5074
        baseline.longitude = -0.1278
        let manager = TelemetryManager(
            location: nil,
            pointing: nil,
            weather: StaticWeatherProvider(),
            baseline: baseline
        )

        let snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.latitude, 51.5074, accuracy: 1e-4)
        XCTAssertEqual(snapshot.longitude, -0.1278, accuracy: 1e-4)
    }

    #if canImport(CoreLocation)
    func testCoreLocationProviderInitializes() {
        let provider = CoreLocationProvider()
        XCTAssertNotNil(provider)
    }
    #endif
}
