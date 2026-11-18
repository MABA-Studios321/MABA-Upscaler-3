/*==============================================================================================
  MABA Upscaler 2 - quality modes and dynamic controller (C99 / C++, header only)

  Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
  SPDX-License-Identifier: Apache-2.0

  This header has no graphics-API dependency. It decides, each frame, what resolution to render
  the 3D scene at and which build of maba_upscaler.frag.glsl to upscale it with.

  RUNGS (continuous resolution ladder, lowest to highest)
      rung -15..-1  scale 0.35..0.49 in 1% steps, fast shader      (constrained devices)
      rung 0..9     scale 0.50..0.59 in 1% steps, fast shader
      rung 10       scale 0.59, quality shader          "Balanced"
      rung 11..51   scale 0.60..1.00 in 1% steps, quality shader   (rung 51 = native resolution)
  The classic presets are anchors on this ladder:
      Performance = rung 0 (0.50, fast), Balanced = rung 10 (0.59, quality),
      Quality = rung 18 (0.67, quality), Ultra Quality = rung 28 (0.77, quality).
  "fast shader" is the default build; "quality shader" is the MABA_QUALITY 1 build. On a device
  without textureGather (OpenGL ES 3.0) use the MABA_GATHER 0 build for every rung. At rung 51 the
  frame is native: MabaFrame.isNative is set and the upscale pass can be skipped entirely.

  RANGE (scalability)
      Dynamic mode moves inside [rungMin, rungMax]. By default that is the WHOLE ladder, so a weak
      GPU can drop to 0.35 and a strong one climbs to native; nothing is capped for a hardware
      class. Narrow it with MabaSetScaleRange(&maba, minScale, maxScale) when a game wants a
      quality floor or a render-scale ceiling. The fixed presets ignore the range.

  MODES
      MABA_MODE_DYNAMIC (default)  moves along the rungs to hold a target frame time. It steps down
                                   one rung at a time when over budget, and steps UP by as many
                                   rungs as the measured headroom predicts will still fit (see
                                   MabaUpdateDynamic), so a GPU with plenty of spare time reaches
                                   its sustainable resolution in seconds, not minutes.
      MABA_MODE_ULTRA_QUALITY / QUALITY / BALANCED / PERFORMANCE  stay on one anchor rung.

  TIMING
      MabaBeginFrame(u, lastFrameMs, ...)     present-to-present frame time. Simple, but with
                                              vsync on it cannot see GPU headroom: a frame that
                                              finishes early still reports 16.7 ms at 60 Hz.
      MabaBeginFrameGpu(u, gpuMs, ...)        GPU-only time from a timer query (recommended;
                                              EXT_disjoint_timer_query on GLES, vkCmdWriteTimestamp
                                              on Vulkan). Steps up whenever the GPU is comfortably
                                              under budget, even at the vsync cap. Some drivers
                                              latch timestamps once per frame (begin == end); such
                                              a timer cannot measure GPU time - detect it and fall
                                              back to a glFinish-timed probe frame.

  USAGE
      MabaUpscaler maba;
      MabaInit(&maba, MABA_MODE_DYNAMIC, 60.0f);
      // optional: MabaSetScaleRange(&maba, 0.50f, 0.85f);

      // Allocate the scene render target ONCE at the largest size this controller can ask for:
      int texW, texH;
      MabaMaxRenderSizeFor(&maba, outW, outH, &texW, &texH);

      // Every frame:
      MabaFrame f = MabaBeginFrameGpu(&maba, lastGpuMs, outW, outH);
      //   render the scene into viewport (0, 0, f.renderWidth, f.renderHeight) of that target
      //   if f.isNative: present the render target directly, no upscale pass
      //   otherwise bind the program for f.qualityShader (0 = fast build, 1 = MABA_QUALITY build)
      float size[4], params[4];
      MabaUniforms(&f, texW, texH, 0.5f, size, params);
      //   set uMabaInputSize = size, uMabaParams = params, draw 3 vertices, then draw the UI

  Thermal / battery: call MabaSetTargetFps(&maba, 30.0f) when the device throttles; the
  controller keeps its rung and re-settles against the new budget.
==============================================================================================*/
#ifndef MABA_UPSCALER_H
#define MABA_UPSCALER_H

