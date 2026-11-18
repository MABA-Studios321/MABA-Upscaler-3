package com.maba.upscalertest;

/** Pure-Java port of maba_temporal.h (Halton jitter + reset state). No Android dependencies. */
public final class MabaTemporal {
    public static final int PHASES = 16;

    public int phase;
    public boolean resetNext;
    public float historyWeight, depthTolerance, clipGamma;

    // Result arrays reused by every call: the per-frame calls allocate nothing (no garbage on the
    // render thread). Read a result before calling the same method again.
    private final float[] frameOut = new float[4];
    private final float[] uniformOut = new float[4];

    public MabaTemporal() {
        this(0.9f, 0.01f, 1.25f);
    }

    public MabaTemporal(float historyWeight, float depthTolerance, float clipGamma) {
        // Same validation as MabaTemporalInit in maba_temporal.h.
        this.historyWeight = (historyWeight > 0f && historyWeight < 1f) ? historyWeight : 0.9f;
        this.depthTolerance = depthTolerance > 0f ? depthTolerance : 0.01f;
        this.clipGamma = clipGamma > 0f ? clipGamma : 1.25f;
        reset();
    }

    public void reset() {
        resetNext = true;
        phase = 0;
    }

    public static float halton(int index, int base) {
        float f = 1f, r = 0f;
        if (base < 2) return 0f;   // as in maba_temporal.h: base 0 / 1 would never terminate
        while (index > 0) {
            f /= base;
            r += f * (index % base);
            index /= base;
        }
        return r;
    }

    /** Returns {jitterX, jitterY, reset(0/1), phase}. The array is reused by the next call. */
    public float[] beginFrame() {
        frameOut[3] = phase;
        frameOut[2] = resetNext ? 1f : 0f;
        resetNext = false;
        frameOut[0] = halton(phase + 1, 2) - 0.5f;
        frameOut[1] = halton(phase + 1, 3) - 0.5f;
        phase = (phase + 1) % PHASES;
        return frameOut;
    }

    /** {historyWeight, depthTolerance, reset, clipGamma} for uMabaTemporalParams (reused array). */
    public float[] uniforms(float reset) {
        uniformOut[0] = historyWeight;
        uniformOut[1] = depthTolerance;
        uniformOut[2] = reset;
        uniformOut[3] = clipGamma;
        return uniformOut;
    }

    /** Same, taking the array beginFrame() returned. */
    public float[] uniforms(float[] frame) {
        return uniforms(frame[2]);
    }
}
