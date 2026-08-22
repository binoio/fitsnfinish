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
