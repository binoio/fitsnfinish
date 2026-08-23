import Foundation

/// Wavelength-dependent atmospheric optical depths.
///
/// These parameterize the *shape* of the scattered-sky baseline (stage 1 of
/// the hybrid engine) — how steeply the background brightens with airmass
/// and how that steepness varies with color. They are not a radiative
/// transfer solution: the absolute amplitude of the modeled baseline is
/// least-squares fitted to each frame, so only the relative geometry needs
/// to be right.
public enum RayleighMie {
    /// Rayleigh optical depth at sea level for a given wavelength.
    ///
    /// Hansen & Travis (1974) approximation; `wavelength` in micrometers.
    public static func rayleighOpticalDepth(wavelengthMicrons λ: Double) -> Double {
        let λ2 = λ * λ
        let λ4 = λ2 * λ2
        return 0.008569 / λ4 * (1 + 0.0113 / λ2 + 0.00013 / λ4)
    }

    /// Aerosol optical depth via the Ångström turbidity law
    /// τ = β · λ^(−α), with `beta` the turbidity coefficient (aerosol
    /// optical depth at 1 µm) and `alpha` the Ångström exponent.
    /// α ≈ 1.3 is a continental-aerosol prior; maritime and dust aerosols
    /// run flatter (α ≈ 0.2–0.8), fine smoke steeper (α ≈ 1.8–2.2) — it is
    /// exposed as a telemetry/preset parameter rather than hard-coded.
    public static func mieOpticalDepth(
        wavelengthMicrons λ: Double,
        beta: Double,
        alpha: Double = 1.3
    ) -> Double {
        beta * pow(λ, -alpha)
    }

    /// Hygroscopic aerosol growth, single-parameter Hänel (1976) form:
    ///
    ///     β(RH) = β_dry · (1 − RH)^(−γ)
    ///
    /// with γ = 0.25 by default (a mid-range value for aged continental
    /// aerosol; sulfate-rich aerosol runs higher, dust lower) and RH clamped
    /// to ≤ 0.97 so saturated air stays finite. This is the exact
    /// parameterization used — no lookup tables or species mixing.
    public static func humidityAdjustedBeta(
        beta: Double,
        relativeHumidity rh: Double,
        gamma: Double = 0.25
    ) -> Double {
        let clamped = min(max(rh, 0), 0.97)
        return beta * pow(1 - clamped, -gamma)
    }

    /// Combined extinction optical depth at a single wavelength.
    public static func totalOpticalDepth(
        wavelengthMicrons λ: Double,
        beta: Double,
        relativeHumidity: Double,
        alpha: Double = 1.3,
        gamma: Double = 0.25
    ) -> Double {
        let adjustedBeta = humidityAdjustedBeta(
            beta: beta, relativeHumidity: relativeHumidity, gamma: gamma
        )
        return rayleighOpticalDepth(wavelengthMicrons: λ)
            + mieOpticalDepth(wavelengthMicrons: λ, beta: adjustedBeta, alpha: alpha)
    }

    /// Band-integrated optical depth: FITS data are usually broadband, so
    /// the molecular/aerosol model is averaged across the filter passband
    /// (rectangular response, 5-point midpoint rule) rather than evaluated
    /// at a single nominal wavelength. With Rayleigh's λ⁻⁴ this matters:
    /// a 0.1 µm-wide blue band scatters measurably more than its center
    /// wavelength alone suggests.
    public static func bandOpticalDepth(
        centerMicrons: Double,
        bandwidthMicrons: Double,
        beta: Double,
        relativeHumidity: Double,
        alpha: Double = 1.3,
        gamma: Double = 0.25
    ) -> Double {
        guard bandwidthMicrons > 0 else {
            return totalOpticalDepth(
                wavelengthMicrons: centerMicrons, beta: beta,
                relativeHumidity: relativeHumidity, alpha: alpha, gamma: gamma
            )
        }
        let samples = 5
        var total = 0.0
        for i in 0 ..< samples {
            let fraction = (Double(i) + 0.5) / Double(samples) - 0.5
            let λ = max(centerMicrons + fraction * bandwidthMicrons, 0.3)
            total += totalOpticalDepth(
                wavelengthMicrons: λ, beta: beta,
                relativeHumidity: relativeHumidity, alpha: alpha, gamma: gamma
            )
        }
        return total / Double(samples)
    }
}
