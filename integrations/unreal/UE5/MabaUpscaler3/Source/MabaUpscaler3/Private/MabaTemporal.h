/*==============================================================================================
  MABA-Upscaler 2 (Temporal) - jitter sequence and resolve-pass state (C99 / C++, header only)

  Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
  SPDX-License-Identifier: Apache-2.0

  Companion to maba_temporal.frag.glsl. Decides the per-frame sub-texel jitter, tracks the
  Halton phase, and tells the renderer when the history must be reset.

  FRAME CONTRACT (see the shader header for the full uniform list)
    1. Jitter the scene projection so the image content moves BY (jitterX, jitterY) texels at
       RENDER resolution (a perspective projection, column-major, GL-style; clip.w = -z):
         proj[2][0] -= jitterX * 2.0f / renderWidth;
         proj[2][1] -= jitterY * 2.0f / renderHeight;
       (For row-major matrices, transpose the indices; for an orthographic projection the
       translation column m[3][0], m[3][1] is shifted by += instead. Keep the UI unjittered.)
       Pass the same (jitterX, jitterY) to the resolve pass as uMabaJitter.
    2. Render scene color + depth at render resolution into the current ping-pong slot.
    3. Run maba_temporal.frag.glsl at render resolution:
         reads  current color, current depth, PREVIOUS resolve, PREVIOUS depth
         writes the new resolve (which becomes next frame's history)
       Pass uMabaInvViewProj = inverse(UNJITTERED current view-proj),
            uMabaPrevViewProj = the UNJITTERED view-proj of LAST frame.
    4. Upscale the resolve to the screen with maba_upscaler.frag.glsl as usual.
    5. Swap the ping-pong slots.

  RESETS
    Call MabaTemporalReset() on camera cuts, resolution changes, and before the first frame.
    The next MabaTemporalBeginFrame() reports reset = 1 and the shader ignores history.

  TUNING (MabaTemporalInit params)
    historyWeight  0.85..0.95  - higher = more stable, more ghosting risk. Default 0.9.
    depthTolerance 0.005..0.02 - disocclusion rejection threshold. Default 0.01.
    clipGamma      1.0..1.5    - variance-clip box width. Default 1.25.
==============================================================================================*/
#ifndef MABA_TEMPORAL_H
#define MABA_TEMPORAL_H

#ifdef __cplusplus
extern "C" {
#endif

#define MABA_TEMPORAL_PHASES 16

typedef struct MabaTemporal
{
    int   phase;            /* next Halton phase to use */
    int   resetNext;        /* 1 = next frame must ignore history */
    float historyWeight;
    float depthTolerance;
    float clipGamma;
} MabaTemporal;

typedef struct MabaTemporalFrame
{
    float jitterX;          /* sub-texel jitter at render resolution, [-0.5, 0.5] */
    float jitterY;
    int   reset;            /* pass as uMabaTemporalParams.z */
    int   phase;
} MabaTemporalFrame;

static inline void MabaTemporalReset(MabaTemporal* t)
{
    t->resetNext = 1;
    t->phase = 0;
}

static inline void MabaTemporalInit(MabaTemporal* t, float historyWeight, float depthTolerance,
                                    float clipGamma)
{
    t->historyWeight = (historyWeight > 0.0f && historyWeight < 1.0f) ? historyWeight : 0.9f;
    t->depthTolerance = (depthTolerance > 0.0f) ? depthTolerance : 0.01f;
    t->clipGamma = (clipGamma > 0.0f) ? clipGamma : 1.25f;
    MabaTemporalReset(t);
}

/* Halton sequence value in [0,1) for the given base (>= 2) and 1-based index. */
static inline float MabaHalton(int index, int base)
{
    float f = 1.0f, r = 0.0f;
    if (base < 2) return 0.0f;   /* base 0 / 1 would never terminate */
    while (index > 0)
    {
        f /= (float)base;
        r += f * (float)(index % base);
        index /= base;
    }
    return r;
}

/* Call once per frame, before rendering the scene. */
static inline MabaTemporalFrame MabaTemporalBeginFrame(MabaTemporal* t)
{
    MabaTemporalFrame f;
    f.phase = t->phase;
    f.reset = t->resetNext;
    t->resetNext = 0;
    /* Halton(2,3), 16 phases, centred to [-0.5, 0.5] texel. */
    f.jitterX = MabaHalton(t->phase + 1, 2) - 0.5f;
    f.jitterY = MabaHalton(t->phase + 1, 3) - 0.5f;
    t->phase = (t->phase + 1) % MABA_TEMPORAL_PHASES;
    return f;
}

/* Values for uMabaTemporalParams. */
static inline void MabaTemporalUniforms(const MabaTemporal* t, const MabaTemporalFrame* f,
                                        float params[4])
{
    params[0] = t->historyWeight;
    params[1] = t->depthTolerance;
    params[2] = (float)f->reset;
    params[3] = t->clipGamma;
}

#ifdef __cplusplus
}
#endif
#endif /* MABA_TEMPORAL_H */
