#include <metal_stdlib>
using namespace metal;

// Monitoring-only display transforms.
//
// The recorded master keeps the camera's native wide-gamut / log values. These
// kernels exist purely so the operator can see a usable picture on the phone
// display, which is not a reference monitor. Nothing here is presented as
// Apple's own transform: the Apple Log curve is not published for third-party
// use, so `logToDisplay` is an explicit approximation and is labelled as such
// in the UI.

// mode:
//   0 = passthrough
//   1 = log -> display (approximate, monitoring only)
//   2 = P3-D65 -> Rec.709

static float3 approximateLogToDisplay(float3 logRGB) {
    // Deliberately simple: an approximate inverse of a log-ish curve. This is
    // NOT the Apple Log transfer function and must not be used to author
    // graded deliverables.
    float3 linear = pow(max(logRGB, float3(1e-4)), float3(2.2));
    return linear;
}

static float3 p3ToRec709(float3 p3) {
    // P3-D65 -> Rec.709, D65 white point (row-major).
    float3x3 m = float3x3(
        float3(1.2249, -0.2249, 0.0000),
        float3(-0.0420, 1.0420, 0.0000),
        float3(-0.0197, -0.0786, 1.0983)
    );
    return m * p3;
}

kernel void displayTransform(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant uint &mode [[buffer(0)]]
) {
    const uint2 gid = uint2(thread_position_in_grid.xy);
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }
    const float4 rgba = src.read(gid);

    float3 rgb = rgba.rgb;
    if (mode == 1) {
        rgb = approximateLogToDisplay(rgb);
    } else if (mode == 2) {
        rgb = p3ToRec709(rgb);
    }

    dst.write(float4(clamp(rgb, 0.0, 1.0), rgba.a), gid);
}
