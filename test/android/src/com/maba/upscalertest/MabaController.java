package com.maba.upscalertest;

/**
 * Pure-Java port of the Dynamic controller in maba_upscaler.h (no Android dependencies, so it
 * can be unit-tested on the host). Kept line-for-line in sync with the C header; the parity
 * test in test/android/src/.../Parity.java feeds both the same trace and diffs the sequences.
 */
public final class MabaController implements DynController {
    /** The whole ladder: scale 0.35 (rung -15) .. 1.00 = native (rung 51). */
    public static final int RUNG_FLOOR = -15, RUNG_CEIL = 51;
    /** The span of the classic presets (0.50..0.77): their anchors, no longer a limit on Dynamic. */
    public static final int RUNG_COUNT = 29;
    public static final int RUNG_MIN = 0, RUNG_MAX = RUNG_COUNT - 1;

    public static final int MODE_DYNAMIC = 0, MODE_ULTRA_QUALITY = 1, MODE_QUALITY = 2,
        MODE_BALANCED = 3, MODE_PERFORMANCE = 4;

    public static final int START_RUNG = 10;
    public static final float OVER_RATIO = 1.02f;
    public static final int DOWN_FRAMES = 20, UP_FRAMES = 180, UP_FRAMES_MAX = 3600,
        PROVEN_FRAMES = 300;
    /** A multi-rung step up must be predicted to use at most this share of the frame budget. */
    public static final float HEADROOM = 0.90f;
    /** Most rungs one step up may climb. */
    public static final int MAX_JUMP = 16;

    public int mode;
    public float targetMs;
    public int rung;
    public float avgMs;
    public int overFrames, goodFrames, upWait;
    public boolean probing;
    public int rungMin, rungMax;     // the range Dynamic mode may use (default: the whole ladder)
    public int probeFrom;            // the rung the current step up started from

    public MabaController(int mode, float targetFps) {
        targetMs = 1000f / (targetFps > 1f ? targetFps : 60f);
        rungMin = RUNG_FLOOR;
        rungMax = RUNG_CEIL;
        setMode(mode);
    }

    /** Render scale of a rung in whole percent (exact). */
    public static int rungPercent(int rung) {
        return (rung <= 9) ? (50 + rung) : (49 + rung);
    }

    public static float rungScale(int rung) {
        return (float) rungPercent(rung) * 0.01f;
    }

    public static boolean rungQuality(int rung) {
        return rung >= 10;
    }

    /** True at scale 1.00: render at output size and skip the upscale pass. */
    public static boolean rungNative(int rung) {
        return rungPercent(rung) >= 100;
    }

    /** The rung closest to a render scale (0.35..1.00). 0.59 maps to the quality build (rung 10). */
    public static int scaleToRung(float scale) {
        int pct = (int) (scale * 100f + 0.5f);
        if (pct < 35) pct = 35;
        if (pct > 100) pct = 100;
        return (pct <= 58) ? (pct - 50) : (pct - 49);
    }

    public static int modeRung(int mode) {
        switch (mode) {
            case MODE_ULTRA_QUALITY: return 28;
            case MODE_QUALITY: return 18;
            case MODE_BALANCED: return 10;
            case MODE_PERFORMANCE: return 0;
            default: return START_RUNG;
        }
    }

    private int clampRung(int r) {
        if (r < rungMin) r = rungMin;
        if (r > rungMax) r = rungMax;
        return r;
    }

    public void setMode(int mode) {
        this.mode = mode;
        rung = modeRung(mode);
        if (mode == MODE_DYNAMIC) rung = clampRung(rung);   // presets are explicit
        avgMs = 0f;
        overFrames = 0;
        goodFrames = 0;
        upWait = UP_FRAMES;
        probing = false;
        probeFrom = rung;
    }

    /** Restrict Dynamic mode to a render-scale range. In Dynamic mode the rung moves inside it. */
    @Override public void setScaleRange(float minScale, float maxScale) {
        int lo = scaleToRung(minScale);
        int hi = scaleToRung(maxScale);
        if (hi < lo) hi = lo;
        rungMin = lo;
        rungMax = hi;
        if (mode == MODE_DYNAMIC) rung = clampRung(rung);
        avgMs = 0f;
        overFrames = 0;
        goodFrames = 0;
        probing = false;
        probeFrom = rung;
    }

    public void setTargetFps(float targetFps) {
        targetMs = 1000f / (targetFps > 1f ? targetFps : 60f);
        avgMs = 0f;
        overFrames = 0;
        goodFrames = 0;
        probing = false;
    }

    public void seedRung(int r) {
        rung = clampRung(r);
        avgMs = 0f;
        overFrames = 0;
        goodFrames = 0;
        probing = false;
        probeFrom = rung;
    }

    public void updateDynamic(float frameMs) {
        if (frameMs <= 0f || frameMs > 1000f) return;
        avgMs = avgMs <= 0f ? frameMs : avgMs + (frameMs - avgMs) * 0.1f;
        if (avgMs > targetMs * OVER_RATIO) {
            goodFrames = 0;
            if (++overFrames >= DOWN_FRAMES && rung > rungMin) {
                int next = rung - 1;
                if (probing) {
                    // A failed step up returns to the rung it started from, in one step.
                    if (probeFrom < rung && probeFrom >= rungMin) next = probeFrom;
                    upWait = Math.min(upWait * 2, UP_FRAMES_MAX);
                    probing = false;
                }
                rung = next;
                overFrames = 0;
                avgMs = targetMs;
            }
        } else {
            overFrames = 0;
            goodFrames++;
            if (probing && goodFrames >= PROVEN_FRAMES) {
                probing = false;
                upWait = Math.max(UP_FRAMES, upWait / 2);
            }
            if (!probing && goodFrames >= upWait && rung < rungMax) {
                // One rung, or several when the measured frame time says they fit: the time at a
                // higher rung is predicted as if the whole frame scaled with the pixel count.
                int cur = rungPercent(rung);
                int next = rung + 1;
                for (int r = rung + 2; r <= rungMax && r <= rung + MAX_JUMP; r++) {
                    int p = rungPercent(r);
                    if (avgMs * (float) (p * p) / (float) (cur * cur) > targetMs * HEADROOM) break;
                    next = r;
                }
                probeFrom = rung;
                rung = next;
                goodFrames = 0;
                probing = true;
            }
        }
    }

    /** Call once per frame (present-to-present or GPU-only ms); returns the rung to render at. */
    public int beginFrame(float lastFrameMs) {
        if (mode == MODE_DYNAMIC) updateDynamic(lastFrameMs);
        return rung;
    }

    @Override public int rung() { return rung; }

    public int renderWidth(int outW) {
        return Math.max(2, Math.round(outW * rungScale(rung)));
    }

    public int renderHeight(int outH) {
        return Math.max(2, Math.round(outH * rungScale(rung)));
    }
}
