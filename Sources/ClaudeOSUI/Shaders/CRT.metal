#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// CRT phosphor for SwiftUI `.layerEffect` — gives any view the wasteland tube look:
// a tight green bloom/afterglow around bright pixels (so glyphs glow like phosphor),
// scanlines, and a sliver of chromatic aberration. No time uniform, so SwiftUI only
// re-runs it when the view's content actually changes. Purely visual — hit-testing,
// layout and event routing are untouched.
[[ stitchable ]]
half4 crtPhosphor(float2 pos, SwiftUI::Layer layer) {
    // Base colour with a sliver of chromatic aberration on the R/B channels.
    const float ca = 0.6;
    half4 c = layer.sample(pos);
    half r  = layer.sample(pos + float2(ca, 0.0)).r;
    half b  = layer.sample(pos - float2(ca, 0.0)).b;
    half3 col = half3(r, c.g, b);
    half  a   = c.a;

    // Phosphor bloom / afterglow: luma-weighted accumulation of a small neighbourhood,
    // with extra weight for already-bright pixels so bright glyphs bleed a soft halo
    // while body text stays legible.
    const half3 tint = half3(0.55h, 1.0h, 0.62h);
    half3 glow = half3(0.0h);
    half  tot  = 0.0h;
    for (int x = -2; x <= 2; x++) {
        for (int y = -2; y <= 2; y++) {
            float2 off = float2(float(x), float(y)) * 2.2;
            half3 s = layer.sample(pos + off).rgb;
            half  d2 = half(x * x + y * y);
            half  w  = 1.0h / (1.0h + d2);
            half  luma = dot(s, half3(0.299h, 0.587h, 0.114h));
            w += smoothstep(0.40h, 1.0h, luma) * 0.5h;
            glow += s * w;
            tot  += w;
        }
    }
    col += (glow / tot) * tint * 0.34h;

    // Scanlines (≈2-point period), subtle so text stays sharp.
    half scan = half(sin(pos.y * 3.14159) * 0.5 + 0.5);
    col *= 1.0h - 0.10h * scan;

    // Warm CRT lift.
    col *= 1.05h;

    return half4(col, a);
}