#ifdef __cplusplus
extern "C" {
#endif

/* The whole ladder: scale 0.35 (rung -15) .. 1.00 = native (rung 51). */
#define MABA_RUNG_FLOOR (-15)
#define MABA_RUNG_CEIL  51

/* The span of the classic presets (0.50..0.77), kept for source compatibility: it is the range the
   presets are anchored in, no longer a limit on Dynamic mode. */
#define MABA_RUNG_COUNT 29
#define MABA_RUNG_MIN 0
#define MABA_RUNG_MAX (MABA_RUNG_COUNT - 1)

typedef enum MabaMode
{
    MABA_MODE_DYNAMIC = 0,
    MABA_MODE_ULTRA_QUALITY,
    MABA_MODE_QUALITY,
    MABA_MODE_BALANCED,
    MABA_MODE_PERFORMANCE
} MabaMode;

/* Rung -> render scale (in whole percent, exact) and shader build. */
static inline int MabaRungPercent(int rung)
{
    return (rung <= 9) ? (50 + rung) : (49 + rung);
}

static inline float MabaRungScale(int rung)
{
    return (float)MabaRungPercent(rung) * 0.01f;
}

static inline int MabaRungQuality(int rung)
{
    return rung >= 10;
}

/* The rung closest to a render scale (0.35..1.00). 0.59 maps to the quality build (rung 10). */
static inline int MabaScaleToRung(float scale)
{
    int pct = (int)(scale * 100.0f + 0.5f);
    if (pct < 35) pct = 35;
    if (pct > 100) pct = 100;
    return (pct <= 58) ? (pct - 50) : (pct - 49);
}

typedef struct MabaUpscaler
{
    MabaMode mode;
    float targetMs;     /* frame time to hold in Dynamic mode */
    int   rung;         /* current position on the ladder */
    float avgMs;        /* smoothed frame time */
    int   overFrames;   /* consecutive frames over budget */
    int   goodFrames;   /* consecutive frames within budget */
    int   upWait;       /* good frames required before trying a higher rung */
    int   probing;      /* 1 while a recent step up is still being proven */
    int   rungMin;      /* lowest rung Dynamic mode may use */
    int   rungMax;      /* highest rung Dynamic mode may use */
    int   probeFrom;    /* the rung the current step up started from */
} MabaUpscaler;

typedef struct MabaFrame
{
    int   rung;
    int   renderWidth;
    int   renderHeight;
    int   qualityShader;
    float scale;
    int   isNative;     /* 1 at scale 1.00: render at output size and skip the upscale pass */
} MabaFrame;

/* Tuning of the dynamic controller. */
#define MABA_DYN_START_RUNG    10     /* Balanced */
#define MABA_DYN_OVER_RATIO    1.02f  /* smoothed frame time above target * this = over budget */
#define MABA_DYN_DOWN_FRAMES   20     /* over-budget frames before stepping down */
#define MABA_DYN_UP_FRAMES     180    /* good frames before the first attempt to step up */
#define MABA_DYN_UP_FRAMES_MAX 3600   /* cap on the back-off after failed attempts */
#define MABA_DYN_PROVEN_FRAMES 300    /* good frames after a step up that halve the back-off */
#define MABA_DYN_HEADROOM      0.90f  /* a multi-rung step up must be predicted to use at most this
                                         share of the frame budget */
#define MABA_DYN_MAX_JUMP      16     /* most rungs one step up may climb */

static inline int MabaModeRung(MabaMode mode)
{
    switch (mode)
    {
        case MABA_MODE_ULTRA_QUALITY: return 28;
        case MABA_MODE_QUALITY:       return 18;
        case MABA_MODE_BALANCED:      return 10;
        case MABA_MODE_PERFORMANCE:   return 0;
        case MABA_MODE_DYNAMIC:       return MABA_DYN_START_RUNG;
        default:                      return MABA_DYN_START_RUNG;
    }
}

static inline int MabaClampRung(const MabaUpscaler* u, int rung)
{
    if (rung < u->rungMin) rung = u->rungMin;
    if (rung > u->rungMax) rung = u->rungMax;
    return rung;
}

static inline void MabaSetMode(MabaUpscaler* u, MabaMode mode)
{
    u->mode = mode;
    u->rung = MabaModeRung(mode);
    if (mode == MABA_MODE_DYNAMIC) u->rung = MabaClampRung(u, u->rung);   /* presets are explicit */
    u->avgMs = 0.0f;
    u->overFrames = 0;
    u->goodFrames = 0;
    u->upWait = MABA_DYN_UP_FRAMES;
    u->probing = 0;
    u->probeFrom = u->rung;
}

static inline void MabaInit(MabaUpscaler* u, MabaMode mode, float targetFps)
{
    u->targetMs = 1000.0f / (targetFps > 1.0f ? targetFps : 60.0f);
    u->rungMin = MABA_RUNG_FLOOR;
    u->rungMax = MABA_RUNG_CEIL;
    MabaSetMode(u, mode);
}

/* Restrict Dynamic mode to a render-scale range, e.g. a quality floor or a ceiling. The default
   is the whole ladder (0.35 .. 1.00). In Dynamic mode the current rung is moved inside the new
   range; a fixed preset keeps its rung (presets ignore the range). */
static inline void MabaSetScaleRange(MabaUpscaler* u, float minScale, float maxScale)
{
    int lo = MabaScaleToRung(minScale);
    int hi = MabaScaleToRung(maxScale);
    if (hi < lo) hi = lo;
    u->rungMin = lo;
    u->rungMax = hi;
    if (u->mode == MABA_MODE_DYNAMIC) u->rung = MabaClampRung(u, u->rung);
    u->avgMs = 0.0f;
    u->overFrames = 0;
    u->goodFrames = 0;
    u->probing = 0;
    u->probeFrom = u->rung;
}

/* Change the frame-rate budget at runtime (thermal throttling, battery saver, user setting).
   Keeps the current rung; the controller re-settles against the new budget. */
static inline void MabaSetTargetFps(MabaUpscaler* u, float targetFps)
{
    u->targetMs = 1000.0f / (targetFps > 1.0f ? targetFps : 60.0f);
    u->avgMs = 0.0f;
    u->overFrames = 0;
    u->goodFrames = 0;
    u->probing = 0;
}

/* Seed the ladder from a startup calibration instead of always starting at Balanced. */
static inline void MabaSeedRung(MabaUpscaler* u, int rung)
{
    u->rung = MabaClampRung(u, rung);
    u->avgMs = 0.0f;
    u->overFrames = 0;
    u->goodFrames = 0;
    u->probing = 0;
    u->probeFrom = u->rung;
}

/* Size to allocate the scene render target at so every rung this controller can ask for fits
   without reallocation. */
static inline void MabaMaxRenderSizeFor(const MabaUpscaler* u, int outW, int outH, int* texW, int* texH)
{
    float s = MabaRungScale(u->rungMax);
    *texW = (int)((float)outW * s + 0.5f);
    *texH = (int)((float)outH * s + 0.5f);
}

/* Same for the whole ladder: output size. Always large enough, whatever range is set later. */
static inline void MabaMaxRenderSize(int outW, int outH, int* texW, int* texH)
{
    float s = MabaRungScale(MABA_RUNG_CEIL);
    *texW = (int)((float)outW * s + 0.5f);
    *texH = (int)((float)outH * s + 0.5f);
}

/* Dynamic mode: step down quickly when frames run over budget, step up cautiously, and back off
   exponentially when a step up does not hold, so the game does not oscillate.

   A step up climbs one rung, or several when the measured frame time says they fit: the frame time
   at a higher rung is predicted as if the whole frame scaled with the pixel count (an upper bound:
   fixed costs do not grow), and the highest rung predicted to stay within MABA_DYN_HEADROOM of the
   budget is taken, at most MABA_DYN_MAX_JUMP rungs. A step up that fails returns to the rung it
   started from, not one rung per over-budget window. */
static inline void MabaUpdateDynamic(MabaUpscaler* u, float frameMs)
{
    int over;
    if (frameMs <= 0.0f || frameMs > 1000.0f) return;   /* ignore pauses and loading hitches */
    u->avgMs = (u->avgMs <= 0.0f) ? frameMs : u->avgMs + (frameMs - u->avgMs) * 0.1f;
    over = u->avgMs > u->targetMs * MABA_DYN_OVER_RATIO;

    if (over)
    {
        u->goodFrames = 0;
        if (++u->overFrames >= MABA_DYN_DOWN_FRAMES && u->rung > u->rungMin)
        {
            int next = u->rung - 1;
            if (u->probing)
            {
                if (u->probeFrom < u->rung && u->probeFrom >= u->rungMin) next = u->probeFrom;
                u->upWait *= 2;
                if (u->upWait > MABA_DYN_UP_FRAMES_MAX) u->upWait = MABA_DYN_UP_FRAMES_MAX;
                u->probing = 0;
            }
            u->rung = next;
            u->overFrames = 0;
            u->avgMs = u->targetMs;
        }
    }
    else
    {
        u->overFrames = 0;
        u->goodFrames++;
        if (u->probing && u->goodFrames >= MABA_DYN_PROVEN_FRAMES)
        {
            u->probing = 0;
            u->upWait /= 2;   /* relax the back-off gradually, not all at once */
            if (u->upWait < MABA_DYN_UP_FRAMES) u->upWait = MABA_DYN_UP_FRAMES;
        }
        if (!u->probing && u->goodFrames >= u->upWait && u->rung < u->rungMax)
        {
            int cur = MabaRungPercent(u->rung);
            int next = u->rung + 1;
            int r;
            for (r = u->rung + 2; r <= u->rungMax && r <= u->rung + MABA_DYN_MAX_JUMP; r++)
            {
                int p = MabaRungPercent(r);
                if (u->avgMs * (float)(p * p) / (float)(cur * cur) > u->targetMs * MABA_DYN_HEADROOM) break;
                next = r;
            }
            u->probeFrom = u->rung;
            u->rung = next;
            u->goodFrames = 0;
            u->probing = 1;
        }
    }
}

static inline MabaFrame MabaMakeFrame(const MabaUpscaler* u, int outW, int outH)
{
    MabaFrame f;
    int pct = MabaRungPercent(u->rung);
    f.rung = u->rung;
    f.scale = MabaRungScale(u->rung);
    f.qualityShader = MabaRungQuality(u->rung);
    f.isNative = pct >= 100;
    f.renderWidth = (int)((float)outW * f.scale + 0.5f);
    f.renderHeight = (int)((float)outH * f.scale + 0.5f);
    if (f.renderWidth < 2) f.renderWidth = 2;
    if (f.renderHeight < 2) f.renderHeight = 2;
    return f;
}

/* Call once per frame with the previous present-to-present frame time. */
static inline MabaFrame MabaBeginFrame(MabaUpscaler* u, float lastFrameMs, int outW, int outH)
{
    if (u->mode == MABA_MODE_DYNAMIC) MabaUpdateDynamic(u, lastFrameMs);
    return MabaMakeFrame(u, outW, outH);
}

/* Call once per frame with the previous frame's GPU-only time (timer query). Preferred: it sees
   headroom even when vsync caps the present-to-present time. */
static inline MabaFrame MabaBeginFrameGpu(MabaUpscaler* u, float gpuMs, int outW, int outH)
{
    if (u->mode == MABA_MODE_DYNAMIC) MabaUpdateDynamic(u, gpuMs);
    return MabaMakeFrame(u, outW, outH);
}

/* Values for the shader's uMabaInputSize and uMabaParams. texW/texH is the allocated size of the
   scene render target; sharpness is 0..1. */
static inline void MabaUniforms(const MabaFrame* f, int texW, int texH, float sharpness,
                                float inputSize[4], float params[4])
{
    inputSize[0] = (float)f->renderWidth;
    inputSize[1] = (float)f->renderHeight;
    inputSize[2] = 1.0f / (float)texW;
    inputSize[3] = 1.0f / (float)texH;
    params[0] = sharpness;
    params[1] = params[2] = params[3] = 0.0f;
}

#ifdef __cplusplus
}
#endif
#endif /* MABA_UPSCALER_H */
