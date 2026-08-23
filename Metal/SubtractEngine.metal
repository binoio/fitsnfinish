#include <metal_stdlib>
using namespace metal;

// Hybrid gradient subtraction:
//   out = max(image − physicsStrength·(prior − priorMean)·priorGain
//                   − (surface − surfaceMean), 0)
// The prior texture is the physical (Rayleigh/Mie airmass) baseline, the
// surface texture the low-order polynomial fit; both are mean-centered so the
// frame's pedestal is preserved and the black point is clamped at 0.
struct SubtractParams {
    float physicsStrength;
    float priorGain;   // least-squares scale matching prior shape to image
    float priorMean;
    float surfaceMean;
};

kernel void subtract_gradients(
    texture2d<float, access::read>  image   [[texture(0)]],
    texture2d<float, access::read>  prior   [[texture(1)]],
    texture2d<float, access::read>  surface [[texture(2)]],
    texture2d<float, access::write> output  [[texture(3)]],
    constant SubtractParams &params         [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    float pixel = image.read(gid).r;
    float physical = params.physicsStrength * params.priorGain
                   * (prior.read(gid).r - params.priorMean);
    float statistical = surface.read(gid).r - params.surfaceMean;
    float result = max(pixel - physical - statistical, 0.0f);
    output.write(float4(result, result, result, 1.0f), gid);
}

// Display helper: midtone-transfer-function stretch for on-screen preview of
// linear data. m is the midtone balance in (0, 1).
kernel void mtf_stretch(
    texture2d<float, access::read>  input  [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant float &midtone                [[buffer(0)]],
    uint2 gid                              [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) {
        return;
    }
    float x = clamp(input.read(gid).r, 0.0f, 1.0f);
    float m = clamp(midtone, 1e-4f, 1.0f - 1e-4f);
    float y = ((m - 1.0f) * x) / ((2.0f * m - 1.0f) * x - m);
    output.write(float4(y, y, y, 1.0f), gid);
}

// Physical prior render, mirroring AtmosphericModel.evaluatePrior: airmass
// glow plus optional Garstang light-dome and Krisciunas–Schaefer moonlight
// terms, averaged over up to three time samples (target/moon drift across
// long exposures). Row 0 is the bottom of the frame (FITS convention).
// Samples buffer layout: 5 floats per sample — altCenter, azCenter,
// moonAlt, moonAz, moonFactor.
struct PriorParams {
    float tau;
    float extinction;
    float pixScaleDegrees;
    float rotationSine;
    float rotationCosine;
    float domeAzimuthDegrees;
    float domeIntensity;
    uint  sampleCount;
    uint  width;
    uint  height;
};

static inline float kasten_young_airmass(float altitudeDegrees)
{
    float altitude = clamp(altitudeDegrees, 0.0f, 90.0f);
    float z = 90.0f - altitude;
    return 1.0f / (cos(z * M_PI_F / 180.0f)
                   + 0.50572f * pow(96.07995f - z, -1.6364f));
}

kernel void render_prior(
    texture2d<float, access::write> prior [[texture(0)]],
    constant PriorParams &p               [[buffer(0)]],
    device const float *samples           [[buffer(1)]],
    uint2 gid                             [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) {
        return;
    }
    float dx = (float(gid.x) - float(p.width - 1) * 0.5f) * p.pixScaleDegrees;
    float dy = (float(gid.y) - float(p.height - 1) * 0.5f) * p.pixScaleDegrees;
    float along = dx * p.rotationSine + dy * p.rotationCosine;
    float across = dx * p.rotationCosine - dy * p.rotationSine;

    float total = 0.0f;
    for (uint s = 0; s < p.sampleCount; s++) {
        float altCenter   = samples[s * 5 + 0];
        float azCenter    = samples[s * 5 + 1];
        float moonAlt     = samples[s * 5 + 2];
        float moonAz      = samples[s * 5 + 3];
        float moonFactor  = samples[s * 5 + 4];

        float altitude = clamp(altCenter + along, 0.0f, 90.0f);
        float airmass = kasten_young_airmass(altitude);
        float value = 1.0f - exp(-p.tau * airmass);
        float azimuth = azCenter
            + across / max(cos(altitude * M_PI_F / 180.0f), 0.2f);

        if (p.domeIntensity > 0.0f) {
            float deltaAz = (azimuth - p.domeAzimuthDegrees) * M_PI_F / 180.0f;
            value += p.domeIntensity * exp(-altitude / 10.0f)
                   * (1.0f + cos(deltaAz)) * 0.5f;
        }

        if (moonFactor > 0.0f) {
            float a1 = altitude * M_PI_F / 180.0f;
            float a2 = moonAlt * M_PI_F / 180.0f;
            float deltaAz = (azimuth - moonAz) * M_PI_F / 180.0f;
            float cosSep = clamp(
                sin(a1) * sin(a2) + cos(a1) * cos(a2) * cos(deltaAz),
                -1.0f, 1.0f
            );
            float rho = max(acos(cosSep) * 180.0f / M_PI_F, 1.0f);
            float cosRho = cos(rho * M_PI_F / 180.0f);
            float scattering = pow(10.0f, 5.36f) * (1.06f + cosRho * cosRho)
                             + pow(10.0f, 6.15f - rho / 40.0f);
            float selfAbsorption = 1.0f - pow(10.0f, -0.4f * p.extinction * airmass);
            value += moonFactor * scattering * selfAbsorption;
        }
        total += value;
    }
    float glow = total / float(p.sampleCount);
    prior.write(float4(glow, glow, glow, 1.0f), gid);
}

// Cell-median sampling of the physics-subtracted residual: one thread per
// sample cell computes the median of unmasked (below-threshold) residual
// pixels plus the masked fraction, feeding the CPU's tiny least-squares
// solve. Cells are at most 16x16 = 256 pixels.
struct MedianParams {
    uint  width;
    uint  height;
    uint  spacing;
    uint  cellsX;
    uint  cellsY;
    float threshold;
    float physicsStrength;
    float priorGain;
    float priorMean;
};

kernel void cell_median(
    texture2d<float, access::read> image [[texture(0)]],
    texture2d<float, access::read> prior [[texture(1)]],
    device float *medians                [[buffer(0)]],
    device float *maskedFractions        [[buffer(1)]],
    constant MedianParams &p             [[buffer(2)]],
    uint2 gid                            [[thread_position_in_grid]])
{
    if (gid.x >= p.cellsX || gid.y >= p.cellsY) {
        return;
    }
    uint x0 = gid.x * p.spacing;
    uint y0 = gid.y * p.spacing;
    uint x1 = min(x0 + p.spacing, p.width);
    uint y1 = min(y0 + p.spacing, p.height);

    float values[256];
    uint kept = 0;
    uint total = 0;
    for (uint y = y0; y < y1; y++) {
        for (uint x = x0; x < x1; x++) {
            uint2 at = uint2(x, y);
            float correction = p.physicsStrength * p.priorGain
                             * (prior.read(at).r - p.priorMean);
            float residual = max(image.read(at).r - correction, 0.0f);
            total++;
            if (residual <= p.threshold && kept < 256) {
                values[kept++] = residual;
            }
        }
    }
    // Insertion sort; cells are tiny.
    for (uint i = 1; i < kept; i++) {
        float key = values[i];
        int j = int(i) - 1;
        while (j >= 0 && values[j] > key) {
            values[j + 1] = values[j];
            j--;
        }
        values[j + 1] = key;
    }
    uint cell = gid.y * p.cellsX + gid.x;
    medians[cell] = kept > 0 ? values[kept / 2] : 0.0f;
    maskedFractions[cell] = 1.0f - float(kept) / float(total);
}

// Low-order polynomial surface render from up to six coefficients over
// normalized [-1, 1] coordinates.
struct SurfaceParams {
    uint  width;
    uint  height;
    uint  degree;
    float c0, c1, c2, c3, c4, c5;
};

kernel void render_surface(
    texture2d<float, access::write> surface [[texture(0)]],
    constant SurfaceParams &p               [[buffer(0)]],
    uint2 gid                               [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) {
        return;
    }
    float nx = p.width > 1 ? 2.0f * float(gid.x) / float(p.width - 1) - 1.0f : 0.0f;
    float ny = p.height > 1 ? 2.0f * float(gid.y) / float(p.height - 1) - 1.0f : 0.0f;
    float v = p.c0 + p.c1 * nx + p.c2 * ny;
    if (p.degree >= 2) {
        v += p.c3 * nx * nx + p.c4 * nx * ny + p.c5 * ny * ny;
    }
    surface.write(float4(v, v, v, 1.0f), gid);
}
