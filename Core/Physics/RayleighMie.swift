import Foundation

/// Wavelength-dependent atmospheric scattering optical depths.
///
/// The physical prior removes the *non-linear* part of the sky background —
/// the steep airmass curve — so the downstream surface fitter only ever needs
/// a gentle 1st/2nd-degree polynomial.
public enum RayleighMie {
    /// Rayleigh optical depth at sea level for a given wavelength.
    ///
    /// Hansen & Travis (1974) approximation; `wavelength` in micrometers.
    public static func rayleighOpticalDepth(wavelengthMicrons λ: Double) -> Double {
        let λ2 = λ * λ
        let λ4 = λ2 * λ2
        return 0.008569 / λ4 * (1 + 0.0113 / λ2 + 0.00013 / λ4)
    }

    /// Mie (aerosol) optical depth via the Ångström turbidity formula
    /// τ = β · λ^(−α), with `beta` the turbidity coefficient (aerosol
    /// optical depth at 1 µm) and `alpha` the Ångström exponent
    /// (≈1.3 for continental aerosols).
    public static func mieOpticalDepth(
        wavelengthMicrons λ: Double,
        beta: Double,
        alpha: Double = 1.3
    ) -> Double {
        beta * pow(λ, -alpha)
    }

    /// Scales the clear-air aerosol turbidity for hygroscopic particle growth.
    /// Aerosols swell as relative humidity rises, increasing scattering
    /// cross-section (Hänel growth; simple (1 − RH)^(−γ) form, capped so
    /// saturated air stays finite).
    public static func humidityAdjustedBeta(
        beta: Double,
        relativeHumidity rh: Double,
        gamma: Double = 0.25
    ) -> Double {
        let clamped = min(max(rh, 0), 0.97)
        return beta * pow(1 - clamped, -gamma)
    }

    /// Combined extinction optical depth for one wavelength band.
    public static func totalOpticalDepth(
        wavelengthMicrons λ: Double,
        beta: Double,
        relativeHumidity: Double
    ) -> Double {
        let adjustedBeta = humidityAdjustedBeta(beta: beta, relativeHumidity: relativeHumidity)
        return rayleighOpticalDepth(wavelengthMicrons: λ)
            + mieOpticalDepth(wavelengthMicrons: λ, beta: adjustedBeta)
    }
}
