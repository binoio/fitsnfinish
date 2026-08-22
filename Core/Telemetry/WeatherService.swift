import Foundation
#if canImport(WeatherKit) && canImport(CoreLocation)
import WeatherKit
import CoreLocation
#endif

/// Atmospheric conditions needed by the physics stage.
public struct WeatherObservation: Equatable {
    /// Relative humidity in [0, 1].
    public var relativeHumidity: Double
    /// Aerosol optical depth at 1 µm (Ångström β). WeatherKit exposes no
    /// direct AOD product, so it is estimated from visibility when available.
    public var aerosolOpticalDepth: Double

    public init(relativeHumidity: Double, aerosolOpticalDepth: Double) {
        self.relativeHumidity = relativeHumidity
        self.aerosolOpticalDepth = aerosolOpticalDepth
    }

    /// Continental clear-sky defaults used when no live data is available.
    public static let standard = WeatherObservation(
        relativeHumidity: 0.5, aerosolOpticalDepth: 0.1
    )

    /// Koschmieder relation: meteorological visibility V (meters) implies a
    /// sea-level extinction coefficient σ ≈ 3.912 / V; scaled by an ~1.5 km
    /// aerosol scale height to approximate columnar optical depth.
    public static func aerosolOpticalDepth(visibilityMeters: Double) -> Double {
        guard visibilityMeters > 0 else { return standard.aerosolOpticalDepth }
        let sigma = 3.912 / visibilityMeters
        let rayleighSigma = 0.0116e-3 // clear-air limit, 1/m
        return max(sigma - rayleighSigma, 0.005) * 1500
    }
}

/// Abstraction over the weather source so the pipeline and tests never need
/// live WeatherKit access.
public protocol WeatherProviding {
    func currentObservation(latitude: Double, longitude: Double) async throws -> WeatherObservation
}

/// Fixed-value provider for tests, previews, and offline use.
public struct StaticWeatherProvider: WeatherProviding {
    public var observation: WeatherObservation

    public init(observation: WeatherObservation = .standard) {
        self.observation = observation
    }

    public func currentObservation(latitude: Double, longitude: Double) async throws -> WeatherObservation {
        observation
    }
}

#if canImport(WeatherKit) && canImport(CoreLocation)
/// Live WeatherKit-backed provider. Requires the WeatherKit capability and
/// entitlement; callers should fall back to `StaticWeatherProvider` when the
/// request throws (e.g. unsigned development builds).
@available(macOS 13.0, iOS 16.0, *)
public struct WeatherService: WeatherProviding {
    public init() {}

    public func currentObservation(latitude: Double, longitude: Double) async throws -> WeatherObservation {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let weather = try await WeatherKit.WeatherService.shared.weather(
            for: location, including: .current
        )
        let visibility = weather.visibility.converted(to: .meters).value
        return WeatherObservation(
            relativeHumidity: weather.humidity,
            aerosolOpticalDepth: WeatherObservation.aerosolOpticalDepth(
                visibilityMeters: visibility
            )
        )
    }
}
#endif
