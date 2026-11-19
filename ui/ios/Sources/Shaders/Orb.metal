#include <metal_stdlib>
using namespace metal;

// Magical voice orb for the Bridge screen. A single-pass SwiftUI `.colorEffect`
// shader applied to a white square: it renders the glowing sphere AND the wispy
// transient smoke wafting around it, so there is no separate blurred bloom pass
// (cheaper, and the first frame compiles only one pipeline). The sphere occupies
// the central `R` fraction of the canvas; the surrounding ring is animated smoke.
// Colours track the app ring gradient (violet -> pink -> orange). `time` drives all
// motion; `amp` (0…1) swells the waveform from the live mic (idle = gentle pulse).

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

// Smooth value noise.
static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fractal brownian motion — five octaves of value noise.
static float fbm(float2 p) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        v += amp * valueNoise(p);
        p *= 2.0;
        amp *= 0.5;
    }
    return v;
}

[[ stitchable ]] half4 magicOrb(float2 pos, half4 color, float2 size, float time, float amp, float press, float wavePhase) {
    float2 uv = pos / size;
    float2 p = uv * 2.0 - 1.0;          // -1…1 across the whole canvas
    float r = length(p);

    const float R = 0.6;                 // sphere radius (fraction of the half-canvas)

    float3 deepBlue = float3(0.039, 0.388, 0.902); // #0A63E6 (BMW i deep blue)
    float3 elecBlue = float3(0.302, 0.651, 1.000); // #4DA6FF (BMW i electric blue)
    float3 aqua     = float3(0.553, 0.925, 1.000); // #8DECFF (aqua highlight)

    // ---------- surrounding smoke (the ring outside the sphere) ----------
    half3 smokePM = half3(0.0);
    half  smokeA  = 0.0h;
    {
        // When pressed, the smoke is pulled inward toward the sphere.
        float rr = r * (1.0 + press * 0.45);
        float2 inward = (r > 0.001 ? p / r : float2(0.0)) * press * 0.5;
        float2 sp = (p + inward) * 2.3;
        float st = time * 0.16;
        float2 sw = float2(fbm(sp + st), fbm(sp - st + 4.1));
        float d = fbm(sp + sw * 2.2 + float2(0.0, -st * 1.6));  // domain-warped wisps
        d = pow(clamp(d, 0.0, 1.0), 2.1);
        float fall  = smoothstep(1.0, R, rr);                   // 1 at sphere → 0 at edge
        float outer = smoothstep(R - 0.12, R + 0.12, rr);       // only outside the orb
        float dens  = d * fall * outer;
        float3 sc = float3(1.0);                                // white smoke
        float a = clamp(dens * 0.85 * (1.0 + press * 0.5), 0.0, 1.0);
        smokeA  = half(a);
        smokePM = half3(sc * a);
    }

    // ---------- the orb sphere ----------
    half3 orbPM = half3(0.0);
    half  orbA  = 0.0h;
    float mask = smoothstep(R, R - 0.10, r);
    if (mask > 0.001) {
        float2 s = p / R;                 // sphere interior remapped to -1…1
        float2 q = s * 1.6;
        float t = time * 0.25;
        float2 warp = float2(fbm(q + t), fbm(q - t + 5.2));
        float smoke = fbm(q + warp * 1.8 + float2(0.0, -t));
        smoke = pow(clamp(smoke, 0.0, 1.0), 1.4);
        float k = clamp(smoke * 1.1, 0.0, 1.0);
        float3 col = mix(deepBlue, elecBlue, smoothstep(0.0, 0.5, k));
        col = mix(col, aqua, smoothstep(0.5, 1.0, k));

        float rr = length(s);
        col += (1.0 - smoothstep(0.0, 0.7, rr)) * 0.18;                 // core glow
        float bevel = pow(max(0.0, 1.0 - length(s - float2(0.0, -0.5))), 4.0);
        col += bevel * 0.35;                                            // top bevel
        col += pow(clamp(rr, 0.0, 1.0), 3.5) * elecBlue * 0.6;         // fresnel rim
        col *= 0.9 + 0.1 * sin(time * 1.3);                            // breathe

        // ---------- occasional lightning crackle inside the orb ----------
        // Every ~PERIOD seconds a strike fires at a randomised offset, flashes
        // hard with a flickery decay + a quick restrike, then fades. Two jagged
        // bolts (main + branch) arc vertically through the sphere interior.
        {
            const float period = 6.5;
            float idx     = floor(time / period);
            float rnd     = hash21(float2(idx, 7.13));
            float strikeT = idx * period + 0.4 + rnd * (period - 1.6);
            float dt      = time - strikeT;
            if (dt > 0.0 && dt < 0.55) {
                float env    = exp(-dt * 11.0);                         // fast attack, decay
                float flick  = 0.55 + 0.45 * sin((time + rnd) * 70.0);  // crackle
                float second = exp(-abs(dt - 0.15) * 38.0) * 0.7;       // restrike
                float flash  = clamp((env + second) * flick, 0.0, 1.0);

                float b = 0.0;
                for (int k = 0; k < 2; k++) {
                    float sd      = rnd * 53.0 + float(k) * 17.0;
                    float wander  = (fbm(float2(sd, s.y * 3.0 + sd)) - 0.5) * 1.1;
                    wander       += (valueNoise(float2(sd * 3.0, s.y * 11.0)) - 0.5) * 0.3;
                    float originX = (hash21(float2(sd, 1.0)) - 0.5) * 0.7;
                    float dx      = abs(s.x - originX - wander);
                    float coreB   = smoothstep(0.025, 0.0, dx);
                    float glowB   = smoothstep(0.16, 0.0, dx) * 0.45;
                    b = max(b, coreB + glowB);
                }
                float vEnv  = smoothstep(1.0, 0.85, abs(s.y));          // soft top/bottom
                float bolt  = b * vEnv * flash;
                float3 boltCol = mix(aqua, float3(1.0), 0.6);           // white-aqua spark
                col += boltCol * bolt * 1.6;
            }
        }

        orbA  = half(mask);
        orbPM = half3(col * mask);
    }

    // ---------- composite orb over smoke (premultiplied "over") ----------
    half3 outPM = orbPM + smokePM * (1.0h - orbA);
    half  outA  = orbA  + smokeA  * (1.0h - orbA);

    // ---------- pink audio waveform — drawn last so it spans wider than the
    // sphere and runs a bit past the orb edge; tapers at the horizontal ends ----
    {
        float baseAmp = 0.14 * (0.4 + amp);
        // `wavePhase` is accumulated in Swift at a rate driven by the live voice level,
        // so these terms scroll faster as the AI speaks louder. The 0.73 ratio keeps the
        // two carriers in the same relation as the old fixed 2.2 / 1.6 speeds.
        float w = sin(p.x * 8.5 + wavePhase) * baseAmp;
        w += sin(p.x * 17.0 - wavePhase * 0.73) * baseAmp * 0.4;
        // A fast high-frequency "chatter" harmonic that only surfaces while talking
        // (scaled by amp) — gives the line its robotic, syllable-like buzz.
        w += sin(p.x * 34.0 + wavePhase * 1.9) * baseAmp * amp * 0.55;
        float core = smoothstep(0.04, 0.0, abs(p.y - w));
        float glow = smoothstep(0.13, 0.0, abs(p.y - w)) * 0.35;
        float hEnv = 1.0 - smoothstep(0.68, 0.86, abs(p.x));   // fade just outside the orb
        float wA = clamp((core + glow) * hEnv, 0.0, 1.0);
        float3 pink = float3(1.0, 0.36, 0.66);                 // #ff5ca8
        half3 wavePM = half3(pink * wA);
        half  waveA  = half(wA);
        outPM = wavePM + outPM * (1.0h - waveA);
        outA  = waveA  + outA  * (1.0h - waveA);
    }

    return half4(outPM, outA);
}
