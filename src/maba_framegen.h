/*==============================================================================================
  MABA Frame Gen (2x) - slot policy and honest frame counters (C99 / C++, header only)

  Copyright 2026 MABA Studios (owner: Muhammad Affan Bin Adnan)
  SPDX-License-Identifier: Apache-2.0

  Companion to maba_framegen.frag.glsl. MABA Frame Gen shows TWO frames for every REAL frame the
  game renders: the real frame, then one generated frame that extrapolates it forward by half a
  real-frame interval using per-pixel motion vectors and depth. Because the generated frame is
  predicted FORWARD from the newest real frame (not interpolated between two real frames), no
  real frame is ever held back, so frame generation adds no waiting latency.

  FRAME LOOP
      MabaFrameGen fg;  MabaFgInit(&fg);  MabaFgSetEnabled(&fg, 1);

      // Every frame the platform asks for (once per vsync):
      MabaFgSlot slot = MabaFgNextSlot(&fg);
      if (slot == MABA_FG_REAL)
      {
          // render the scene at render resolution into the next ping-pong slot, writing colour,
          // depth and per-pixel motion vectors (UV units, previous real frame -> this one)
      }
      else
      {
          // run the warp pass of maba_framegen.frag.glsl (one full-screen pass at render
          // resolution) on the last real frame, offset by MABA_FG_GEN_OFFSET of one real-frame
          // interval
      }
      // upscale to the screen with maba_upscaler.frag.glsl, draw the UI, present, then:
      int rolled = MabaFgPresented(&fg, slot, nowMs);   // nowMs: any monotonic clock
      if (rolled) show fg.realFps / fg.generatedFps / fg.displayedFps   // updates once per second

  HONEST COUNTERS
      Every counter counts frames actually handed to the platform for presentation, over a
      one-second window, and is only published when that window completes - there is no
      smoothing and no multiplication. displayedFps is real + generated frames per second, which
      is what a 60 Hz panel is physically able to show; it can never exceed the panel's refresh
      rate. With frame generation off every frame is real and displayedFps == realFps.

  CAMERA CUTS
      Call MabaFgInvalidate() on cuts, teleports, resolution changes and scene loads: the next
      frame is real and no frame is extrapolated from stale motion vectors.
==============================================================================================*/
#ifndef MABA_FRAMEGEN_H
#define MABA_FRAMEGEN_H

