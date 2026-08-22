import Foundation
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(CoreMotion) && os(iOS)
import CoreMotion
#endif

/// Provides the device position; abstracted so tests inject fixed values.
public protocol LocationProviding {
    func currentPosition() async throws -> (latitude: Double, longitude: Double)
}

/// Provides the optical-axis pointing; on iPhone/iPad this comes from
/// CoreMotion attitude, on Mac from manual entry or a mount driver.
public protocol PointingProviding {
    func currentPointing() async throws -> (altitudeDegrees: Double, azimuthDegrees: Double)
}

public struct StaticLocationProvider: LocationProviding {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public func currentPosition() async throws -> (latitude: Double, longitude: Double) {
        (latitude, longitude)
    }
}

public struct StaticPointingProvider: PointingProviding {
    public var altitudeDegrees: Double
    public var azimuthDegrees: Double

    public init(altitudeDegrees: Double, azimuthDegrees: Double) {
        self.altitudeDegrees = altitudeDegrees
        self.azimuthDegrees = azimuthDegrees
    }

    public func currentPointing() async throws -> (altitudeDegrees: Double, azimuthDegrees: Double) {
        (altitudeDegrees, azimuthDegrees)
    }
}

/// Assembles a complete `TelemetrySnapshot` from live (or injected) location,
/// pointing, and weather sources. Any source that fails leaves the
/// corresponding baseline value untouched, so the pipeline always has a
/// usable snapshot.
public final class TelemetryManager {
    public var location: LocationProviding?
    public var pointing: PointingProviding?
    public var weather: WeatherProviding
    /// Values used for fields no provider can supply.
    public var baseline: TelemetrySnapshot

    public init(
        location: LocationProviding? = nil,
        pointing: PointingProviding? = nil,
        weather: WeatherProviding = StaticWeatherProvider(),
        baseline: TelemetrySnapshot = TelemetrySnapshot()
    ) {
        self.location = location
        self.pointing = pointing
        self.weather = weather
        self.baseline = baseline
    }

    public func snapshot() async -> TelemetrySnapshot {
        var snapshot = baseline
        if let location, let position = try? await location.currentPosition() {
            snapshot.latitude = position.latitude
            snapshot.longitude = position.longitude
        }
        if let pointing, let aim = try? await pointing.currentPointing() {
            snapshot.targetAltitudeDegrees = aim.altitudeDegrees
            snapshot.targetAzimuthDegrees = aim.azimuthDegrees
        }
        if let observation = try? await weather.currentObservation(
            latitude: snapshot.latitude, longitude: snapshot.longitude
        ) {
            snapshot.relativeHumidity = observation.relativeHumidity
            snapshot.aerosolOpticalDepth = observation.aerosolOpticalDepth
        }
        return snapshot
    }
}

#if canImport(CoreLocation)
/// One-shot CoreLocation position provider. Requires
/// `NSLocationWhenInUseUsageDescription` in Info.plist.
public final class CoreLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<(latitude: Double, longitude: Double), Error>?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    public func currentPosition() async throws -> (latitude: Double, longitude: Double) {
        if let cached = manager.location {
            return (cached.coordinate.latitude, cached.coordinate.longitude)
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            #if os(iOS)
            manager.requestWhenInUseAuthorization()
            #endif
            manager.requestLocation()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        continuation?.resume(returning: (location.coordinate.latitude, location.coordinate.longitude))
        continuation = nil
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
#endif

#if canImport(CoreMotion) && os(iOS)
/// CoreMotion attitude → alt/az pointing for handheld capture. Requires
/// `NSMotionUsageDescription` in Info.plist.
public final class CoreMotionPointingProvider: PointingProviding {
    private let manager = CMMotionManager()

    public init() {}

    public func currentPointing() async throws -> (altitudeDegrees: Double, azimuthDegrees: Double) {
        guard manager.isDeviceMotionAvailable else {
            throw NSError(
                domain: "FitsnFinish.Telemetry", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Device motion unavailable"]
            )
        }
        manager.startDeviceMotionUpdates(using: .xTrueNorthZVertical)
        defer { manager.stopDeviceMotionUpdates() }
        // Give the sensors a moment to converge.
        for _ in 0 ..< 50 {
            if let motion = manager.deviceMotion {
                let pitch = motion.attitude.pitch * 180 / .pi
                var heading = motion.heading
                if heading < 0 { heading += 360 }
                return (pitch, heading)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw NSError(
            domain: "FitsnFinish.Telemetry", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Device motion timed out"]
        )
    }
}
#endif
