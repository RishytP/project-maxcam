#include <metal_stdlib>
using namespace metal;

// Preview-only display transform. The master recording buffer is untouched;
// this kernel converts wide-gamut log or P3 content to sRGB for the screen.
//
// mode:
//   0 = passthrough (already sRGB / decide elsewhere)
//   1 = Apple Log -> sRGB 709 (standard display transform)
//   2 = P3-D65  -> sRGB 709

static float3 logTo709(float3 logRGB) {
    // Apple Log is a 10-bit log encoding with its own defined curve. The
    // nominal highlight reference is 0.15 of encoded value; the transfer
    // function is not published for third-party use, so we expose a clearly
    // labeled approximate decode for monitoring only. The master recording
    // keeps the native Apple Log values untouched.
    //
    // This is NOT the Apple Log curve. It is a monitoring-only approximation
    // used so the operator sees a usable picture. Real grading must use the
    // camera's Apple Log metadata instead.
    float3 lin = pow(max(logRGB, 1e-4), float3(2.2));
    return lin;
}

static float3 p3To709(float3 p3) {
    // Approximate P3-D65 -> Rec.709 matrix (row-major, D65 white point).
    float3x3 m = float3x3(
        1.2249, -0.2249, 0.0,
        -0.0420, 1.0420, 0.0,
        -0.0197, -0.0786, 1.0983
    );
    return m * p3;
}

kernel void displayTransform(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant uint &mode [[buffer(0)]]
) {
    const uint2 gid = uint2(thread_position_in_grid.xy);
    const float4 rgba = src.read(gid);

    float3 rgb = rgba.rgb;
    if (mode == 1) {
        rgb = logTo709(rgb);
    } else if (mode == 2) {
        rgb = p3To709(rgb);
    }

    // Simple sRGB-ish output: clamp and write.
    float3 out = clamp(rgb, 0.0, 1.0);
    dst.write(float4(out, rgba.a), gid);
}