#ifdef __cplusplus
extern "C" {
#endif

/* How far ahead of the real frame the generated frame is predicted, as a fraction of the real
   frame interval. 0.5 = halfway to the next real frame; assumes evenly paced real frames. */
#define MABA_FG_GEN_OFFSET 0.5f
/* Length of the counting window; counters are published once per window. */
#define MABA_FG_WINDOW_MS  1000.0

typedef enum MabaFgSlot
{
    MABA_FG_REAL = 0,
    MABA_FG_GENERATED = 1
} MabaFgSlot;

typedef struct MabaFrameGen
{
    int    enabled;
    int    nextSlot;           /* MabaFgSlot to produce next while enabled */
    int    genPerReal;         /* generated frames after each real one: 1 = 2x (default), 2 = 3x */
    int    genIndex;           /* generated frames already presented since the last real one */
    int    haveReal;           /* a real frame exists to extrapolate from */
    double windowStartMs;      /* < 0 until the first presented frame */
    int    windowReal;         /* frames presented in the current window */
    int    windowGenerated;
    float  realFps;            /* last completed window */
    float  generatedFps;
    float  displayedFps;
    int    statsValid;         /* 1 once a full window has completed */
} MabaFrameGen;

static inline void MabaFgResetStats(MabaFrameGen* g)
{
    g->windowStartMs = -1.0;
    g->windowReal = 0;
    g->windowGenerated = 0;
    g->realFps = 0.0f;
    g->generatedFps = 0.0f;
    g->displayedFps = 0.0f;
    g->statsValid = 0;
}

static inline void MabaFgInit(MabaFrameGen* g)
{
    g->enabled = 0;
    g->nextSlot = MABA_FG_REAL;
    g->haveReal = 0;
    g->genPerReal = 1;
    g->genIndex = 0;
    MabaFgResetStats(g);
}

/* Generated frames per real frame: 1 (2x, default) or 2 (3x, optional). Takes effect from the next
   real frame; the counters restart so a window never mixes both. */
static inline void MabaFgSetGenPerReal(MabaFrameGen* g, int n)
{
    g->genPerReal = (n >= 2) ? 2 : 1;
    g->nextSlot = MABA_FG_REAL;
    g->haveReal = 0;
    g->genIndex = 0;
    MabaFgResetStats(g);
}

/* How far ahead of the newest real frame the generated frame about to be produced is predicted, as
   a fraction of a real-frame interval: 1/2 at 2x; 1/3 then 2/3 at 3x. */
static inline float MabaFgGenOffset(const MabaFrameGen* g)
{
    return (float)(g->genIndex + 1) / (float)(g->genPerReal + 1);
}

/* Turn frame generation on or off. Restarts the counters so a window never mixes both states. */
static inline void MabaFgSetEnabled(MabaFrameGen* g, int enabled)
{
    g->enabled = enabled ? 1 : 0;
    g->nextSlot = MABA_FG_REAL;
    g->haveReal = 0;
    g->genIndex = 0;
    MabaFgResetStats(g);
}

/* Camera cut / resolution change: the next frame is real; stats keep running. */
static inline void MabaFgInvalidate(MabaFrameGen* g)
{
    g->nextSlot = MABA_FG_REAL;
    g->haveReal = 0;
    g->genIndex = 0;
}

/* Which kind of frame to produce next. Without a valid real frame it is always REAL. */
static inline MabaFgSlot MabaFgNextSlot(const MabaFrameGen* g)
{
    if (!g->enabled || !g->haveReal) return MABA_FG_REAL;
    return (MabaFgSlot)g->nextSlot;
}

/* Record that a frame was handed to the platform for presentation. slot is the kind of frame it was:
   it advances the slot policy and feeds the counters, so real / generated fps stay honest.
   Returns 1 when a one-second window just completed (the published fps values changed). */
static inline int MabaFgPresented(MabaFrameGen* g, MabaFgSlot slot, double nowMs)
{
    double elapsed;
    if (slot == MABA_FG_REAL)
    {
        g->haveReal = 1;
        g->genIndex = 0;
        g->nextSlot = g->enabled ? MABA_FG_GENERATED : MABA_FG_REAL;
    }
    else
    {
        g->genIndex++;
        g->nextSlot = (g->genIndex < g->genPerReal) ? MABA_FG_GENERATED : MABA_FG_REAL;
    }

    if (g->windowStartMs < 0.0)
    {
        /* This frame only marks the start of the first window; counting begins after it. */
        g->windowStartMs = nowMs;
        g->windowReal = 0;
        g->windowGenerated = 0;
        return 0;
    }
    if (slot == MABA_FG_REAL) g->windowReal++; else g->windowGenerated++;

    elapsed = nowMs - g->windowStartMs;
    if (elapsed < MABA_FG_WINDOW_MS) return 0;

    g->realFps = (float)((double)g->windowReal * 1000.0 / elapsed);
    g->generatedFps = (float)((double)g->windowGenerated * 1000.0 / elapsed);
    g->displayedFps = g->realFps + g->generatedFps;
    g->statsValid = 1;
    g->windowStartMs = nowMs;   /* this frame starts the next window */
    g->windowReal = 0;
    g->windowGenerated = 0;
    return 1;
}
/*==============================================================================================
  FRAME GEN GOVERNOR - Frame Gen must never make things worse
  A generated frame costs GPU time. When the real frame is cheap (the panel is already full) or the
  generated frame is too dear, two frames per (real + generated) can be FEWER than one frame per
  real frame. The governor measures the interval between real frames with Frame Gen on and, in short
  probes, with it off, and keeps Frame Gen on only when it really shows more frames per second on
  the panel (capped at the panel's refresh rate), with a margin.

      MabaFgGovernor gv;  MabaFgGovInit(&gv, 60.0f);
      // once per REAL frame, with the time since the previous real frame:
      int wantOn = MabaFgGovStep(&gv, intervalMs);   // 1 = run Frame Gen for the next real frame
  The caller shows Frame Gen only while wantOn is 1. The first few real frames after a state change
  are ignored (history, pacing). All times are in milliseconds.
==============================================================================================*/
#define MABA_GOV_SETTLE_FRAMES 4      /* real frames ignored after a state change */
#define MABA_GOV_MEASURE_FRAMES 14    /* real frames averaged per measurement */
#define MABA_GOV_PROBE_MS 20000.0     /* how often a running state re-measures the other one */
#define MABA_GOV_MARGIN 1.05f         /* Frame Gen must show at least 5% more than off */

typedef enum MabaGovPhase
{
    MABA_GOV_RUN_ON = 0,      /* Frame Gen on, its interval EMA is kept */
    MABA_GOV_PROBE_OFF = 1,   /* off for a few frames to measure the plain real-frame interval */
    MABA_GOV_RUN_OFF = 2,     /* Frame Gen judged not worth it */
    MABA_GOV_PROBE_ON = 3     /* on for a few frames to see if it pays now */
} MabaGovPhase;

typedef struct MabaFgGovernor
{
    int    phase;
    float  panelHz;
    int    settle;            /* frames still to ignore */
    int    count;             /* frames accumulated in the current measurement */
    double sum;               /* ... and their total interval */
    float  onMs;              /* interval between real frames with Frame Gen on (last measurement) */
    float  offMs;             /* ... and with it off */
    double sinceProbeMs;      /* time spent in the running phase */
    int    wantOn;
} MabaFgGovernor;

static inline void MabaFgGovInit(MabaFgGovernor* v, float panelHz)
{
    v->phase = MABA_GOV_PROBE_OFF;      /* measure the plain rate first */
    v->panelHz = panelHz > 1.0f ? panelHz : 60.0f;
    v->settle = MABA_GOV_SETTLE_FRAMES;
    v->count = 0;
    v->sum = 0.0;
    v->onMs = 0.0f;
    v->offMs = 0.0f;
    v->sinceProbeMs = 0.0;
    v->wantOn = 0;
}

/* Frames per second the panel shows for a real-frame interval, with or without Frame Gen. */
static inline float MabaFgGovShown(const MabaFgGovernor* v, float intervalMs, int frameGen)
{
    float fps = (frameGen ? 2000.0f : 1000.0f) / (intervalMs > 0.1f ? intervalMs : 0.1f);
    return fps < v->panelHz ? fps : v->panelHz;
}

static inline void MabaFgGovEnter(MabaFgGovernor* v, int phase)
{
    v->phase = phase;
    v->settle = MABA_GOV_SETTLE_FRAMES;
    v->count = 0;
    v->sum = 0.0;
    v->sinceProbeMs = 0.0;
    v->wantOn = (phase == MABA_GOV_RUN_ON || phase == MABA_GOV_PROBE_ON) ? 1 : 0;
}

/* Frame Gen pays when it shows clearly more than off AND the panel is not already full without it. */
static inline int MabaFgGovPays(const MabaFgGovernor* v)
{
    float off = MabaFgGovShown(v, v->offMs, 0);
    float on = MabaFgGovShown(v, v->onMs, 1);
    if (off >= v->panelHz - 1.5f) return 0;           /* the panel is already full */
    return on >= off * MABA_GOV_MARGIN;
}

/* Call once per real frame with the time since the previous real frame. Returns whether Frame Gen
   should run for the next real frame. */
static inline int MabaFgGovStep(MabaFgGovernor* v, float intervalMs)
{
    if (intervalMs <= 0.0f) return v->wantOn;
    if (v->settle > 0) { v->settle--; return v->wantOn; }
    v->sinceProbeMs += intervalMs;
    v->sum += intervalMs;
    v->count++;

    if (v->phase == MABA_GOV_RUN_ON || v->phase == MABA_GOV_RUN_OFF)
    {
        /* Keep the running interval fresh and re-measure the other state now and then. */
        float avg = (float)(v->sum / v->count);
        if (v->count >= MABA_GOV_MEASURE_FRAMES)
        {
            if (v->phase == MABA_GOV_RUN_ON) v->onMs = avg; else v->offMs = avg;
            v->sum = 0.0; v->count = 0;
        }
        if (v->sinceProbeMs >= MABA_GOV_PROBE_MS)
            MabaFgGovEnter(v, v->phase == MABA_GOV_RUN_ON ? MABA_GOV_PROBE_OFF : MABA_GOV_PROBE_ON);
        return v->wantOn;
    }

    if (v->count < MABA_GOV_MEASURE_FRAMES) return v->wantOn;
    {
        float avg = (float)(v->sum / v->count);
        if (v->phase == MABA_GOV_PROBE_OFF)
        {
            v->offMs = avg;
            if (v->onMs <= 0.0f) { MabaFgGovEnter(v, MABA_GOV_PROBE_ON); return v->wantOn; }   /* start-up: now measure on */
            MabaFgGovEnter(v, MabaFgGovPays(v) ? MABA_GOV_RUN_ON : MABA_GOV_RUN_OFF);
        }
        else   /* MABA_GOV_PROBE_ON */
        {
            v->onMs = avg;
            MabaFgGovEnter(v, MabaFgGovPays(v) ? MABA_GOV_RUN_ON : MABA_GOV_RUN_OFF);
        }
    }
    return v->wantOn;
}

#ifdef __cplusplus
}
#endif
#endif /* MABA_FRAMEGEN_H */
