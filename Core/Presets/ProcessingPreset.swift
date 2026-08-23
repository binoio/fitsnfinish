import Foundation

/// A named rig + site combination: everything the engine needs that isn't
/// derived from the image itself. Shared between the apps and the `fnfin`
/// CLI; serialized as JSON for preset files.
public struct ProcessingPreset: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var targetAltitudeDegrees: Double
    public var targetAzimuthDegrees: Double
    public var relativeHumidity: Double
    public var aerosolOpticalDepth: Double
    public var fieldOfViewDegrees: Double
    public var degree: Int
    public var physicsStrength: Float
    // 0.4.0 physics fields — decoded with defaults so pre-0.4.0 preset
    // files keep importing.
    public var fieldRotationDegrees: Double = 0
    public var moonlightEnabled: Bool = true
    public var lightDomeAzimuthDegrees: Double = 0
    public var lightDomeIntensity: Double = 0
    /// Ångström aerosol exponent (0.4.0; defaults keep older files valid).
    public var angstromExponent: Double = 1.3

    public init(
        id: UUID = UUID(), name: String,
        latitude: Double, longitude: Double,
        targetAltitudeDegrees: Double, targetAzimuthDegrees: Double,
        relativeHumidity: Double, aerosolOpticalDepth: Double,
        fieldOfViewDegrees: Double, degree: Int, physicsStrength: Float,
        fieldRotationDegrees: Double = 0, moonlightEnabled: Bool = true,
        lightDomeAzimuthDegrees: Double = 0, lightDomeIntensity: Double = 0,
        angstromExponent: Double = 1.3
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.targetAltitudeDegrees = targetAltitudeDegrees
        self.targetAzimuthDegrees = targetAzimuthDegrees
        self.relativeHumidity = relativeHumidity
        self.aerosolOpticalDepth = aerosolOpticalDepth
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.degree = degree
        self.physicsStrength = physicsStrength
        self.fieldRotationDegrees = fieldRotationDegrees
        self.moonlightEnabled = moonlightEnabled
        self.lightDomeAzimuthDegrees = lightDomeAzimuthDegrees
        self.lightDomeIntensity = lightDomeIntensity
        self.angstromExponent = angstromExponent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        targetAltitudeDegrees = try container.decode(Double.self, forKey: .targetAltitudeDegrees)
        targetAzimuthDegrees = try container.decode(Double.self, forKey: .targetAzimuthDegrees)
        relativeHumidity = try container.decode(Double.self, forKey: .relativeHumidity)
        aerosolOpticalDepth = try container.decode(Double.self, forKey: .aerosolOpticalDepth)
        fieldOfViewDegrees = try container.decode(Double.self, forKey: .fieldOfViewDegrees)
        degree = try container.decode(Int.self, forKey: .degree)
        physicsStrength = try container.decode(Float.self, forKey: .physicsStrength)
        fieldRotationDegrees = try container.decodeIfPresent(Double.self, forKey: .fieldRotationDegrees) ?? 0
        moonlightEnabled = try container.decodeIfPresent(Bool.self, forKey: .moonlightEnabled) ?? true
        lightDomeAzimuthDegrees = try container.decodeIfPresent(Double.self, forKey: .lightDomeAzimuthDegrees) ?? 0
        lightDomeIntensity = try container.decodeIfPresent(Double.self, forKey: .lightDomeIntensity) ?? 0
        angstromExponent = try container.decodeIfPresent(Double.self, forKey: .angstromExponent) ?? 1.3
    }

    /// Applies this preset's site and engine fields onto a telemetry
    /// snapshot (image-derived fields — RA/Dec, date, exposure — are kept).
    public func applied(to base: TelemetrySnapshot) -> TelemetrySnapshot {
        var telemetry = base
        telemetry.latitude = latitude
        telemetry.longitude = longitude
        telemetry.targetAltitudeDegrees = targetAltitudeDegrees
        telemetry.targetAzimuthDegrees = targetAzimuthDegrees
        telemetry.relativeHumidity = relativeHumidity
        telemetry.aerosolOpticalDepth = aerosolOpticalDepth
        telemetry.fieldOfViewDegrees = fieldOfViewDegrees
        telemetry.fieldRotationDegrees = fieldRotationDegrees
        telemetry.moonlightEnabled = moonlightEnabled
        telemetry.lightDomeAzimuthDegrees = lightDomeAzimuthDegrees
        telemetry.lightDomeIntensity = lightDomeIntensity
        telemetry.angstromExponent = angstromExponent
        return telemetry
    }
}
